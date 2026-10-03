import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'src/features/intelligence/services/meeting_intelligence_service.dart';
import 'src/features/public_apis/services/public_api_service.dart';
import 'src/features/recorder/presentation/recorder_view.dart';
import 'src/core/config_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize SQLite FFI on Windows and Linux desktop targets
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // Instantiate core domain services
  final publicApiService = PublicApiService();
  
  final configService = ConfigService();
  await configService.loadConfig();

  final intelligenceService = MeetingIntelligenceService(
    config: configService.getAiConfig(),
    publicApiService: publicApiService,
  );

  runApp(LabScribeApp(
    intelligenceService: intelligenceService,
    publicApiService: publicApiService,
  ));
}

class LabScribeApp extends StatelessWidget {
  final MeetingIntelligenceService intelligenceService;
  final PublicApiService publicApiService;

  const LabScribeApp({
    super.key,
    required this.intelligenceService,
    required this.publicApiService,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LabScribe AI — Scientific Meeting & Research Companion',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
      ),
      home: RecorderView(
        intelligenceService: intelligenceService,
        publicApiService: publicApiService,
      ),
    );
  }
}
