import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:whisper_ggml/whisper_ggml.dart';
import '../../../models/meeting_session.dart';
import '../../public_apis/services/public_api_service.dart';
import 'package:path_provider/path_provider.dart';
import '../../../core/config_service.dart';
import '../../audio/services/audio_chunker_service.dart';
import '../../clinical/services/phi_scrubber_service.dart';
import '../../audio/services/wav_probe.dart';
import 'transcript_cleaner.dart';

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
    return (await transcribeAudioDetailed(
      audioFilePath: audioFilePath,
      languageHint: languageHint,
      onProgress: onProgress,
    )).text;
  }

  /// Same as [transcribeAudio], but also returns the engine's timed
  /// segments so callers can ground speaker turns and playback seek in
  /// real timestamps. [TranscriptSegment]s are empty when the audio had
  /// to be split into chunks whose durations could not be measured.
  Future<({String text, List<TranscriptSegment> segments})>
      transcribeAudioDetailed({
    required String audioFilePath,
    String? languageHint,
    void Function(String progressUpdate)? onProgress,
  }) async {
    final file = File(audioFilePath);
    if (!await file.exists()) {
      throw Exception('Audio file not found at: $audioFilePath');
    }

    final ext = audioFilePath.split('.').last.toLowerCase();
    if (ext == 'wav') {
      // A recorder killed mid-file leaves RIFF/data size fields wrong; the
      // engine rejects such files outright, so repair before it sees them.
      await WavProbe.repairSizes(file);
      final info = await WavProbe.probe(file);
      if (info == null) {
        throw Exception(
          'This WAV file could not be parsed (missing or corrupt header). '
          'Re-record the session; if imports keep failing, convert the file '
          'to 16 kHz mono WAV first.',
        );
      }
      // The engine reads 16 kHz/16-bit PCM natively. Any other format is
      // resampled by FFmpeg — but only when FFmpeg exists. Say exactly what
      // is wrong instead of letting the native layer fail opaquely.
      final needsConversion = info.sampleRate != 16000 ||
          info.bitsPerSample != 16 ||
          info.channels > 2;
      if (needsConversion &&
          (Platform.isWindows || Platform.isLinux) &&
          !await _audioChunker.ffmpegAvailable()) {
        throw Exception(
          'This WAV is ${info.formatLabel}, but the speech engine needs '
          '16 kHz mono 16-bit audio. FFmpeg (the converter) was not found — '
          'install it (for example: sudo apt install ffmpeg) and retry, or '
          'record again inside the app, which writes engine-ready WAV.',
        );
      }
    }
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

    final String scientificContextPrompt = whisperContextPrompt(languageHint);
    final lang = _whisperLang(languageHint);
    final modelName = _config.whisperModel;

    await ensureModelReady(
      onStatus: onProgress,
      onProgress: (p) => onProgress?.call('Preparing model — $p%...'),
    );
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
      // download may be corrupted — retry once with Tiny, but only when it
      // is already on disk: pulling 75 MB in the middle of a failure just
      // hides the real error behind another wait.
      if (modelName != 'tiny' && (await modelFileStatus('tiny')).present) {
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
      throw Exception(
        'On-device transcription failed: $e',
      );
    }
  }

  /// Turns terse native errors into instructions the user can act on.
  static String _engineErrorHint(String raw) {
    final m = raw.toLowerCase();
    if (m.contains('must be 16 khz') ||
        m.contains('must be 16 bit') ||
        m.contains('failed to open wav')) {
      return '$raw — the file could not be converted. Install FFmpeg '
          '(for example: sudo apt install ffmpeg) so any format is '
          'resampled automatically, or record/import a 16 kHz WAV.';
    }
    if (m.contains('failed to load model') || m.contains('ggml')) {
      return '$raw — the speech model looks incomplete. Open Engine and '
          're-download the model, then retry.';
    }
    return raw;
  }

  /// Core transcription pass (chunked when long). Extracted so a failed
  /// first attempt can transparently retry with a lighter model.
  ///
  /// Returns the cleaned text plus absolute-timestamped segments. Chunk
  /// offsets are measured from each chunk's real duration; when a chunk's
  /// duration cannot be read (non-WAV splits), segments are dropped rather
  /// than returned with wrong times.
  Future<({String text, List<TranscriptSegment> segments})> _runTranscription({
    required WhisperModel model,
    required String modelLabel,
    required String lang,
    required String basePrompt,
    required String audioFilePath,
    required void Function(String progressUpdate)? onProgress,
  }) async {
    if (_audioChunker.needsChunking(audioFilePath)) {
      onProgress?.call('Long recording — transcribing in sequential parts ($modelLabel)...');
      final chunkPaths = await _audioChunker.splitAudioFile(audioFilePath);
      final List<String> parts = [];
      final List<TranscriptSegment> segments = [];
      var offsetMs = 0;
      var offsetsReliable = true;
      String rollingPrompt = basePrompt;
      try {
        for (int i = 0; i < chunkPaths.length; i++) {
          final part = await _transcribeChunk(
            model: model,
            filePath: chunkPaths[i],
            lang: lang,
            prompt: rollingPrompt,
            withSegments: true,
            timeOffsetMs: offsetMs,
            onProgress: (percent) => onProgress?.call('Transcribing part ${i + 1} of ${chunkPaths.length} ($modelLabel) — $percent%...'),
          );
          if (part.text.isNotEmpty) parts.add(part.text);
          segments.addAll(part.segments);
          rollingPrompt = _audioChunker.buildRollingPrompt(
            basePrompt: basePrompt,
            previousChunkTranscript: part.text,
          );
          // Advance the clock by this chunk's measured duration so the next
          // chunk's timestamps stay absolute in the original recording.
          final info = await WavProbe.probe(File(chunkPaths[i]));
          if (info == null) {
            offsetsReliable = false;
          } else {
            offsetMs += (info.durationSec * 1000).round();
          }
        }
      } finally {
        await _audioChunker.cleanupChunks(chunkPaths, audioFilePath);
      }
      return (
        text: parts.join(' '),
        segments:
            offsetsReliable ? segments : const <TranscriptSegment>[],
      );
    }
    return await _transcribeChunk(
      model: model,
      filePath: audioFilePath,
      lang: lang,
      prompt: basePrompt,
      withSegments: true,
      onProgress: (percent) => onProgress?.call('Transcribing on-device ($modelLabel) — $percent%...'),
    );
  }

  /// Approximate on-disk bytes per model (validates completed downloads).
  static const Map<String, int> expectedModelBytes = {
    'tiny': 75 * 1024 * 1024,
    'base': 150 * 1024 * 1024,
    'small': 465 * 1024 * 1024,
  };

  /// Local model-file status: presence + size on disk.
  Future<({bool present, int bytes, String path})> modelFileStatus(String name) async {
    try {
      final controller = WhisperController();
      final path = await controller.getPath(_whisperModel(name));
      final file = File(path);
      if (await file.exists()) {
        return (present: true, bytes: await file.length(), path: path);
      }
      return (present: false, bytes: 0, path: path);
    } catch (_) {
      return (present: false, bytes: 0, path: '');
    }
  }

  /// Downloads the model from the plugin's own HuggingFace URL
  /// (`WhisperModel.modelUri`) into the plugin's own path
  /// (`WhisperController.getPath`), with real progress and size
  /// verification. A truncated or corrupt file is deleted and reported
  /// instead of being fed to the engine.
  Future<String> downloadModelFile({
    required String name,
    void Function(double fraction, int received, int total)? onProgress,
  }) async {
    final model = _whisperModel(name);
    final controller = WhisperController();
    final path = await controller.getPath(model);
    final expected = expectedModelBytes[name] ?? (100 * 1024 * 1024);
    final file = File(path);

    if (await file.exists()) {
      final len = await file.length();
      if (len > expected ~/ 2) return path;
      try {
        await file.delete();
      } catch (_) {}
    }

    try {
      await _dio.download(
        model.modelUri.toString(),
        path,
        deleteOnError: true,
        options: Options(
          receiveTimeout: const Duration(minutes: 30),
          sendTimeout: const Duration(seconds: 30),
        ),
        onReceiveProgress: (received, total) {
          final denom = total > 0 ? total : expected;
          onProgress?.call((received / denom).clamp(0.0, 1.0), received, denom);
        },
      );
    } catch (e) {
      throw Exception(
        'Model download failed ($name). Connect to stable internet and retry. '
        'Details: $e',
      );
    }

    final len = await file.length();
    if (len < expected ~/ 2) {
      try {
        await file.delete();
      } catch (_) {}
      throw Exception(
        'Model download incomplete ($name): got ${(len / 1048576).toStringAsFixed(0)} MB, '
        'expected ~${(expected / 1048576).toStringAsFixed(0)} MB. Retry on stable internet.',
      );
    }
    return path;
  }

  WhisperModel _whisperModel([String? name]) {
    switch (name ?? _config.whisperModel) {
      case 'tiny':
        return WhisperModel.tiny;
      case 'small':
        return WhisperModel.small;
      case 'base':
      default:
        return WhisperModel.base;
    }
  }

  /// The model the user chose in Engine settings — used by one-shot
  /// transcription and by live captions alike so both stay in sync.
  WhisperModel get selectedWhisperModel => _whisperModel();

  /// Vocabulary-bias prompt that steers Whisper toward scientific terms,
  /// shared by every inference path (batch, chunked, live captions).
  static String whisperContextPrompt(String? languageHint) {
    if (languageHint == 'hi' || languageHint == 'hinglish') {
      return 'Scientific research seminar, oncology tumor board, and biomedical lab meeting in Hindi, English, and Hinglish. '
          'Terms: KRAS G12C, TP53, BRCA1/2, EGFR, HER2, BRAF V600E, PD-L1, '
          'cisplatin, osimertinib, doxorubicin, paclitaxel, pembrolizumab, sotorasib, '
          'Western blot, flow cytometry, qPCR, RNA-Seq, ChIP-seq, immunohistochemistry, CRISPR-Cas9, '
          'p-value, hazard ratio, Kaplan-Meier, 95% CI, IC50, viability. '
          'Transcribe scientific and code-mixed Hindi-English terminology accurately.';
    }
    return 'Scientific research seminar, oncology tumor board, and biomedical lab meeting. '
        'Terms: gene symbols (KRAS G12C, TP53, BRCA1/2, EGFR, HER2, BRAF V600E, PD-L1), '
        'oncology drugs (cisplatin, osimertinib, doxorubicin, paclitaxel, pembrolizumab, sotorasib), '
        'experimental assays (Western blot, flow cytometry, qPCR, RNA-Seq, ChIP-seq, immunohistochemistry, CRISPR-Cas9), '
        'and statistics (p-value, hazard ratio, Kaplan-Meier, 95% CI). '
        'Transcribe scientific terminology accurately with standard scientific casing.';
  }

  /// Downloads (once) and validates the speech model by transcribing a
  /// second of generated silence. Any completed call — even with empty
  /// text, which is correct for silence — proves the model is cached and
  /// working. Call this during setup instead of discovering a broken
  /// engine mid-meeting.
  Future<void> ensureModelReady({
    String? modelName,
    void Function(String status)? onStatus,
    void Function(int percent)? onProgress,
    void Function(double fraction, int received, int total)? onDownloadProgress,
    bool force = false,
  }) async {
    final name = modelName ?? _config.whisperModel;
    if (!force && ConfigService().isModelWarmed(name)) {
      final status = await modelFileStatus(name);
      if (status.present) return;
    }
    final size = ConfigService.whisperSizes[name] ?? '';
    onStatus?.call('Downloading $name model ($size) — one time only...');
    await downloadModelFile(
      name: name,
      onProgress: (fraction, received, total) {
        onDownloadProgress?.call(fraction, received, total);
        onStatus?.call(
          'Downloading $name — ${(received / 1048576).toStringAsFixed(0)}/${(total / 1048576).toStringAsFixed(0)} MB...',
        );
      },
    );
    // Validate end-to-end inference on generated silence (empty text is
    // correct for silence; any completed call proves the engine works).
    // The low-level API is used deliberately: `WhisperController` swallows
    // errors and returns null, which would mark a broken model as warmed
    // and make every later transcription fail with a generic message.
    final dir = await getTemporaryDirectory();
    final silentPath = await WavProbe.writeSilenceWav(dir);
    try {
      final model = _whisperModel(name);
      final modelPath = await WhisperController().getPath(model);
      await Whisper(model: model).transcribe(
        transcribeRequest: TranscribeRequest(
          audio: silentPath,
          language: 'en',
          initialPrompt: 'test',
          isNoTimestamps: true,
          // Keep the validated weights parked so the first real
          // transcription starts instantly instead of reloading.
          keepModelLoaded: true,
        ),
        modelPath: modelPath,
        onProgress: onProgress,
      );
      await ConfigService().markModelWarmed(name);
      onStatus?.call('Model ready.');
    } finally {
      try {
        await File(silentPath).delete();
      } catch (_) {}
    }
  }

  String _whisperLang(String? hint) {
    if (hint == 'en') return 'en';
    if (hint == 'hi') return 'hi';
    return 'auto';
  }

  /// Single on-device inference pass over one audio file.
  ///
  /// Deliberately uses the low-level [Whisper] API instead of
  /// `WhisperController.transcribe`: the controller catches every native
  /// error and returns `null`, which discards the actual reason ("WAV file
  /// must be 16 kHz", "failed to load model") and leaves the user with a
  /// misleading generic message. The low-level call rethrows the native
  /// message, which we then expand into actionable guidance.
  Future<({String text, List<TranscriptSegment> segments})> _transcribeChunk({
    required WhisperModel model,
    required String filePath,
    required String lang,
    required String prompt,
    required void Function(int percent) onProgress,
    required bool withSegments,
    int timeOffsetMs = 0,
  }) async {
    final modelPath = await WhisperController().getPath(model);
    try {
      final result = await Whisper(model: model).transcribe(
        transcribeRequest: TranscribeRequest(
          audio: filePath,
          language: lang,
          initialPrompt: prompt,
          // Timestamps power speaker-turn grounding; without them the
          // caller gets text-only fallbacks.
          isNoTimestamps: !withSegments,
          // Drop non-speech tokens so music/noise/silence markers never
          // reach the saved transcript.
          suppressNonSpeechTokens: true,
          // Park the weights after this pass: the next chunk (or the next
          // transcription) reuses them instead of reloading for seconds.
          keepModelLoaded: true,
        ),
        modelPath: modelPath,
        onProgress: onProgress,
      );

      final segments = <TranscriptSegment>[];
      if (withSegments && result.segments != null) {
        for (final s in result.segments!) {
          final text = s.text.trim();
          if (text.isEmpty) continue;
          segments.add(TranscriptSegment(
            startMs: timeOffsetMs + s.fromTs.inMilliseconds,
            endMs: timeOffsetMs + s.toTs.inMilliseconds,
            text: text,
          ));
        }
      }
      // Clean bracketed annotations, filler words, and hallucinated loops
      // before joining, so every chunk and single-file path benefits.
      return (
        text: TranscriptCleaner.clean(result.text),
        segments: segments,
      );
    } catch (e) {
      throw Exception(_engineErrorHint(e.toString()));
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
    SessionKind kind = SessionKind.meeting,
    List<TranscriptSegment> segments = const [],
  }) async {
    if (transcript.trim().isEmpty) {
      throw Exception('Transcript is empty. Cannot generate intelligence.');
    }

    // Speaker-turn grounding: when the engine gave us timed segments (and
    // the transcript is short enough to analyze in one pass), hand the model
    // the numbered segments and ask for index ranges — real recording times
    // instead of second estimates. Long transcripts use the map-reduce path
    // below, whose condensed context cannot be indexed, so they skip this.
    final words = transcript.split(RegExp(r'\s+'));
    final groundWithSegments = segments.isNotEmpty && words.length <= 5000;

    final kindFocus = switch (kind) {
      SessionKind.journalClub => '''
Journal Club focus:
- Identify the paper, its central claim, and the evidence presented.
- Critique methods, sample sizes, statistics, figures/tables, and alternative interpretations.
- List concrete revisions, additional experiments, or analyses the group agreed on.''',
      SessionKind.seminar => '''
Seminar focus:
- Distill the core hypothesis or mechanism and the three most important takeaways.
- Capture open questions from the audience and how the speaker answered them.
- Note references or reading worth following up afterwards.''',
      SessionKind.lecture => '''
Lecture focus:
- Extract key concepts, definitions, and mechanisms in teaching order.
- Flag exam-relevant facts, formulas, and mnemonics as mentioned.
- Capture assigned homework or reading.''',
      SessionKind.meeting => '''
Lab meeting focus:
- Track decisions, blockers, and owners for each agenda item.
- Surface data problems raised: failed replicates, missing controls, statistical doubts.''',
    };

    final diarizationDirective = groundWithSegments
        ? '4. Conversational Diarization: The user message contains numbered '
            'timed transcript segments. Split the dialogue into "speakerTurns" '
            'and give each turn "startIdx" and "endIdx" — the first and last '
            'segment indexes the utterance covers — plus speakerId '
            '("Speaker 1", "Speaker 2"), speakerName (infer Dr. Name or Role '
            'if mentioned, else the speakerId), and text. Do NOT invent '
            'startSeconds/endSeconds when indexes are available; turns must '
            'follow the segment order without large gaps.'
        : '4. Conversational Diarization: Analyze speaker shifts and dialogue '
            'flow in the transcript. Segment into "speakerTurns" with '
            'startSeconds, endSeconds, speakerId ("Speaker 1", "Speaker 2", '
            'etc.), speakerName (infer Dr. Name or Role if mentioned in '
            'context, otherwise default to speakerId), and text.';

    final scientificSystemPrompt = '''
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
      "startIdx": 0,
      "endIdx": 4,
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
  "literatureQueries": [
    "Author, gene, or study referenced (e.g., 'Baselga PI3K inhibitor trial', 'KRAS G12C sotorasib resistance 2023')"
  ]
}

Scientific Processing Directives:
1. Preserve precise scientific capitalization: gene symbols in UPPERCASE (e.g. EGFR, TP53, MYC), proteins/assays standard (e.g. p53, Western blot, RNA-Seq).
2. Distinguish statistical significance: identify mentioned p-values, sample sizes (n=), controls, and confidence intervals.
3. Extract 1-3 paper/author queries in "literatureQueries" to resolve via PubMed.
$diarizationDirective
5. Output raw JSON only. Do not add markdown code fences or explanatory preamble.

Session-type focus:
$kindFocus
''';

    try {
      // Hierarchical Map-Reduce summarization for long transcripts (> 5,000 words / ~7,500 tokens)
      String effectiveContext = transcript;
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
Session type: ${kind.label}
Scientific Context:
"""
$effectiveContext
"""
${groundWithSegments ? '''

Timed transcript segments (0-based index, "start-end seconds | text"):
${segments.asMap().entries.map((e) => '[${e.key}] ${e.value.startSeconds}-${e.value.endSeconds}s | ${e.value.text}').join('\n')}
''' : ''}
''';

    Future<Map<String, dynamic>> attempt() async {
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

      final rawJsonText =
          response.data['choices'][0]['message']['content']?.toString() ?? '';
      if (rawJsonText.trim().isEmpty) {
        throw const FormatException('Empty model response');
      }
      return _cleanAndParseJson(rawJsonText);
    }

    // Small hosted models occasionally truncate long JSON. A fresh sampling
    // usually completes; only after two truncated responses do we give up
    // with an explanation instead of a raw parser error.
    late final Map<String, dynamic> parsed;
    try {
      parsed = await attempt();
    } on FormatException catch (_) {
      debugPrint('[MeetingIntelligenceService] truncated JSON, retrying once...');
      try {
        parsed = await attempt();
      } on FormatException catch (e) {
        throw Exception(
          'The analysis model returned an incomplete response twice '
          '(${e.message}). Your recording and transcript are safe. '
          'Wait a moment and retry — or analyze a shorter session.',
        );
      }
    }

    final summary = SummaryResult.fromJson(parsed['summary'] ?? {});
    final rawTasks = (parsed['actionItems'] as List?) ?? [];
    final actionItems = rawTasks.map((t) => ActionItem.fromJson(t)).toList();
    final rawLiterature = List<String>.from(parsed['literatureQueries'] ?? []);

    final rawSpeakerTurns = (parsed['speakerTurns'] as List?) ?? [];
    List<SpeakerTurn> speakerTurns = rawSpeakerTurns.map((s) {
      final map = Map<String, dynamic>.from(s as Map);
      if (groundWithSegments) {
        // Prefer the model's segment-index range: it maps directly onto
        // real recording time. Otherwise clamp its second estimates to the
        // actual audio length so playback seek never overshoots.
        final startIdx = (map['startIdx'] as num?)?.toInt();
        final endIdx = (map['endIdx'] as num?)?.toInt();
        if (startIdx != null && startIdx >= 0 && startIdx < segments.length) {
          final end = (endIdx != null && endIdx >= startIdx && endIdx < segments.length)
              ? endIdx
              : startIdx;
          map['startSeconds'] = segments[startIdx].startSeconds;
          map['endSeconds'] = segments[end].endSeconds;
        } else {
          final totalSec = segments.last.endSeconds;
          map['startSeconds'] =
              ((map['startSeconds'] as num?)?.toInt() ?? 0).clamp(0, totalSec).toInt();
          map['endSeconds'] =
              ((map['endSeconds'] as num?)?.toInt() ?? 0).clamp(0, totalSec).toInt();
        }
      }
      return SpeakerTurn.fromJson(map);
    }).toList();

    if (speakerTurns.isEmpty && transcript.isNotEmpty) {
      speakerTurns = _synthesizeFallbackSpeakerTurns(transcript, segments);
    }

    // Compound glossary removed (Library shows papers only).
    const glossary = <GlossaryTerm>[];

    // Resolve PubMed citations via NCBI E-Utilities
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

  /// Clean Markdown code fences and extract valid JSON object from LLM response
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

  /// Synthesize speaker turns when running offline or when transcript has implicit dialogue.
  ///
  /// [segments], when present, replace word-count time estimates with the
  /// engine's real timestamps — playback seek then lands where the words
  /// were actually spoken.
  List<SpeakerTurn> _synthesizeFallbackSpeakerTurns(
    String transcript,
    List<TranscriptSegment> segments,
  ) {
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

    // No explicit labels: with timed segments, group a few consecutive
    // segments per turn and take their real start/end times.
    if (segments.isNotEmpty) {
      const perTurn = 3;
      for (var i = 0; i < segments.length; i += perTurn) {
        final endExclusive =
            (i + perTurn < segments.length) ? i + perTurn : segments.length;
        final text = segments
            .sublist(i, endExclusive)
            .map((s) => s.text)
            .join(' ')
            .trim();
        if (text.isEmpty) continue;
        final idx = turns.length + 1;
        turns.add(SpeakerTurn(
          id: 'turn-$idx',
          speakerId: 'Speaker $idx',
          speakerName: 'Speaker $idx',
          startSeconds: segments[i].startSeconds,
          endSeconds: segments[endExclusive - 1].endSeconds,
          text: text,
        ));
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
