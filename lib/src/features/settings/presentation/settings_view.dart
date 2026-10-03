import 'package:flutter/material.dart';
import '../../../core/config_service.dart';
import 'package:dio/dio.dart';

class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _baseUrlController;
  late TextEditingController _apiKeyController;
  late TextEditingController _llmModelController;
  late TextEditingController _transcriptionBaseUrlController;
  late TextEditingController _transcriptionApiKeyController;
  late TextEditingController _transcriptionModelController;
  late TextEditingController _translateUrlController;
  
  String _selectedPreset = 'Local: Balanced (Qwen 2.5 7B + Faster-Whisper)';

  final List<String> _presets = [
    'Local: Balanced (Qwen 2.5 7B + Faster-Whisper)',
    'Local: Biomedical Specialist (BioMistral 7B + Faster-Whisper)',
    'Local: Ultra-Compact (Qwen 2.5 1.5B + Whisper Base)',
    'Lab Server: vLLM High-Throughput (Port 8000)',
    'Cloud: Groq Free Tier (Whisper Large-v3 + Llama 3.3)',
    'Cloud: OpenAI (Whisper-1 + GPT-4o-mini)',
    'Custom Endpoint',
  ];

  @override
  void initState() {
    super.initState();
    final config = ConfigService();
    _baseUrlController = TextEditingController(text: config.openAiBaseUrl);
    _apiKeyController = TextEditingController(text: config.openAiApiKey);
    _llmModelController = TextEditingController(text: config.llmModel);
    _transcriptionBaseUrlController = TextEditingController(text: config.transcriptionBaseUrl);
    _transcriptionApiKeyController = TextEditingController(text: config.transcriptionApiKey);
    _transcriptionModelController = TextEditingController(text: config.transcriptionModel);
    _translateUrlController = TextEditingController(text: config.libreTranslateBaseUrl);
    _determinePreset();
  }

  void _determinePreset() {
    final url = _baseUrlController.text;
    final model = _llmModelController.text;

    if (model.contains('biomistral')) {
      _selectedPreset = 'Local: Biomedical Specialist (BioMistral 7B + Faster-Whisper)';
    } else if (url.contains('localhost:11434') && model.contains('1.5b')) {
      _selectedPreset = 'Local: Ultra-Compact (Qwen 2.5 1.5B + Whisper Base)';
    } else if (url.contains('localhost:11434')) {
      _selectedPreset = 'Local: Balanced (Qwen 2.5 7B + Faster-Whisper)';
    } else if (url.contains(':8000')) {
      _selectedPreset = 'Lab Server: vLLM High-Throughput (Port 8000)';
    } else if (url.contains('api.groq.com')) {
      _selectedPreset = 'Cloud: Groq Free Tier (Whisper Large-v3 + Llama 3.3)';
    } else if (url.contains('api.openai.com')) {
      _selectedPreset = 'Cloud: OpenAI (Whisper-1 + GPT-4o-mini)';
    } else {
      _selectedPreset = 'Custom Endpoint';
    }
  }

  void _applyPreset(String preset) {
    setState(() {
      _selectedPreset = preset;
      if (preset == 'Local: Balanced (Qwen 2.5 7B + Faster-Whisper)') {
        _baseUrlController.text = 'http://localhost:11434/v1';
        _apiKeyController.text = 'ollama';
        _llmModelController.text = 'qwen2.5:7b';
        _transcriptionBaseUrlController.text = 'http://localhost:8000/v1';
        _transcriptionApiKeyController.text = '';
        _transcriptionModelController.text = 'whisper-large-v3-turbo';
      } else if (preset == 'Local: Biomedical Specialist (BioMistral 7B + Faster-Whisper)') {
        _baseUrlController.text = 'http://localhost:11434/v1';
        _apiKeyController.text = 'ollama';
        _llmModelController.text = 'biomistral:7b';
        _transcriptionBaseUrlController.text = 'http://localhost:8000/v1';
        _transcriptionApiKeyController.text = '';
        _transcriptionModelController.text = 'whisper-large-v3-turbo';
      } else if (preset == 'Local: Ultra-Compact (Qwen 2.5 1.5B + Whisper Base)') {
        _baseUrlController.text = 'http://localhost:11434/v1';
        _apiKeyController.text = 'ollama';
        _llmModelController.text = 'qwen2.5:1.5b';
        _transcriptionBaseUrlController.text = 'http://localhost:11434/v1';
        _transcriptionApiKeyController.text = 'ollama';
        _transcriptionModelController.text = 'whisper-base';
      } else if (preset == 'Lab Server: vLLM High-Throughput (Port 8000)') {
        _baseUrlController.text = 'http://localhost:8000/v1';
        _apiKeyController.text = 'EMPTY';
        _llmModelController.text = 'Qwen/Qwen2.5-7B-Instruct';
        _transcriptionBaseUrlController.text = 'http://localhost:8000/v1';
        _transcriptionApiKeyController.text = '';
        _transcriptionModelController.text = 'whisper-large-v3-turbo';
      } else if (preset == 'Cloud: Groq Free Tier (Whisper Large-v3 + Llama 3.3)') {
        _baseUrlController.text = 'https://api.groq.com/openai/v1';
        _apiKeyController.clear();
        _llmModelController.text = 'llama-3.3-70b-versatile';
        _transcriptionBaseUrlController.text = 'https://api.groq.com/openai/v1';
        _transcriptionApiKeyController.clear();
        _transcriptionModelController.text = 'whisper-large-v3';
      } else if (preset == 'Cloud: OpenAI (Whisper-1 + GPT-4o-mini)') {
        _baseUrlController.text = 'https://api.openai.com/v1';
        _apiKeyController.clear();
        _llmModelController.text = 'gpt-4o-mini';
        _transcriptionBaseUrlController.text = 'https://api.openai.com/v1';
        _transcriptionApiKeyController.clear();
        _transcriptionModelController.text = 'whisper-1';
      }
    });
  }

  Future<void> _saveConfig() async {
    if (_formKey.currentState!.validate()) {
      await ConfigService().saveConfig(
        openAiBaseUrl: _baseUrlController.text,
        openAiApiKey: _apiKeyController.text,
        llmModel: _llmModelController.text,
        transcriptionBaseUrl: _transcriptionBaseUrlController.text,
        transcriptionApiKey: _transcriptionApiKeyController.text,
        transcriptionModel: _transcriptionModelController.text,
        libreTranslateBaseUrl: _translateUrlController.text,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Model configuration saved successfully!')),
        );
      }
    }
  }

  Future<void> _testConnection() async {
    try {
      final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 5)));
      final response = await dio.get(
        '${_baseUrlController.text}/models',
        options: Options(
          headers: _apiKeyController.text.isNotEmpty
              ? {'Authorization': 'Bearer ${_apiKeyController.text}'}
              : {},
        ),
      );
      if (response.statusCode == 200 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('LLM Endpoint Connection Successful!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('LLM connection notice: $e (Ollama / vLLM may omit /models)')),
        );
      }
    }
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _llmModelController.dispose();
    _transcriptionBaseUrlController.dispose();
    _transcriptionApiKeyController.dispose();
    _transcriptionModelController.dispose();
    _translateUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Model & Engine Settings'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20.0),
          children: [
            const Text(
              'Select Inference Architecture & Model Tier',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 6),
            const Text(
              'Choose between local private offline engines (Ollama / vLLM) or high-speed cloud APIs.',
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _selectedPreset,
              decoration: const InputDecoration(
                labelText: 'Configuration Preset',
                border: OutlineInputBorder(),
              ),
              items: _presets
                  .map((preset) => DropdownMenuItem(value: preset, child: Text(preset, style: const TextStyle(fontSize: 13))))
                  .toList(),
              onChanged: (value) {
                if (value != null) _applyPreset(value);
              },
            ),
            const SizedBox(height: 24),
            const Text('LLM Reasoning Engine (Hypotheses, Summaries & Tasks)', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            TextFormField(
              controller: _baseUrlController,
              decoration: const InputDecoration(
                labelText: 'LLM API Base URL',
                hintText: 'e.g. http://localhost:11434/v1 or http://localhost:8000/v1',
                border: OutlineInputBorder(),
              ),
              validator: (value) => value!.isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _apiKeyController,
              decoration: const InputDecoration(
                labelText: 'LLM API Key (use "ollama" for local)',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _llmModelController,
              decoration: const InputDecoration(
                labelText: 'LLM Model Name',
                hintText: 'qwen2.5:7b, biomistral:7b, qwen2.5:1.5b, or llama-3.3-70b-versatile',
                border: OutlineInputBorder(),
              ),
              validator: (value) => value!.isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 24),
            const Text('Speech-To-Text Engine (Whisper & Audio Transcripts)', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            TextFormField(
              controller: _transcriptionBaseUrlController,
              decoration: const InputDecoration(
                labelText: 'Transcription Endpoint URL',
                hintText: 'e.g. http://localhost:8000/v1 or https://api.groq.com/openai/v1',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _transcriptionModelController,
              decoration: const InputDecoration(
                labelText: 'Transcription Model Name',
                hintText: 'whisper-large-v3-turbo, whisper-large-v3, whisper-base',
                border: OutlineInputBorder(),
              ),
              validator: (value) => value!.isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 24),
            const Text('Linguistic & Translation Engine', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            TextFormField(
              controller: _translateUrlController,
              decoration: const InputDecoration(
                labelText: 'LibreTranslate URL',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 32),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _testConnection,
                    icon: const Icon(Icons.wifi_tethering),
                    label: const Text('Test Connection'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _saveConfig,
                    icon: const Icon(Icons.save),
                    label: const Text('Save Settings'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
