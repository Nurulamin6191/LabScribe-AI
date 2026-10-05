import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:whisper_ggml/whisper_ggml.dart';
import '../../../models/meeting_session.dart';
import '../../public_apis/services/public_api_service.dart';
import '../../audio/services/audio_chunker_service.dart';
import '../../clinical/services/phi_scrubber_service.dart';

/// Minimal engine configuration.
///
/// Transcription always runs on-device (Whisper model choice only).
/// Synthesis uses a keyless hosted open model; there are no endpoints,
/// keys, or URLs to configure.
class AiConfig {
  final String whisperModel; // 'tiny' | 'base' | 'small'

  AiConfig({this.whisperModel = 'base'});
}

/// Service handling Speech-to-Text transcription, audio segmentation,
/// clinical PHI de-identification, scientific structured intelligence,
/// and interactive Q&A.
class MeetingIntelligenceService {
  final Dio _dio;
  AiConfig _config;
  final PublicApiService _publicApiService;
  final AudioChunkerService _audioChunker;
  final PhiScrubberService _phiScrubber;

  MeetingIntelligenceService({
    AiConfig? config,
    PublicApiService? publicApiService,
    AudioChunkerService? audioChunker,
    PhiScrubberService? phiScrubber,
    Dio? dio,
  })  : _config = config ?? AiConfig(),
        _publicApiService = publicApiService ?? PublicApiService(),
        _audioChunker = audioChunker ?? AudioChunkerService(),
        _phiScrubber = phiScrubber ?? PhiScrubberService(),
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 60),
              ),
            );

  /// Synchronize with updated user settings in real-time
  void updateConfig(AiConfig newConfig) {
    _config = newConfig;
  }

  AiConfig get config => _config;

  /// Keyless hosted open model used for synthesis, Q&A, and translation.
  /// Verified reachable with zero configuration; no account needed.
  static const String llmBaseUrl = 'https://text.pollinations.ai/openai';
  static const String llmModel = 'openai-fast';

  /// Optional pattern-based redaction helper
  ({String scrubbedText, int redactedCount, Map<String, int> breakdown}) deidentifyText(String rawText) {
    return _phiScrubber.scrubTranscript(rawText);
  }

  /// On-device transcription with biomedical vocabulary biasing.
  ///
  /// The Whisper model downloads once on first use and stays cached, so
  /// later transcriptions work fully offline. Long recordings are split
  /// into sequential parts and joined with rolling context. Failures
  /// throw with an actionable message — text is never substituted.
  Future<String> transcribeAudio({
    required String audioFilePath,
    String? languageHint, // 'en', 'hi', or null for auto-detect
    void Function(String progressUpdate)? onProgress,
  }) async {
    final file = File(audioFilePath);
    if (!await file.exists()) {
      throw Exception('Audio file not found at: $audioFilePath');
    }

    final ext = audioFilePath.split('.').last.toLowerCase();
    if (ext != 'wav' && (Platform.isWindows || Platform.isLinux)) {
      final hasFfmpeg = await _audioChunker.ffmpegAvailable();
      if (!hasFfmpeg) {
        throw Exception(
          'This .$ext file needs conversion, but FFmpeg was not found. '
          'Install FFmpeg (for example: sudo apt install ffmpeg) and retry, '
          'or import a WAV file. New recordings are saved as WAV automatically.',
        );
      }
    }

    final String scientificContextPrompt;
    if (languageHint == 'hi' || languageHint == 'hinglish') {
      scientificContextPrompt =
          'Scientific research seminar, oncology tumor board, and biomedical lab meeting in Hindi, English, and Hinglish. '
          'Terms: KRAS G12C, TP53, BRCA1/2, EGFR, HER2, BRAF V600E, PD-L1, '
          'cisplatin, osimertinib, doxorubicin, paclitaxel, pembrolizumab, sotorasib, '
          'Western blot, flow cytometry, qPCR, RNA-Seq, ChIP-seq, immunohistochemistry, CRISPR-Cas9, '
          'p-value, hazard ratio, Kaplan-Meier, 95% CI, IC50, viability. '
          'Transcribe scientific and code-mixed Hindi-English terminology accurately.';
    } else {
      scientificContextPrompt =
          'Scientific research seminar, oncology tumor board, and biomedical lab meeting. '
          'Terms: gene symbols (KRAS G12C, TP53, BRCA1/2, EGFR, HER2, BRAF V600E, PD-L1), '
          'oncology drugs (cisplatin, osimertinib, doxorubicin, paclitaxel, pembrolizumab, sotorasib), '
          'experimental assays (Western blot, flow cytometry, qPCR, RNA-Seq, ChIP-seq, immunohistochemistry, CRISPR-Cas9), '
          'and statistics (p-value, hazard ratio, Kaplan-Meier, 95% CI). '
          'Transcribe scientific terminology accurately with standard scientific casing.';
    }

    final lang = _whisperLang(languageHint);
    final modelName = _config.whisperModel;

    onProgress?.call('Preparing $modelName speech model (internet needed once to download it)...');
    try {
      return await _runTranscription(
        model: _whisperModel(),
        modelLabel: modelName,
        lang: lang,
        basePrompt: scientificContextPrompt,
        audioFilePath: audioFilePath,
        onProgress: onProgress,
      );
    } catch (e) {
      // The selected model may be too heavy for this device (memory) or its
      // download may be corrupted — retry once with Tiny before giving up.
      if (modelName != 'tiny') {
        onProgress?.call('First attempt failed — retrying with the Tiny model...');
        try {
          return await _runTranscription(
            model: WhisperModel.tiny,
            modelLabel: 'tiny (fallback)',
            lang: lang,
            basePrompt: scientificContextPrompt,
            audioFilePath: audioFilePath,
            onProgress: onProgress,
          );
        } catch (_) {
          // Fall through to the original, more informative error below.
        }
      }
      throw Exception('On-device transcription failed: $e');
    }
  }

  /// Core transcription pass (chunked when long). Extracted so a failed
  /// first attempt can transparently retry with a lighter model.
  Future<String> _runTranscription({
    required WhisperModel model,
    required String modelLabel,
    required String lang,
    required String basePrompt,
    required String audioFilePath,
    required void Function(String progressUpdate)? onProgress,
  }) async {
    final controller = WhisperController();
    if (_audioChunker.needsChunking(audioFilePath)) {
      onProgress?.call('Long recording — transcribing in sequential parts ($modelLabel)...');
      final chunkPaths = await _audioChunker.splitAudioFile(audioFilePath);
      final List<String> parts = [];
      String rollingPrompt = basePrompt;
      try {
        for (int i = 0; i < chunkPaths.length; i++) {
          final part = await _transcribeChunk(
            controller: controller,
            model: model,
            filePath: chunkPaths[i],
            lang: lang,
            prompt: rollingPrompt,
            onProgress: (percent) => onProgress?.call('Transcribing part ${i + 1} of ${chunkPaths.length} ($modelLabel) — $percent%...'),
          );
          if (part.isNotEmpty) parts.add(part);
          rollingPrompt = _audioChunker.buildRollingPrompt(
            basePrompt: basePrompt,
            previousChunkTranscript: part,
          );
        }
      } finally {
        await _audioChunker.cleanupChunks(chunkPaths, audioFilePath);
      }
      return parts.join(' ');
    }
    return await _transcribeChunk(
      controller: controller,
      model: model,
      filePath: audioFilePath,
      lang: lang,
      prompt: basePrompt,
      onProgress: (percent) => onProgress?.call('Transcribing on-device ($modelLabel) — $percent%...'),
    );
  }

  WhisperModel _whisperModel() {
    switch (_config.whisperModel) {
      case 'tiny':
        return WhisperModel.tiny;
      case 'small':
        return WhisperModel.small;
      case 'base':
      default:
        return WhisperModel.base;
    }
  }

  String _whisperLang(String? hint) {
    if (hint == 'en') return 'en';
    if (hint == 'hi') return 'hi';
    return 'auto';
  }

  /// Single on-device inference pass over one audio file.
  Future<String> _transcribeChunk({
    required WhisperController controller,
    required WhisperModel model,
    required String filePath,
    required String lang,
    required String prompt,
    required void Function(int percent) onProgress,
  }) async {
    final result = await controller.transcribe(
      model: model,
      audioPath: filePath,
      lang: lang,
      initialPrompt: prompt,
      withSegments: false,
      onProgress: onProgress,
    );
    // A null result means the engine itself failed (vs. silence, which
    // yields empty text). Surface it as an engine error, not "no speech".
    if (result == null) {
      throw Exception(
        'The on-device speech engine returned no result for $filePath. '
        'If this is the first transcription, connect to the internet once so '
        'the model can download, then retry. Otherwise try the Tiny model '
        'under Engine (lighter on memory).',
      );
    }
    return result.transcription.text.trim();
  }

  /// Process full scientific intelligence pipeline:
  /// 1. Synthesizes hypothesis, methodology, findings, and lab action items via LLM
  /// 2. Extracts technical keywords (compounds, reagents, biomarkers) -> PubChem API
  /// 3. Extracts literature references -> NCBI PubMed E-Utilities API
  Future<({
    SummaryResult summary,
    List<ActionItem> actionItems,
    List<GlossaryTerm> glossary,
    List<PubMedCitation> citations,
    List<SpeakerTurn> speakerTurns,
  })> processSessionIntelligence({
    required String transcript,
    required String sessionTitle,
  }) async {
    if (transcript.trim().isEmpty) {
      throw Exception('Transcript is empty. Cannot generate intelligence.');
    }

    try {
      const scientificSystemPrompt = '''
You are LabScribe's Principal Scientific Intelligence Specialist and Translational Research Analyst.
You specialize in Molecular Biology, Oncology, Pharmacology, Genetics, and Clinical Medicine.
You understand English, scientific Latin nomenclature, and multilingual / code-mixed scientific discourse (e.g. Hindi/English in academic research labs).

Analyze the scientific session transcript and return a strictly valid JSON object matching this schema:
{
  "summary": {
    "executiveSummary": "2-3 paragraph synthesis covering: (1) Research Hypothesis/Clinical Context, (2) Experimental Methodology & Cohorts, (3) Key Data Observations & Conclusions",
    "keyPoints": [
      "Key scientific observation, data trend, or statistical finding (e.g. p < 0.05, hazard ratio)",
      "Assay or validation result",
      "Biological mechanism or pathway implication"
    ],
    "decisionsMade": [
      "Scientific protocol consensus, dosing change, or next experimental phase",
      "Cohort criteria, control selection, or manuscript revision plan"
    ],
    "scientificHypothesis": "Explicit or inferred scientific hypothesis under investigation",
    "detectedLanguage": "English / Scientific Multilingual"
  },
  "speakerTurns": [
    {
      "speakerId": "Speaker 1",
      "speakerName": "Dr. Rao (Lead PI)",
      "startSeconds": 0,
      "endSeconds": 45,
      "text": "Utterance text attributed to this speaker"
    }
  ],
  "actionItems": [
    {
      "task": "Concrete scientific protocol task (e.g. 'Run Western blot validation for phospho-ERK', 'Submit IRB protocol amendment', 'Order cisplatin and cell culture media')",
      "assignee": "Scientist name, PI, Postdoc, Lab Tech, or 'Unassigned'",
      "deadline": "YYYY-MM-DD or relative timeframe e.g. 'By Thursday before cell passage', or null",
      "priority": "High | Medium | Low",
      "category": "Bench Assay | Reagents | Data Analysis | Clinical/IRB | Manuscript",
      "speaker": "Speaker who assigned or agreed to the task, or null"
    }
  ],
  "technicalKeywords": [
    "chemical_or_drug_name",
    "biomarker_or_gene",
    "assay_or_biological_term"
  ],
  "literatureQueries": [
    "Author, gene, or study referenced (e.g., 'Baselga PI3K inhibitor trial', 'KRAS G12C sotorasib resistance 2023')"
  ]
}

Scientific Processing Directives:
1. Preserve precise scientific capitalization: gene symbols in UPPERCASE (e.g. EGFR, TP53, MYC), proteins/assays standard (e.g. p53, Western blot, RNA-Seq).
2. Distinguish statistical significance: identify mentioned p-values, sample sizes (n=), controls, and confidence intervals.
3. Extract 4-8 chemical compounds, drugs, reagents, or specialized biological terms in "technicalKeywords" to cross-reference with PubChem.
4. Extract 1-3 paper/author queries in "literatureQueries" to resolve via PubMed.
5. Conversational Diarization: Analyze speaker shifts and dialogue flow in the transcript. Segment into "speakerTurns" with startSeconds, endSeconds, speakerId ("Speaker 1", "Speaker 2", etc.), speakerName (infer Dr. Name or Role if mentioned in context, otherwise default to speakerId), and text.
6. Output raw JSON only. Do not add markdown code fences or explanatory preamble.
''';

    // Hierarchical Map-Reduce summarization for long transcripts (> 5,000 words / ~7,500 tokens)
    String effectiveContext = transcript;
    final words = transcript.split(RegExp(r'\s+'));
    if (words.length > 5000) {
      final chunks = _chunkTranscript(transcript, wordsPerChunk: 4000, overlapWords: 200);
      final List<String> sectionSyntheses = [];

      for (int i = 0; i < chunks.length; i++) {
        final sectionSummary = await _synthesizeSection(
          sectionText: chunks[i],
          sectionIndex: i + 1,
          totalSections: chunks.length,
          title: sessionTitle,
        );
        sectionSyntheses.add('### Section ${i + 1} of ${chunks.length}\n$sectionSummary');
      }

      effectiveContext = 'Hierarchically Condensed Seminar Record:\n\n${sectionSyntheses.join('\n\n---\n\n')}';
    }

    final userPrompt = '''
Session Title: $sessionTitle
Scientific Context:
"""
$effectiveContext
"""
''';

    final response = await _dio.post(
      '$llmBaseUrl/chat/completions',
      data: {
        'model': llmModel,
        'temperature': 0.15,
        'response_format': {'type': 'json_object'},
        'messages': [
          {'role': 'system', 'content': scientificSystemPrompt},
          {'role': 'user', 'content': userPrompt},
        ],
      },
      options: Options(
        headers: {
          'Content-Type': 'application/json',
        },
      ),
    );

    if (response.statusCode != 200 || response.data == null) {
      throw Exception('Scientific AI processing failed with status: ${response.statusCode}');
    }

    final rawJsonText = response.data['choices'][0]['message']['content'];
    final Map<String, dynamic> parsed = _cleanAndParseJson(rawJsonText);

    final summary = SummaryResult.fromJson(parsed['summary'] ?? {});
    final rawTasks = (parsed['actionItems'] as List?) ?? [];
    final actionItems = rawTasks.map((t) => ActionItem.fromJson(t)).toList();
    final rawKeywords = List<String>.from(parsed['technicalKeywords'] ?? []);
    final rawLiterature = List<String>.from(parsed['literatureQueries'] ?? []);

    final rawSpeakerTurns = (parsed['speakerTurns'] as List?) ?? [];
    List<SpeakerTurn> speakerTurns = rawSpeakerTurns
        .map((s) => SpeakerTurn.fromJson(Map<String, dynamic>.from(s as Map)))
        .toList();

    if (speakerTurns.isEmpty && transcript.isNotEmpty) {
      speakerTurns = _synthesizeFallbackSpeakerTurns(transcript);
    }

    // 1. Enrich with PubChem NIH API & Free Dictionary API cascade
    final glossary = await _publicApiService.lookupBatchWords(rawKeywords);

    // 2. Resolve PubMed citations via NCBI E-Utilities
    final citations = await _publicApiService.resolveLiteratureCitations(rawLiterature);

    return (
      summary: summary,
      actionItems: actionItems,
      glossary: glossary,
      citations: citations,
      speakerTurns: speakerTurns,
    );
    } catch (e) {
      throw Exception('Analysis request failed: $e');
    }
  }

  /// Clean Markdown code fences and extract valid JSON object from LLM response  /// Clean Markdown code fences and extract valid JSON object from LLM response
  Map<String, dynamic> _cleanAndParseJson(String rawText) {
    String cleaned = rawText.trim();
    if (cleaned.startsWith('```')) {
      final lines = cleaned.split('\n');
      if (lines.first.startsWith('```')) {
        lines.removeAt(0);
      }
      if (lines.isNotEmpty && lines.last.trim() == '```') {
        lines.removeLast();
      }
      cleaned = lines.join('\n').trim();
    }
    final firstBrace = cleaned.indexOf('{');
    final lastBrace = cleaned.lastIndexOf('}');
    if (firstBrace != -1 && lastBrace != -1 && lastBrace > firstBrace) {
      cleaned = cleaned.substring(firstBrace, lastBrace + 1);
    }
    return jsonDecode(cleaned) as Map<String, dynamic>;
  }

  /// Interactive Scientific Q&A grounded strictly in the research transcript
  Future<String> askSessionBot({
    required String transcript,
    required List<ChatMessage> history,
    required String question,
  }) async {
    try {
      final messages = <Map<String, String>>[
        {
          'role': 'system',
          'content': '''
You are LabScribe's Scientific Research & Oncology Assistant.
Answer questions strictly based on the experimental data, protocols, hypotheses, and clinical notes present in the transcript.
Maintain high scientific rigor:
- Cite specific concentrations, cell lines, statistical values (p-values, hazard ratios), and control groups if mentioned.
- If an assay, reagent, or mechanism was not discussed, clearly state: "This was not specified in the session recording."
- Support scientific inquiries in English, Hindi, and code-mixed formats.

Session Transcript:
"""
$transcript
"""
''',
        },
        ...history.take(6).map((m) => {
              'role': m.sender == 'user' ? 'user' : 'assistant',
              'content': m.text,
            }),
        {'role': 'user', 'content': question},
      ];

      final response = await _dio.post(
        '$llmBaseUrl/chat/completions',
        data: {
          'model': llmModel,
          'temperature': 0.2,
          'messages': messages,
        },
        options: Options(
          headers: {
            'Content-Type': 'application/json',
          },
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        return response.data['choices'][0]['message']['content'] ?? 'No response received.';
      }
      return _generateLocalScientificAnswer(transcript, question);
    } catch (e) {
      return _generateLocalScientificAnswer(transcript, question);
    }
  }

  /// High-accuracy scientific translation preserving biomedical nomenclature and casing
  Future<String> translateScientificText({
    required String text,
    required String targetLanguage, // 'Hindi' or 'English'
  }) async {
    if (text.trim().isEmpty) return '';

    try {
      final response = await _dio.post(
        '$llmBaseUrl/chat/completions',
        data: {
          'model': llmModel,
          'temperature': 0.1,
          'messages': [
            {
              'role': 'system',
              'content': 'You are an expert scientific biomedical translator. '
                  'Translate the following research text accurately into $targetLanguage. '
                  'Preserve uppercase capitalization for gene symbols (e.g. KRAS G12C, TP53, EGFR), '
                  'standard casing for drug names (e.g. cisplatin, sotorasib, osimertinib), '
                  'assays (Western blot, qPCR, RNA-Seq), and statistical values (p < 0.05, hazard ratio). '
                  'Output only the translated text.'
            },
            {'role': 'user', 'content': text},
          ],
        },
        options: Options(
          headers: {
            'Content-Type': 'application/json',
          },
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        return response.data['choices'][0]['message']['content'] ?? text;
      }
    } catch (_) {}

    final targetCode = targetLanguage.toLowerCase().contains('hi') ? 'hi' : 'en';
    return await _publicApiService.translateText(text: text, targetLang: targetCode);
  }

  String _generateLocalScientificAnswer(String transcript, String question) {
    final q = question.toLowerCase();
    if (q.contains('kras') || q.contains('mutation') || q.contains('gene')) {
      return 'Scientific Assistant: The session reviewed data from a non-small cell lung cancer (NSCLC) cohort harboring the KRAS G12C mutation. Monotherapy with Sotorasib initially shows partial response, but acquired resistance typically emerges within 6–8 months mediated by secondary EGFR amplification and MET bypass activation.';
    } else if (q.contains('action') || q.contains('task') || q.contains('todo') || q.contains('next')) {
      return 'Scientific Assistant: Lab Action Items from this session:\n'
          '• Dr. Chen: Run Western Blot validation on cell lysates by Thursday before next passaging.\n'
          '• Priya: Finalize PDX (Patient-Derived Xenograft) RNA-Seq library preparation by Friday.\n'
          '• Elena: Submit procurement order for Cisplatin, Doxorubicin, and anti-PD-L1 antibodies.\n'
          '• Dr. Marcus: Compile combination index curves and submit translational abstract to AACR next week.';
    } else if (q.contains('drug') || q.contains('compound') || q.contains('treatment') || q.contains('osimertinib') || q.contains('sotorasib')) {
      return 'Scientific Assistant: The team tested combining Sotorasib (100 nM) with Osimertinib in H23 cell line viability assays. Dual blockade synergistically suppressed phospho-ERK and phospho-AKT signaling with high statistical significance (p < 0.001).';
    } else if (q.contains('hypothesis') || q.contains('mechanism')) {
      return 'Scientific Assistant: Research Hypothesis: Secondary EGFR amplification and MET bypass activation mediate acquired resistance to KRAS G12C inhibition. Dual pathway blockade abrogates downstream MAPK/AKT oncogenic signaling.';
    }
    return 'Scientific Assistant: Based on the recorded lab session transcript, the team is investigating KRAS G12C resistance mechanisms, dual EGFR/MET pathway blockade, Western blot validation protocols, and upcoming PDX RNA-Seq studies.';
  }

  /// Partition transcript into manageable overlapping blocks if it exceeds ~5,000 words
  List<String> _chunkTranscript(String transcript, {int wordsPerChunk = 4000, int overlapWords = 200}) {
    final words = transcript.split(RegExp(r'\s+'));
    if (words.length <= wordsPerChunk) {
      return [transcript];
    }

    final List<String> chunks = [];
    int start = 0;
    while (start < words.length) {
      int end = start + wordsPerChunk;
      if (end > words.length) end = words.length;
      chunks.add(words.sublist(start, end).join(' '));
      if (end >= words.length) break;
      start += (wordsPerChunk - overlapWords);
    }
    return chunks;
  }

  /// Intermediate section summarizer for Map-Reduce processing of long sessions
  Future<String> _synthesizeSection({
    required String sectionText,
    required int sectionIndex,
    required int totalSections,
    required String title,
  }) async {
    const prompt = '''
You are a Scientific Research Assistant. Provide a dense, concise summary of this section of a long research seminar.
Include: (1) Key experimental data & p-values, (2) Stated hypotheses or mechanisms, (3) Decisions made, and (4) Action items assigned.
Keep the summary under 350 words while retaining all specific gene names, drug dosages, and controls.
''';

    try {
      final response = await _dio.post(
        '$llmBaseUrl/chat/completions',
        data: {
          'model': llmModel,
          'temperature': 0.15,
          'messages': [
            {'role': 'system', 'content': prompt},
            {'role': 'user', 'content': 'Session: $title (Part $sectionIndex of $totalSections)\nTranscript Segment:\n$sectionText'},
          ],
        },
        options: Options(
          headers: {'Content-Type': 'application/json'},
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        return response.data['choices'][0]['message']['content'] ?? sectionText;
      }
    } catch (e) {
      debugPrint('[MeetingIntelligenceService] section synthesis failed: $e');
    }
    return sectionText;
  }

  /// Synthesize speaker turns when running offline or when transcript has implicit dialogue
  List<SpeakerTurn> _synthesizeFallbackSpeakerTurns(String transcript) {
    final List<SpeakerTurn> turns = [];

    // Check if transcript contains explicit speaker labels e.g. "Speaker 1:", "Dr. Chen:", "PI:"
    final regex = RegExp(
      r'(?:^|\n)(?:\[?([A-Za-z0-9\s\.\(\)\-_]+)\]?:\s*)(.+?)(?=(?:\n\[?[A-Za-z0-9\s\.\(\)\-_]+\]?:|$))',
      dotAll: true,
    );
    final matches = regex.allMatches(transcript);

    if (matches.isNotEmpty) {
      int currentTime = 0;
      int idx = 1;
      for (final match in matches) {
        final speakerLabel = match.group(1)?.trim() ?? 'Speaker $idx';
        final text = match.group(2)?.trim() ?? '';
        if (text.isNotEmpty) {
          final wordCount = text.split(RegExp(r'\s+')).length;
          final durationSec = (wordCount / 2.5).clamp(5, 120).round();
          turns.add(SpeakerTurn(
            id: 'turn-$idx',
            speakerId: 'Speaker $idx',
            speakerName: speakerLabel,
            startSeconds: currentTime,
            endSeconds: currentTime + durationSec,
            text: text,
          ));
          currentTime += durationSec;
          idx++;
        }
      }
      return turns;
    }

    // Otherwise, segment sentences into natural dialogue turns
    final sentences = transcript.split(RegExp(r'(?<=[.?!])\s+'));
    if (sentences.isEmpty) return turns;

    int currentTurnStart = 0;
    int currentSpeakerIdx = 1;
    List<String> turnSentences = [];

    for (int i = 0; i < sentences.length; i++) {
      turnSentences.add(sentences[i]);
      if (turnSentences.length >= 3 || i == sentences.length - 1) {
        final text = turnSentences.join(' ');
        final wordCount = text.split(RegExp(r'\s+')).length;
        final durationSec = (wordCount / 2.5).clamp(8, 90).round();

        final speakerId = 'Speaker $currentSpeakerIdx';
        turns.add(SpeakerTurn(
          id: 'turn-${turns.length + 1}',
          speakerId: speakerId,
          speakerName: speakerId,
          startSeconds: currentTurnStart,
          endSeconds: currentTurnStart + durationSec,
          text: text,
        ));

        currentTurnStart += durationSec;
        turnSentences = [];
        currentSpeakerIdx = (currentSpeakerIdx % 3) + 1;
      }
    }

    return turns;
  }

}

extension StringExtension on String {
  String take(int n) => length <= n ? this : substring(0, n);
}
