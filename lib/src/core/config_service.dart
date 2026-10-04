import 'package:shared_preferences/shared_preferences.dart';
import '../features/intelligence/services/meeting_intelligence_service.dart';

/// Minimal app configuration.
///
/// Install-and-use design: transcription runs on-device (Whisper) and
/// synthesis uses a keyless hosted open model. The only persisted choice
/// is the Whisper model size. There are no endpoints, keys, or URLs to
/// configure.
class ConfigService {
  static final ConfigService _instance = ConfigService._internal();
  factory ConfigService() => _instance;
  ConfigService._internal();

  late SharedPreferences _prefs;

  /// 'tiny' (75 MB, fastest), 'base' (150 MB, balanced), 'small' (460 MB, accurate)
  String whisperModel = 'base';

  Future<void> loadConfig() async {
    _prefs = await SharedPreferences.getInstance();
    whisperModel = _prefs.getString('whisperModel') ?? 'base';
    if (!['tiny', 'base', 'small'].contains(whisperModel)) {
      whisperModel = 'base';
    }
  }

  Future<void> setWhisperModel(String model) async {
    whisperModel = model;
    await _prefs.setString('whisperModel', whisperModel);
  }

  AiConfig getAiConfig() {
    return AiConfig(whisperModel: whisperModel);
  }
}
