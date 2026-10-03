import 'package:shared_preferences/shared_preferences.dart';
import '../features/intelligence/services/meeting_intelligence_service.dart';

class ConfigService {
  static final ConfigService _instance = ConfigService._internal();
  factory ConfigService() => _instance;
  ConfigService._internal();

  late SharedPreferences _prefs;

  String openAiBaseUrl = 'https://text.pollinations.ai/openai';
  String openAiApiKey = 'zero-setup';
  String llmModel = 'openai-fast';
  String transcriptionBaseUrl = '';
  String transcriptionApiKey = '';
  String transcriptionModel = 'whisper-large-v3';
  String libreTranslateBaseUrl = 'http://localhost:5000';
  bool isDemoMode = false;

  Future<void> loadConfig() async {
    _prefs = await SharedPreferences.getInstance();
    openAiBaseUrl = _prefs.getString('openAiBaseUrl') ?? 'https://text.pollinations.ai/openai';
    openAiApiKey = _prefs.getString('openAiApiKey') ?? 'zero-setup';
    llmModel = _prefs.getString('llmModel') ?? 'openai-fast';
    transcriptionBaseUrl = _prefs.getString('transcriptionBaseUrl') ?? '';
    transcriptionApiKey = _prefs.getString('transcriptionApiKey') ?? '';
    transcriptionModel = _prefs.getString('transcriptionModel') ?? 'whisper-large-v3';
    libreTranslateBaseUrl = _prefs.getString('libreTranslateBaseUrl') ?? 'http://localhost:5000';
    isDemoMode = _prefs.getBool('isDemoMode') ?? false;

    // Reset stale demo placeholders so real transcription is attempted or prompted
    if (transcriptionBaseUrl == 'demo') transcriptionBaseUrl = '';
    if (transcriptionApiKey == 'demo') transcriptionApiKey = '';
  }

  Future<void> saveConfig({
    required String openAiBaseUrl,
    required String openAiApiKey,
    required String llmModel,
    String? transcriptionBaseUrl,
    String? transcriptionApiKey,
    required String transcriptionModel,
    required String libreTranslateBaseUrl,
    bool isDemoMode = false,
  }) async {
    this.openAiBaseUrl = openAiBaseUrl;
    this.openAiApiKey = openAiApiKey;
    this.llmModel = llmModel;
    this.transcriptionBaseUrl = transcriptionBaseUrl ?? openAiBaseUrl;
    this.transcriptionApiKey = transcriptionApiKey ?? openAiApiKey;
    this.transcriptionModel = transcriptionModel;
    this.libreTranslateBaseUrl = libreTranslateBaseUrl;
    this.isDemoMode = isDemoMode;

    await _prefs.setString('openAiBaseUrl', this.openAiBaseUrl);
    await _prefs.setString('openAiApiKey', this.openAiApiKey);
    await _prefs.setString('llmModel', this.llmModel);
    await _prefs.setString('transcriptionBaseUrl', this.transcriptionBaseUrl);
    await _prefs.setString('transcriptionApiKey', this.transcriptionApiKey);
    await _prefs.setString('transcriptionModel', this.transcriptionModel);
    await _prefs.setString('libreTranslateBaseUrl', this.libreTranslateBaseUrl);
    await _prefs.setBool('isDemoMode', this.isDemoMode);
  }

  AiConfig getAiConfig() {
    return AiConfig(
      openAiApiKey: openAiApiKey,
      openAiBaseUrl: openAiBaseUrl,
      transcriptionBaseUrl: transcriptionBaseUrl,
      transcriptionApiKey: transcriptionApiKey,
      transcriptionModel: transcriptionModel,
      llmModel: llmModel,
      isDemoMode: isDemoMode || openAiBaseUrl == 'demo',
    );
  }
}
