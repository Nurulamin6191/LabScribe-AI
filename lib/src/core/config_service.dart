import 'package:shared_preferences/shared_preferences.dart';
import '../features/intelligence/services/meeting_intelligence_service.dart';

class ConfigService {
  static final ConfigService _instance = ConfigService._internal();
  factory ConfigService() => _instance;
  ConfigService._internal();

  late SharedPreferences _prefs;

  String openAiBaseUrl = 'http://localhost:11434/v1';
  String openAiApiKey = 'ollama';
  String llmModel = 'qwen2.5:3b';
  String transcriptionBaseUrl = 'http://localhost:8000/v1';
  String transcriptionApiKey = '';
  String transcriptionModel = 'whisper-large-v3-turbo';
  String libreTranslateBaseUrl = 'http://localhost:5000';
  bool isDemoMode = false;

  Future<void> loadConfig() async {
    _prefs = await SharedPreferences.getInstance();
    openAiBaseUrl = _prefs.getString('openAiBaseUrl') ?? 'http://localhost:11434/v1';
    openAiApiKey = _prefs.getString('openAiApiKey') ?? 'ollama';
    llmModel = _prefs.getString('llmModel') ?? 'qwen2.5:3b';
    transcriptionBaseUrl = _prefs.getString('transcriptionBaseUrl') ?? openAiBaseUrl;
    transcriptionApiKey = _prefs.getString('transcriptionApiKey') ?? openAiApiKey;
    transcriptionModel = _prefs.getString('transcriptionModel') ?? 'whisper-large-v3-turbo';
    libreTranslateBaseUrl = _prefs.getString('libreTranslateBaseUrl') ?? 'http://localhost:5000';
    isDemoMode = _prefs.getBool('isDemoMode') ?? false;
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
      isDemoMode: isDemoMode || openAiBaseUrl == 'demo' || transcriptionBaseUrl == 'demo',
    );
  }
}
