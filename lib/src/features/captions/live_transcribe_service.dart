import 'package:speech_to_text/speech_to_text.dart';

/// On-device live transcription for the "Live" capture mode.
///
/// Uses the OS speech recognizer (Android / iOS / Windows / macOS) with no
/// API keys, no uploads, and no configuration. Linux is unsupported by the
/// plugin, so callers must check [isPlatformSupported] and hide live mode.
///
/// Design notes (from plugin docs):
/// - Only `initialize`, `listen(onResult:, localeId:)`, `stop`, `cancel`,
///   `isListening`, and `locales` are used — the long-stable API surface.
/// - The OS ends sessions after pauses/time limits with status `done`;
///   the caller restarts listening to capture continuously.
/// - Recording audio and recognizing simultaneously conflict on Android,
///   which is why Live mode captures captions INSTEAD of a file.
typedef LiveTextCallback = void Function(String words);
typedef LiveStatusCallback = void Function(String status);

class LiveTranscribeService {
  final SpeechToText _speech = SpeechToText();
  bool _ready = false;

  LiveStatusCallback? onStatusChanged;

  bool get isReady => _ready;

  bool get isListening {
    try {
      return _speech.isListening;
    } catch (_) {
      return false;
    }
  }

  Future<bool> init() async {
    try {
      _ready = await _speech.initialize(
        onStatus: (status) => onStatusChanged?.call(status),
        onError: (_) {},
      );
    } catch (_) {
      _ready = false;
    }
    return _ready;
  }

  Future<List<String>> localeIds() async {
    try {
      final locales = await _speech.locales();
      return locales.map((e) => e.localeId).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<bool> start({String? localeId, LiveTextCallback? onResult}) async {
    if (!_ready) return false;
    try {
      if (localeId != null && localeId.isNotEmpty) {
        return await _speech.listen(
          onResult: (result) => onResult?.call(result.recognizedWords),
          localeId: localeId,
        );
      }
      return await _speech.listen(
        onResult: (result) => onResult?.call(result.recognizedWords),
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> stop() async {
    try {
      await _speech.stop();
    } catch (_) {}
  }

  Future<void> cancel() async {
    try {
      await _speech.cancel();
    } catch (_) {}
  }
}
