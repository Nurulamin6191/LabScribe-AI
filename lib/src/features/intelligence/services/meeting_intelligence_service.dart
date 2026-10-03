import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import '../../../models/meeting_session.dart';
import '../../public_apis/services/public_api_service.dart';
import '../../audio/services/audio_chunker_service.dart';
import '../../clinical/services/phi_scrubber_service.dart';

/// Configuration for AI Providers (Whisper STT & LLM Inference)
class AiConfig {
  final String openAiApiKey;
  final String openAiBaseUrl;
  final String transcriptionBaseUrl;
  final String transcriptionApiKey;
  final String transcriptionModel;
  final String llmModel;

  AiConfig({
    this.openAiApiKey = '',
    this.openAiBaseUrl = 'https://api.openai.com/v1',
    String? transcriptionBaseUrl,
    String? transcriptionApiKey,
    this.transcriptionModel = 'whisper-1',
    this.llmModel = 'qwen2.5:3b',
  })  : transcriptionBaseUrl = transcriptionBaseUrl ?? openAiBaseUrl,
        transcriptionApiKey = transcriptionApiKey ?? openAiApiKey;
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
                connectTimeout: const Duration(seconds: 45),
                receiveTimeout: const Duration(seconds: 300),
              ),
            );

  /// Synchronize with updated user settings in real-time
  void updateConfig(AiConfig newConfig) {
    _config = newConfig;
  }

  AiConfig get config => _config;

  /// Client-side HIPAA Safe Harbor & clinical de-identification
  ({String scrubbedText, int redactedCount, Map<String, int> breakdown}) deidentifyText(String rawText) {
    return _phiScrubber.scrubTranscript(rawText);
  }

  /// Transcribe audio file with biomedical prompt conditioning and
  /// automated multi-part segmentation if the file exceeds the 24 MB ceiling.
  Future<String> transcribeAudio({
    required String audioFilePath,
    String? languageHint, // 'en', 'hi', or null for auto-detect
    void Function(String progressUpdate)? onProgress,
  }) async {
    final file = File(audioFilePath);
    if (!await file.exists()) {
      throw Exception('Audio file not found at: $audioFilePath');
    }

    // If API key is empty and URL still points to default openai.com, use offline mock
    if (_config.openAiApiKey.isEmpty && _config.openAiBaseUrl.contains('openai.com')) {
      return _generateMockScientificTranscript();
    }

    const scientificContextPrompt = 
        'Scientific research seminar, oncology tumor board, and biomedical lab meeting. '
        'Terms: gene symbols (KRAS G12C, TP53, BRCA1/2, EGFR, HER2, BRAF V600E, PD-L1), '
        'oncology drugs (cisplatin, osimertinib, doxorubicin, paclitaxel, pembrolizumab, sotorasib), '
        'experimental assays (Western blot, flow cytometry, qPCR, RNA-Seq, ChIP-seq, immunohistochemistry, CRISPR-Cas9), '
        'and statistics (p-value, hazard ratio, Kaplan-Meier, 95% CI). '
        'Transcribe scientific and code-mixed terminology accurately with standard scientific casing.';

    // Check if audio file exceeds the 24 MB API limit
    if (_audioChunker.needsChunking(audioFilePath)) {
      onProgress?.call('Audio exceeds 24 MB limit. Segmenting into sequential chunks...');
      final chunkPaths = await _audioChunker.splitAudioFile(audioFilePath);
      final List<String> transcriptParts = [];
      String rollingPrompt = scientificContextPrompt;

      try {
        for (int i = 0; i < chunkPaths.length; i++) {
          final chunkPath = chunkPaths[i];
          onProgress?.call('Transcribing chunk ${i + 1} of ${chunkPaths.length}...');
          
          final chunkTranscript = await _transcribeSingleFile(
            filePath: chunkPath,
            prompt: rollingPrompt,
            languageHint: languageHint,
          );
          transcriptParts.add(chunkTranscript);

          // Update rolling context for continuous syntactic flow
          rollingPrompt = _audioChunker.buildRollingPrompt(
            basePrompt: scientificContextPrompt,
            previousChunkTranscript: chunkTranscript,
          );
        }
      } finally {
        await _audioChunker.cleanupChunks(chunkPaths, audioFilePath);
      }

      return transcriptParts.join(' ');
    } else {
      // Single chunk execution
      return await _transcribeSingleFile(
        filePath: audioFilePath,
        prompt: scientificContextPrompt,
        languageHint: languageHint,
      );
    }
  }

  /// Internal worker for a single audio file chunk
  Future<String> _transcribeSingleFile({
    required String filePath,
    required String prompt,
    String? languageHint,
  }) async {
    final file = File(filePath);
    final fileName = file.path.split(Platform.pathSeparator).last;

    final formData = FormData.fromMap({
      'file': await MultipartFile.fromFile(file.path, filename: fileName),
      'model': _config.transcriptionModel,
      'response_format': 'json',
      'prompt': prompt,
      if (languageHint != null && languageHint.isNotEmpty) 'language': languageHint,
    });

    final response = await _dio.post(
      '${_config.transcriptionBaseUrl}/audio/transcriptions',
      data: formData,
      options: Options(
        headers: {
          if (_config.transcriptionApiKey.isNotEmpty)
            'Authorization': 'Bearer ${_config.transcriptionApiKey}',
        },
      ),
    );

    if (response.statusCode == 200 && response.data != null) {
      return response.data['text'] ?? '';
    } else {
      throw Exception('Transcription failed with code: ${response.statusCode}');
    }
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

    if (_config.openAiApiKey.isEmpty && _config.openAiBaseUrl.contains('openai.com')) {
      return _generateMockScientificIntelligence(transcript);
    }

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
      '${_config.openAiBaseUrl}/chat/completions',
      data: {
        'model': _config.llmModel,
        'temperature': 0.15,
        'response_format': {'type': 'json_object'},
        'messages': [
          {'role': 'system', 'content': scientificSystemPrompt},
          {'role': 'user', 'content': userPrompt},
        ],
      },
      options: Options(
        headers: {
          'Authorization': 'Bearer ${_config.openAiApiKey}',
          'Content-Type': 'application/json',
        },
      ),
    );

    if (response.statusCode != 200 || response.data == null) {
      throw Exception('Scientific AI processing failed with status: ${response.statusCode}');
    }

    final rawJsonText = response.data['choices'][0]['message']['content'];
    final Map<String, dynamic> parsed = jsonDecode(rawJsonText);

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
  }

  /// Interactive Scientific Q&A grounded strictly in the research transcript
  Future<String> askSessionBot({
    required String transcript,
    required List<ChatMessage> history,
    required String question,
  }) async {
    if (_config.openAiApiKey.isEmpty && _config.openAiBaseUrl.contains('openai.com')) {
      return 'Scientific Assistant (Demo Mode): Based on this session transcript, the discussion investigates '
          'KRAS G12C and EGFR signaling pathways, experimental controls, and combination drug regimens.';
    }

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
      '${_config.openAiBaseUrl}/chat/completions',
      data: {
        'model': _config.llmModel,
        'temperature': 0.2,
        'messages': messages,
      },
      options: Options(
        headers: {
          'Authorization': 'Bearer ${_config.openAiApiKey}',
          'Content-Type': 'application/json',
        },
      ),
    );

    if (response.statusCode == 200 && response.data != null) {
      return response.data['choices'][0]['message']['content'] ?? 'No response received.';
    }
    return 'Unable to fetch response from scientific intelligence service.';
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
        '${_config.openAiBaseUrl}/chat/completions',
        data: {
          'model': _config.llmModel,
          'temperature': 0.15,
          'messages': [
            {'role': 'system', 'content': prompt},
            {'role': 'user', 'content': 'Session: $title (Part $sectionIndex of $totalSections)\nTranscript Segment:\n$sectionText'},
          ],
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer ${_config.openAiApiKey}',
            'Content-Type': 'application/json',
          },
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        return response.data['choices'][0]['message']['content'] ?? sectionText;
      }
    } catch (e) {
      print('[MeetingIntelligenceService] Error in section synthesis: $e');
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

  // --- Scientific Mock Fallbacks for Instant Offline Validation ---

  String _generateMockScientificTranscript() {
    return 'Dr. Rao (Lead PI): Good afternoon lab team. Today we are reviewing data from our non-small cell lung cancer (NSCLC) cohort '
        'harboring the KRAS G12C mutation. As you recall, monotherapy with Sotorasib initially shows partial response, '
        'but acquired resistance frequently emerges within six to eight months.\n\n'
        'Dr. Marcus (Remote Zoom Collaborator): Our hypothesis is that secondary EGFR amplification and MET bypass activation mediate this resistance. '
        'In our in vitro cell viability assays with the H23 cell line, combining Sotorasib at 100 nanomolar with Osimertinib '
        'synergistically suppressed phospho-ERK and phospho-AKT levels with statistical significance (p < 0.001).\n\n'
        'Dr. Rao (Lead PI): Dr. Chen, please run the Western Blot validation on cell lysates by Thursday before our next passaging. '
        'Priya, aap patient-derived xenograft (PDX) samples ka RNA-Seq library preparation finalize kar lijiye by Friday.\n\n'
        'Elena (Postdoc - Bench Lead): Understood Dr. Rao. Also, we need to order fresh stocks of Cisplatin, Doxorubicin, and anti-PD-L1 antibodies for the apoptosis flow cytometry assay. '
        'I will submit the order requisition to procurement today.\n\n'
        'Dr. Marcus (Remote Zoom Collaborator): Agreed. Let us compile the combination index curves and submit the translational abstract to AACR by next week. Thank you all.';
  }

  Future<({
    SummaryResult summary,
    List<ActionItem> actionItems,
    List<GlossaryTerm> glossary,
    List<PubMedCitation> citations,
    List<SpeakerTurn> speakerTurns,
  })> _generateMockScientificIntelligence(String transcript) async {
    await Future.delayed(const Duration(milliseconds: 1000));

    final summary = SummaryResult(
      executiveSummary:
          'The research meeting reviewed mechanisms of acquired resistance in KRAS G12C-mutant non-small cell lung cancer (NSCLC). '
          'Preliminary in vitro data on H23 cell lines demonstrates that dual inhibition using Sotorasib combined with Osimertinib '
          'effectively abrogates secondary EGFR/MET bypass signaling, significantly downregulating phosphorylated ERK and AKT pathways (p < 0.001). '
          'Next steps involve in vivo PDX RNA-Seq transcriptomic validation and apoptosis flow cytometry quantification.',
      keyPoints: [
        'Sotorasib monotherapy exhibits acquired resistance mediated by EGFR/MET bypass activation.',
        'Dual inhibition (Sotorasib 100 nM + Osimertinib) synergistic efficacy confirmed in vitro (p < 0.001).',
        'Marked downregulation of downstream phosphorylated ERK and AKT signaling observed.',
        'Patient-derived xenograft (PDX) transcriptomic profiling scheduled to corroborate in vitro findings.',
      ],
      decisionsMade: [
        'Proceed with combination regimen testing in patient-derived xenograft (PDX) models.',
        'Authorize purchase of fresh Cisplatin, Doxorubicin, and anti-PD-L1 antibody batches.',
        'Prepare translational abstract submission for upcoming AACR annual conference.',
      ],
      scientificHypothesis:
          'Secondary EGFR amplification and MET bypass signaling drive acquired resistance to KRAS G12C inhibition, which can be overcome via dual pathway blockade.',
      detectedLanguage: 'English / Scientific Multilingual',
    );

    final speakerTurns = [
      SpeakerTurn(
        id: 'turn-1',
        speakerId: 'Speaker 1',
        speakerName: 'Dr. Rao (Lead PI)',
        startSeconds: 0,
        endSeconds: 42,
        text: 'Good afternoon lab team. Today we are reviewing data from our non-small cell lung cancer (NSCLC) cohort harboring the KRAS G12C mutation. As you recall, monotherapy with Sotorasib initially shows partial response, but acquired resistance frequently emerges within six to eight months.',
      ),
      SpeakerTurn(
        id: 'turn-2',
        speakerId: 'Speaker 2',
        speakerName: 'Dr. Marcus (Remote Zoom Collaborator)',
        startSeconds: 43,
        endSeconds: 88,
        text: 'Our hypothesis is that secondary EGFR amplification and MET bypass activation mediate this resistance. In our in vitro cell viability assays with the H23 cell line, combining Sotorasib at 100 nanomolar with Osimertinib synergistically suppressed phospho-ERK and phospho-AKT levels (p < 0.001).',
      ),
      SpeakerTurn(
        id: 'turn-3',
        speakerId: 'Speaker 1',
        speakerName: 'Dr. Rao (Lead PI)',
        startSeconds: 89,
        endSeconds: 115,
        text: 'Dr. Chen, please run the Western Blot validation on cell lysates by Thursday before our next passaging. Priya, aap patient-derived xenograft (PDX) samples ka RNA-Seq library preparation finalize kar lijiye by Friday.',
      ),
      SpeakerTurn(
        id: 'turn-4',
        speakerId: 'Speaker 3',
        speakerName: 'Elena (Postdoc - Bench Lead)',
        startSeconds: 116,
        endSeconds: 145,
        text: 'Understood Dr. Rao. Also, we need to order fresh stocks of Cisplatin, Doxorubicin, and anti-PD-L1 antibodies for the apoptosis flow cytometry assay. I will submit the order requisition to procurement today.',
      ),
      SpeakerTurn(
        id: 'turn-5',
        speakerId: 'Speaker 2',
        speakerName: 'Dr. Marcus (Remote Zoom Collaborator)',
        startSeconds: 146,
        endSeconds: 172,
        text: 'Agreed. Let us compile the combination index curves and submit the translational abstract to AACR by next week. Thank you all.',
      ),
    ];

    final actionItems = [
      ActionItem(
        id: '1',
        task: 'Execute Western Blot validation for phospho-ERK and phospho-AKT on H23 cell lysates',
        assignee: 'Dr. Chen',
        deadline: 'Thursday',
        priority: 'High',
        category: 'Bench Assay',
        speaker: 'Dr. Rao (Lead PI)',
      ),
      ActionItem(
        id: '2',
        task: 'Finalize RNA-Seq library prep on PDX tumor tissue cohorts',
        assignee: 'Priya',
        deadline: 'Friday',
        priority: 'High',
        category: 'Data Analysis',
        speaker: 'Dr. Rao (Lead PI)',
      ),
      ActionItem(
        id: '3',
        task: 'Procure Cisplatin, Doxorubicin, and anti-PD-L1 reagents for apoptosis assay',
        assignee: 'Lab Tech',
        deadline: 'Monday',
        priority: 'Medium',
        category: 'Reagents',
        speaker: 'Elena (Postdoc - Bench Lead)',
      ),
      ActionItem(
        id: '4',
        task: 'Draft translational oncology abstract for AACR conference submission',
        assignee: 'Research Team',
        deadline: 'Next week',
        priority: 'High',
        category: 'Manuscript',
        speaker: 'Dr. Marcus (Remote Zoom Collaborator)',
      ),
    ];

    // Query PubChem and Free Dictionary cascade for scientific terms
    final sampleScientificTerms = ['cisplatin', 'doxorubicin', 'apoptosis', 'angiogenesis'];
    final glossary = await _publicApiService.lookupBatchWords(sampleScientificTerms);

    final sampleCitations = [
      PubMedCitation(
        pmid: '33208354',
        title: 'Mechanisms of Acquired Resistance to KRAS G12C Inhibitors in Non-Small Cell Lung Cancer',
        authors: 'Awad MM, Liu S, Rybkin II, et al.',
        journal: 'N Engl J Med',
        pubYear: '2021',
        doi: '10.1056/NEJMoa2105281',
      ),
    ];

    return (
      summary: summary,
      actionItems: actionItems,
      glossary: glossary,
      citations: sampleCitations,
      speakerTurns: speakerTurns,
    );
  }
}

extension StringExtension on String {
  String take(int n) => length <= n ? this : substring(0, n);
}
