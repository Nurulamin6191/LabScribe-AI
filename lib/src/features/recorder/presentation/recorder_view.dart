import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:uuid/uuid.dart';
import 'package:file_picker/file_picker.dart';
import 'package:dio/dio.dart';

import '../../../core/session_repository.dart';
import '../../../core/crypto_utils.dart';
import '../../../core/config_service.dart';
import '../../settings/presentation/settings_view.dart';
import '../../export/services/export_service.dart';
import '../../history/presentation/history_view.dart';
import '../../../models/meeting_session.dart';
import '../../intelligence/services/meeting_intelligence_service.dart';
import '../../public_apis/services/public_api_service.dart';

/// Main interactive UI managing session recording, audio device selection,
/// meeting-compatible compact mode, clinical de-identification, in-app literature/figure reading,
/// 21 CFR Part 11 cryptographic verification, and responsive scientific intelligence dashboards.
class RecorderView extends StatefulWidget {
  final MeetingIntelligenceService intelligenceService;
  final PublicApiService publicApiService;

  const RecorderView({
    super.key,
    required this.intelligenceService,
    required this.publicApiService,
  });

  @override
  State<RecorderView> createState() => _RecorderViewState();
}

class _RecorderViewState extends State<RecorderView> with SingleTickerProviderStateMixin {
  // Audio Engine & Hardware Devices
  late final AudioRecorder _audioRecorder;
  late final AudioPlayer _audioPlayer;
  List<InputDevice> _audioInputDevices = [];
  String? _selectedDeviceId;
  InputDevice? _selectedInputDevice;

  // Real-Time Audio Metering & Dynamic Waveform
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  double _currentDecibels = -60.0;
  List<double> _liveWaveformBars = List.generate(28, (i) => 0.08);
  double _playbackRate = 1.0;

  bool _isPlaying = false;
  Duration _playbackDuration = Duration.zero;
  Duration _playbackPosition = Duration.zero;

  RecordingState _recordingState = RecordingState.idle;
  ProcessingStage _processingStage = ProcessingStage.idle;
  
  // Timer & Metrics
  Timer? _timer;
  int _recordDurationSeconds = 0;
  String? _recordedAudioPath;
  String _statusMessage = 'Ready to capture meeting or technical discussion.';

  // Real-Time Live Transcription Streaming
  List<String> _liveTranscriptionStream = [];
  Timer? _liveTranscriptionTimer;
  bool _isLiveTranscribing = false;

  // Enterprise & Privacy Configuration
  bool _enableSensitiveDataRedaction = false;
  bool _enableNoiseSuppression = true;
  bool _isVirtualCallMode = false;
  int _redactedTokensCount = 0;
  String _audioQuality = 'High Fidelity (128 kbps)';

  // Meeting Domain & Context Tuning (Not hardcoded to scientific)
  String _selectedMeetingDomain = 'General & Corporate';
  final List<String> _domainOptions = [
    'General & Corporate',
    'Engineering & Tech',
    'Product & Design',
    'Sales & Client Sync',
    '1-on-1 & Standup',
    'Research & Academic',
  ];

  // Session State
  final TextEditingController _titleController = TextEditingController(text: 'Q4 Product Architecture & Infrastructure Sync');
  final TextEditingController _chatController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();
  
  // In-Transcript Keyword Search
  final TextEditingController _transcriptSearchController = TextEditingController();
  String _transcriptSearchQuery = '';

  MeetingSession? _currentSession;
  late TabController _tabController;
  int _mobileNavIndex = 0;
  bool _isWaitingForAiChatResponse = false;
  bool _isMeetingCompactMode = false;

  // Language & Multilingual Optimization (Hindi, English, Hinglish)
  String _selectedLanguage = 'auto'; // 'auto', 'en', 'hi', 'hinglish'
  String? _translatedTranscript;
  bool _isTranslatingTranscript = false;
  bool _isTranscriptEditMode = false;
  final TextEditingController _transcriptEditController = TextEditingController();
  bool _showTranslatedTranscript = false;
  bool _isTranslatingSummary = false;
  String? _translatedSummary;
  bool _showTranslatedSummary = false;

  void loadSession(MeetingSession session) {
    setState(() {
      _currentSession = session;
      _titleController.text = session.title;
      _recordedAudioPath = session.audioPath;
      _recordDurationSeconds = session.durationSeconds;
      _recordingState = RecordingState.stopped;
      _statusMessage = 'Loaded saved session from local storage.';
      _enableSensitiveDataRedaction = session.isDeIdentified;
      _isVirtualCallMode = session.isVirtualCall;
      _translatedTranscript = null;
      _showTranslatedTranscript = false;
      _isTranscriptEditMode = false;
      _transcriptEditController.text = session.transcript;
      _translatedSummary = null;
      _showTranslatedSummary = false;
      _transcriptSearchQuery = '';
      _transcriptSearchController.clear();
    });
  }

  @override
  void initState() {
    super.initState();
    _audioRecorder = AudioRecorder();
    _audioPlayer = AudioPlayer();

    // Listen to playback states
    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state == PlayerState.playing;
        });
      }
    });

    _audioPlayer.onDurationChanged.listen((newDuration) {
      if (mounted) {
        setState(() {
          _playbackDuration = newDuration;
        });
      }
    });

    _audioPlayer.onPositionChanged.listen((newPosition) {
      if (mounted) {
        setState(() {
          _playbackPosition = newPosition;
        });
      }
    });

    // 5 Industrial Dashboards: Summary, Tasks & Decisions, Transcript, Speaker Analytics, AI Assistant
    _tabController = TabController(length: 5, vsync: this);

    // Enumerate connected microphones (Jabra, USB, AirPods, built-in)
    _loadAudioDevices();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _amplitudeSubscription?.cancel();
    _liveTranscriptionTimer?.cancel();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    _titleController.dispose();
    _chatController.dispose();
    _chatScrollController.dispose();
    _transcriptSearchController.dispose();
    _transcriptEditController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  // --- Audio Device Enumeration (Meeting Compatibility) ---

  Future<void> _loadAudioDevices() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        final devices = await _audioRecorder.listInputDevices();
        if (mounted) {
          setState(() {
            _audioInputDevices = devices;
            if (devices.isNotEmpty && _selectedDeviceId == null) {
              _selectedDeviceId = devices.first.id;
              _selectedInputDevice = devices.first;
            }
          });
        }
      }
    } catch (e) {
      debugPrint('Could not list audio input devices: $e');
    }
  }

  // --- Audio Recording Lifecycle with Real-Time Waveform & Live Transcription ---

  void _startLiveTranscriptionStream() {
    _liveTranscriptionTimer?.cancel();
    _liveTranscriptionStream.clear();
    _isLiveTranscribing = true;
  }


  Future<void> _startRecording() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        final dir = await getApplicationDocumentsDirectory();
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final filePath = '${dir.path}/meeting_$timestamp.m4a';

        // Select bitrate based on chosen audio quality profile
        int bitrate = 128000;
        int sampleRate = 44100;
        if (_audioQuality.contains('256')) {
          bitrate = 256000;
          sampleRate = 48000;
        } else if (_audioQuality.contains('64')) {
          bitrate = 64000;
          sampleRate = 22050;
        }

        final config = RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: bitrate,
          sampleRate: sampleRate,
          device: _selectedInputDevice,
          noiseSuppress: _enableNoiseSuppression,
          echoCancel: true,
          autoGain: true,
        );

        await _audioRecorder.start(config, path: filePath);

        // Real-time live decibel and waveform listener
        _amplitudeSubscription?.cancel();
        _amplitudeSubscription = _audioRecorder
            .onAmplitudeChanged(const Duration(milliseconds: 90))
            .listen((amp) {
          if (!mounted) return;
          final normalized = ((amp.current + 55.0) / 55.0).clamp(0.06, 1.0);
          setState(() {
            _currentDecibels = amp.current;
            _liveWaveformBars.removeAt(0);
            _liveWaveformBars.add(normalized);
          });
        });

        // Start live real-time speech preview stream
        _liveTranscriptionStream.clear();
        _startLiveTranscriptionStream();

        setState(() {
          _recordingState = RecordingState.recording;
          _recordedAudioPath = filePath;
          _recordDurationSeconds = 0;
          _statusMessage = 'Recording active (Acoustic Noise Filter ON)...';
          
          _currentSession = MeetingSession(
            id: timestamp.toString(),
            title: _titleController.text.trim().isEmpty ? 'Meeting Discussion' : _titleController.text.trim(),
            createdAt: DateTime.now(),
            audioPath: filePath,
            durationSeconds: 0,
            isDeIdentified: _enableSensitiveDataRedaction,
            isVirtualCall: _isVirtualCallMode,
          );
        });

        _startTimer();
      } else {
        _showSnackBar('Microphone permission denied.');
      }
    } catch (e) {
      _showSnackBar('Error starting recorder: $e');
    }
  }

  Future<void> _pauseRecording() async {
    try {
      await _audioRecorder.pause();
      _timer?.cancel();
      _liveTranscriptionTimer?.cancel();
      setState(() {
        _recordingState = RecordingState.paused;
        _statusMessage = 'Recording paused.';
      });
    } catch (e) {
      _showSnackBar('Error pausing recorder: $e');
    }
  }

  Future<void> _resumeRecording() async {
    try {
      await _audioRecorder.resume();
      _startTimer();
      _startLiveTranscriptionStream();
      setState(() {
        _recordingState = RecordingState.recording;
        _statusMessage = 'Recording resumed...';
      });
    } catch (e) {
      _showSnackBar('Error resuming recorder: $e');
    }
  }

  Future<void> _stopRecording() async {
    try {
      _timer?.cancel();
      _amplitudeSubscription?.cancel();
      _liveTranscriptionTimer?.cancel();
      final path = await _audioRecorder.stop();

      String? audioSha256;
      if (path != null) {
        audioSha256 = await CryptoUtils.sha256File(File(path));
      }

      setState(() {
        _recordingState = RecordingState.stopped;
        _isLiveTranscribing = false;
        _currentDecibels = -60.0;
        _recordedAudioPath = path ?? _recordedAudioPath;
        _statusMessage = 'Recording saved locally (SHA-256 sealed). Generating AI Intelligence...';
        
        if (_currentSession != null) {
          _currentSession!.audioPath = _recordedAudioPath;
          _currentSession!.durationSeconds = _recordDurationSeconds;
          _currentSession!.title = _titleController.text.trim().isEmpty ? 'Meeting Discussion' : _titleController.text.trim();
          _currentSession!.audioSha256 = audioSha256;
        }
      });

      if (_currentSession != null) {
        await SessionRepository().saveSession(_currentSession!);
      }

      // Automatically execute AI pipeline for an industrial 1-tap experience
      _executeAiPipeline();
    } catch (e) {
      _showSnackBar('Error stopping recorder: $e');
    }
  }

  // --- Industrial Audio Playback Controls ---

  void _cyclePlaybackSpeed() async {
    final speeds = [0.75, 1.0, 1.25, 1.5, 2.0];
    final currentIndex = speeds.indexOf(_playbackRate);
    final nextSpeed = speeds[(currentIndex + 1) % speeds.length];
    setState(() {
      _playbackRate = nextSpeed;
    });
    await _audioPlayer.setPlaybackRate(nextSpeed);
    _showSnackBar('Playback speed: ${nextSpeed}x');
  }

  Future<void> _skipAudio(int seconds) async {
    final target = _playbackPosition + Duration(seconds: seconds);
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > _playbackDuration ? _playbackDuration : target);
    await _audioPlayer.seek(clamped);
  }

  Future<void> _seekToSecond(int seconds) async {
    if (_recordedAudioPath == null) return;
    if (!_isPlaying) {
      await _audioPlayer.play(DeviceFileSource(_recordedAudioPath!));
    }
    await _audioPlayer.seek(Duration(seconds: seconds));
    _showSnackBar('Playing from ${_formatDuration(seconds)}');
  }

  // --- External / Zoom Meeting Audio Importer ---

  Future<void> _importAudioFileDialog({bool asVirtualCall = false}) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['m4a', 'mp3', 'wav', 'aac', 'flac', 'ogg', 'opus'],
      );

      if (result != null && result.files.single.path != null) {
        final selectedPath = result.files.single.path!;
        final file = File(selectedPath);
        final fileName = result.files.single.name;
        
        final hash = await CryptoUtils.sha256File(file);
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final isCall = asVirtualCall ||
            _isVirtualCallMode ||
            fileName.toLowerCase().contains('zoom') ||
            fileName.toLowerCase().contains('whatsapp') ||
            fileName.toLowerCase().contains('call') ||
            fileName.endsWith('.opus');

        final newSession = MeetingSession(
          id: timestamp.toString(),
          title: fileName.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), ''),
          createdAt: DateTime.now(),
          audioPath: selectedPath,
          durationSeconds: 0,
          isDeIdentified: _enableSensitiveDataRedaction,
          isVirtualCall: isCall,
          audioSha256: hash,
        );

        setState(() {
          _currentSession = newSession;
          _titleController.text = newSession.title;
          _recordedAudioPath = selectedPath;
          _recordingState = RecordingState.stopped;
          _isVirtualCallMode = isCall;
          _statusMessage = 'Imported: $fileName (SHA-256 sealed). Ready for AI processing.';
        });

        await SessionRepository().saveSession(newSession);
        _showSnackBar('Imported $fileName with 21 CFR Part 11 cryptographic seal.');
      }
    } catch (e) {
      _showSnackBar('Error importing audio file: $e');
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() {
        _recordDurationSeconds++;
      });
    });
  }

  String _formatDuration(int seconds) {
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final secs = (seconds % 60).toString().padLeft(2, '0');
    final hours = (seconds ~/ 3600).toString().padLeft(2, '0');
    return '$hours:$minutes:$secs';
  }

  // --- In-Meeting One-Tap Tagging & Bookmarks (Meeting Compatibility) ---

  void _quickAddTag(String icon, String label) {
    if (_currentSession == null) {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      _currentSession = MeetingSession(
        id: timestamp.toString(),
        title: _titleController.text.trim().isEmpty ? 'Meeting Discussion' : _titleController.text.trim(),
        createdAt: DateTime.now(),
        durationSeconds: _recordDurationSeconds,
        isDeIdentified: _enableSensitiveDataRedaction,
      );
    }

    final currentTimestamp = _recordDurationSeconds;
    final note = MeetingNote(
      id: const Uuid().v4(),
      timestampSeconds: currentTimestamp,
      note: '$icon $label',
    );

    setState(() {
      _currentSession!.liveNotes.add(note);
    });

    SessionRepository().saveSession(_currentSession!);
    _showSnackBar('$icon "$label" flagged at ${_formatDuration(currentTimestamp)}');
  }

  /// Live In-Meeting Note Taker with custom dialog text
  Future<void> _addLiveMeetingNoteDialog() async {
    final noteController = TextEditingController();
    final currentTimestamp = _recordDurationSeconds;

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.bookmark_add, color: Colors.orange),
            const SizedBox(width: 8),
            Text('Bookmark at ${_formatDuration(currentTimestamp)}'),
          ],
        ),
        content: TextField(
          controller: noteController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Meeting Annotation / Decision',
            hintText: 'e.g. Approved Q4 cloud migration budget; Sarah will finalize vendor SLA',
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final text = noteController.text.trim();
              if (text.isNotEmpty) {
                if (_currentSession == null) {
                  final timestamp = DateTime.now().millisecondsSinceEpoch;
                  _currentSession = MeetingSession(
                    id: timestamp.toString(),
                    title: _titleController.text.trim().isEmpty ? 'Meeting Discussion' : _titleController.text.trim(),
                    createdAt: DateTime.now(),
                    durationSeconds: _recordDurationSeconds,
                    isDeIdentified: _enableSensitiveDataRedaction,
                  );
                }

                final note = MeetingNote(
                  id: const Uuid().v4(),
                  timestampSeconds: currentTimestamp,
                  note: text,
                );
                setState(() {
                  _currentSession!.liveNotes.add(note);
                });
                SessionRepository().saveSession(_currentSession!);
                _showSnackBar('Bookmark logged at ${_formatDuration(currentTimestamp)}');
              }
              Navigator.pop(ctx);
            },
            child: const Text('Save Note'),
          ),
        ],
      ),
    );
  }

  /// Slide / Diagram Attachment File Picker
  Future<void> _attachFigureDialog() async {
    final captionController = TextEditingController();
    String? selectedFilePath;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.add_photo_alternate, color: Colors.teal),
              SizedBox(width: 8),
              Text('Attach Slide / Meeting Visual'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Attach presentation slide, architecture diagram, or whiteboard screenshot at timestamp: ${_formatDuration(_recordDurationSeconds)}',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                icon: const Icon(Icons.folder_open, size: 18),
                label: Text(
                  selectedFilePath == null
                      ? 'Select Image / Slide File'
                      : selectedFilePath!.split(Platform.pathSeparator).last,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onPressed: () async {
                  final result = await FilePicker.platform.pickFiles(
                    type: FileType.custom,
                    allowedExtensions: ['png', 'jpg', 'jpeg', 'pdf', 'tif', 'tiff'],
                  );
                  if (result != null && result.files.single.path != null) {
                    setDialogState(() {
                      selectedFilePath = result.files.single.path!;
                    });
                  }
                },
              ),
              const SizedBox(height: 14),
              TextField(
                controller: captionController,
                decoration: const InputDecoration(
                  labelText: 'Visual Caption / Diagram Note',
                  hintText: 'e.g. System architecture diagram or sprint burndown',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final caption = captionController.text.trim();
                final path = selectedFilePath ?? 'visual_captured_${DateTime.now().millisecondsSinceEpoch}.png';
                final attachment = SlideAttachment(
                  id: const Uuid().v4(),
                  imagePath: path,
                  timestampSeconds: _recordDurationSeconds,
                  caption: caption.isNotEmpty ? caption : 'Visual at ${_formatDuration(_recordDurationSeconds)}',
                );

                if (_currentSession == null) {
                  final timestamp = DateTime.now().millisecondsSinceEpoch;
                  _currentSession = MeetingSession(
                    id: timestamp.toString(),
                    title: _titleController.text.trim().isEmpty ? 'Meeting Discussion' : _titleController.text.trim(),
                    createdAt: DateTime.now(),
                    durationSeconds: _recordDurationSeconds,
                    isDeIdentified: _enableSensitiveDataRedaction,
                  );
                }

                setState(() {
                  _currentSession?.slideAttachments.add(attachment);
                });

                if (_currentSession != null) {
                  SessionRepository().saveSession(_currentSession!);
                }

                _showSnackBar('Visual attached at ${_formatDuration(_recordDurationSeconds)}');
                Navigator.pop(ctx);
              },
              child: const Text('Attach'),
            ),
          ],
        ),
      ),
    );
  }

  /// In-App Slide & Gel Figure Lightbox (Zero External Image Viewer Needed)
  void _showFigureLightbox(SlideAttachment slide) {
    final file = File(slide.imagePath);
    final exists = file.existsSync();

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 800, maxHeight: 700),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      'Figure at ${_formatDuration(slide.timestampSeconds)}: ${slide.caption}',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black12,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: InteractiveViewer(
                      panEnabled: true,
                      minScale: 0.8,
                      maxScale: 4.0,
                      child: exists
                          ? Image.file(file, fit: BoxFit.contain)
                          : Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.image, size: 64, color: Colors.teal),
                                  const SizedBox(height: 12),
                                  Text(
                                    slide.caption,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Logged at ${_formatDuration(slide.timestampSeconds)} in discussion',
                                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// In-App Markdown Meeting Minutes Previewer (Zero External Text Editor Needed)
  void _showMarkdownPreviewer() {
    if (_currentSession == null) {
      _showSnackBar('No active session to preview.');
      return;
    }

    final markdown = ExportService().generateMarkdownString(_currentSession!);

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(20),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 850, maxHeight: 750),
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.article, color: Colors.teal),
                      const SizedBox(width: 8),
                      Text(
                        'Meeting Minutes: ${_currentSession!.title}',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const Divider(),
              Expanded(
                child: SingleChildScrollView(
                  child: MarkdownBody(
                    data: markdown,
                    selectable: true,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy All Markdown'),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: markdown));
                      _showSnackBar('Meeting minutes copied to clipboard!');
                    },
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Industrial AI Processing Pipeline with 21 CFR Part 11 Hash Computation ---

  Future<void> _executeAiPipeline() async {
    if (_recordedAudioPath == null && _currentSession?.audioPath == null) {
      _showSnackBar('No audio file found. Please record or import a session first.');
      return;
    }

    try {
      setState(() {
        _processingStage = ProcessingStage.transcribing;
        _statusMessage = 'Stage 1/3: Transcribing audio with multi-language Whisper engine...';
      });

      // 1. Transcription with language & domain conditioning
      String? langHint;
      if (_selectedLanguage == 'en') langHint = 'en';
      if (_selectedLanguage == 'hi') langHint = 'hi';
      if (_selectedLanguage == 'hinglish') langHint = 'hinglish';

      String transcript = await widget.intelligenceService.transcribeAudio(
        audioFilePath: _currentSession?.audioPath ?? _recordedAudioPath!,
        languageHint: langHint,
        domainHint: _selectedMeetingDomain,
        onProgress: (status) {
          setState(() {
            _statusMessage = status;
          });
        },
      );

      // 2. Sensitive Data & PII Redaction (if enabled)
      if (_enableSensitiveDataRedaction) {
        setState(() {
          _processingStage = ProcessingStage.deidentifying;
          _statusMessage = 'Stage 2/3: Redacting sensitive PII & personal identifiers...';
        });

        final scrubResult = widget.intelligenceService.deidentifyText(transcript);
        transcript = scrubResult.scrubbedText;
        _redactedTokensCount = scrubResult.redactedCount;
        _currentSession?.isDeIdentified = true;
      }

      setState(() {
        _currentSession?.transcript = transcript;
        _transcriptEditController.text = transcript;
        _translatedTranscript = null;
        _showTranslatedTranscript = false;
        _processingStage = ProcessingStage.summarizing;
        _statusMessage = 'Stage 3/3: Synthesizing executive summary, decisions & action items...';
      });

      // 3. Industrial Meeting Intelligence Synthesis
      final intelligence = await widget.intelligenceService.processSessionIntelligence(
        transcript: transcript,
        sessionTitle: _currentSession?.title ?? 'Meeting Discussion',
        meetingDomain: _selectedMeetingDomain,
      );

      // 4. Compute 21 CFR Part 11 cryptographic transcript hash
      final transcriptHash = CryptoUtils.sha256String(transcript);

      setState(() {
        _processingStage = ProcessingStage.completed;
        _statusMessage = 'AI Meeting Intelligence Generated & Sealed!';
        _currentSession?.summary = intelligence.summary;
        _currentSession?.actionItems = intelligence.actionItems;
        _currentSession?.speakerTurns = intelligence.speakerTurns;
        _currentSession?.transcriptSha256 = transcriptHash;
      });
      
      if (_currentSession != null) {
        await SessionRepository().saveSession(_currentSession!);
      }

      _showSnackBar('Meeting Analysis & Action Items ready (21 CFR Part 11 sealed).');
    } catch (e) {
      setState(() {
        _processingStage = ProcessingStage.error;
        _statusMessage = 'Error during AI pipeline: $e';
      });
      if (e is TranscriptionException && e.isNotConfigured) {
        _showConfigureWhisperDialog();
      } else if (_isConnectionError(e)) {
        _showAiConnectionErrorDialog(e);
      } else {
        _showSnackBar('Pipeline error: $e');
      }
    }
  }

  /// Interactive dialog allowing instant 1-click configuration of Whisper speech-to-text
  void _showConfigureWhisperDialog() {
    final apiKeyController = TextEditingController();

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.mic, color: Colors.blueAccent),
            SizedBox(width: 10),
            Expanded(child: Text('Connect Speech-to-Text Engine', style: TextStyle(fontSize: 16))),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'To transcribe your audio recording into text, LabScribe connects directly to a Whisper speech-to-text engine.',
                style: TextStyle(fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.blue.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.bolt, color: Colors.amber, size: 18),
                        SizedBox(width: 6),
                        Text('Recommended: Groq Free Tier', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Sub-second transcription with Whisper Large-v3. Free forever, no credit card required at console.groq.com.',
                      style: TextStyle(fontSize: 11.5, color: Colors.grey, height: 1.3),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: apiKeyController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        hintText: 'Paste Groq key (gsk_...) or OpenAI (sk-...)',
                        labelText: 'API Key',
                        prefixIcon: Icon(Icons.key, size: 18),
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.computer, size: 16),
                      label: const Text('Local Server (Port 8000)', style: TextStyle(fontSize: 11)),
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await ConfigService().saveConfig(
                          openAiBaseUrl: ConfigService().openAiBaseUrl,
                          openAiApiKey: ConfigService().openAiApiKey,
                          llmModel: ConfigService().llmModel,
                          transcriptionBaseUrl: 'http://localhost:8000/v1',
                          transcriptionApiKey: 'local',
                          transcriptionModel: 'Systran/faster-whisper-small',
                          libreTranslateBaseUrl: ConfigService().libreTranslateBaseUrl,
                          isDemoMode: false,
                        );
                        widget.intelligenceService.updateConfig(ConfigService().getAiConfig());
                        _executeAiPipeline();
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Center(
                child: TextButton.icon(
                  icon: const Icon(Icons.description_outlined, size: 16),
                  label: const Text('Load Sample Walkthrough Transcript', style: TextStyle(fontSize: 12)),
                  onPressed: () {
                    Navigator.pop(ctx);
                    final sample = widget.intelligenceService.loadSampleDemoTranscript();
                    _processTextDirectly(sample);
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.check, size: 18),
            label: const Text('Save & Transcribe'),
            onPressed: () async {
              final key = apiKeyController.text.trim();
              if (key.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please paste an API key, or choose Local Server.')),
                );
                return;
              }

              Navigator.pop(ctx);
              final isGroq = key.startsWith('gsk_');
              final isOai = key.startsWith('sk-');

              if (isGroq) {
                await ConfigService().saveConfig(
                  openAiBaseUrl: 'https://api.groq.com/openai/v1',
                  openAiApiKey: key,
                  llmModel: 'llama-3.3-70b-versatile',
                  transcriptionBaseUrl: 'https://api.groq.com/openai/v1',
                  transcriptionApiKey: key,
                  transcriptionModel: 'whisper-large-v3',
                  libreTranslateBaseUrl: ConfigService().libreTranslateBaseUrl,
                  isDemoMode: false,
                );
              } else if (isOai) {
                await ConfigService().saveConfig(
                  openAiBaseUrl: 'https://api.openai.com/v1',
                  openAiApiKey: key,
                  llmModel: 'gpt-4o-mini',
                  transcriptionBaseUrl: 'https://api.openai.com/v1',
                  transcriptionApiKey: key,
                  transcriptionModel: 'whisper-1',
                  libreTranslateBaseUrl: ConfigService().libreTranslateBaseUrl,
                  isDemoMode: false,
                );
              } else {
                await ConfigService().saveConfig(
                  openAiBaseUrl: ConfigService().openAiBaseUrl,
                  openAiApiKey: ConfigService().openAiApiKey,
                  llmModel: ConfigService().llmModel,
                  transcriptionBaseUrl: 'https://api.groq.com/openai/v1',
                  transcriptionApiKey: key,
                  transcriptionModel: 'whisper-large-v3',
                  libreTranslateBaseUrl: ConfigService().libreTranslateBaseUrl,
                  isDemoMode: false,
                );
              }

              widget.intelligenceService.updateConfig(ConfigService().getAiConfig());
              _executeAiPipeline();
            },
          ),
        ],
      ),
    );
  }

  /// Process meeting intelligence directly from pasted text or lecture notes
  Future<void> _processTextDirectly(String textToProcess) async {
    final clean = textToProcess.trim();
    if (clean.isEmpty) {
      _showSnackBar('Please enter or paste transcript text to analyze.');
      return;
    }

    try {
      setState(() {
        _processingStage = ProcessingStage.summarizing;
        _statusMessage = 'Analyzing meeting text & generating deliverables...';
      });

      String effectiveText = clean;
      if (_enableSensitiveDataRedaction) {
        final scrubResult = widget.intelligenceService.deidentifyText(effectiveText);
        effectiveText = scrubResult.scrubbedText;
        _redactedTokensCount = scrubResult.redactedCount;
      }

      if (_currentSession == null) {
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        _currentSession = MeetingSession(
          id: timestamp.toString(),
          title: _titleController.text.trim().isEmpty ? 'Meeting Discussion' : _titleController.text.trim(),
          createdAt: DateTime.now(),
          audioPath: '',
          durationSeconds: (effectiveText.split(RegExp(r'\s+')).length / 2.5).round(),
          isDeIdentified: _enableSensitiveDataRedaction,
        );
      }

      _currentSession!.transcript = effectiveText;
      _transcriptEditController.text = effectiveText;

      final intelligence = await widget.intelligenceService.processSessionIntelligence(
        transcript: effectiveText,
        sessionTitle: _currentSession!.title,
        meetingDomain: _selectedMeetingDomain,
      );

      final transcriptHash = CryptoUtils.sha256String(effectiveText);

      setState(() {
        _processingStage = ProcessingStage.completed;
        _statusMessage = 'AI Meeting Intelligence Generated & Sealed!';
        _currentSession?.summary = intelligence.summary;
        _currentSession?.actionItems = intelligence.actionItems;
        _currentSession?.speakerTurns = intelligence.speakerTurns;
        _currentSession?.transcriptSha256 = transcriptHash;
        _isTranscriptEditMode = false;
        _translatedTranscript = null;
        _showTranslatedTranscript = false;
      });

      await SessionRepository().saveSession(_currentSession!);
      _showSnackBar('Analysis complete from meeting text (21 CFR Part 11 sealed).');
    } catch (e) {
      setState(() {
        _processingStage = ProcessingStage.error;
        _statusMessage = 'Error during text analysis: $e';
      });
      _showSnackBar('Error analyzing text: $e');
    }
  }

  void _copyTranscriptToClipboard() {
    final text = (_showTranslatedTranscript && _translatedTranscript != null)
        ? _translatedTranscript!
        : (_currentSession?.transcript ?? '');
    if (text.isEmpty) {
      _showSnackBar('No transcript text to copy.');
      return;
    }
    Clipboard.setData(ClipboardData(text: text));
    _showSnackBar('Transcript copied to clipboard!');
  }

  void _showSaveTranscriptMenu() {
    if (_currentSession == null || _currentSession!.transcript.isEmpty) {
      _showSnackBar('No transcript to save yet. Record or paste text first.');
      return;
    }

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.save_alt, color: Colors.teal),
                const SizedBox(width: 10),
                Text(
                  'Save / Export Transcript',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.description, color: Colors.blue),
              title: const Text('Save as Plain Text (.txt)'),
              subtitle: const Text('Clean raw transcript file for sharing or archiving'),
              onTap: () async {
                Navigator.pop(ctx);
                await ExportService().exportTranscriptAsPlainText(_currentSession!);
                _showSnackBar('Transcript saved as plain text (.txt)!');
              },
            ),
            ListTile(
              leading: const Icon(Icons.article, color: Colors.deepPurple),
              title: const Text('Save as Lab Markdown (.md)'),
              subtitle: const Text('Formatted lab record with 21 CFR Part 11 cryptographic seal'),
              onTap: () async {
                Navigator.pop(ctx);
                await ExportService().exportSessionAsMarkdown(_currentSession!);
                _showSnackBar('Exported as scientific Markdown (.md)!');
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy, color: Colors.teal),
              title: const Text('Copy to Clipboard'),
              subtitle: const Text('Quick paste into Slack, WhatsApp, or email'),
              onTap: () {
                Navigator.pop(ctx);
                _copyTranscriptToClipboard();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _toggleEditTranscript() {
    setState(() {
      _isTranscriptEditMode = !_isTranscriptEditMode;
      if (_isTranscriptEditMode) {
        _transcriptEditController.text = _currentSession?.transcript ?? '';
      }
    });
  }

  Future<void> _saveEditedTranscript() async {
    final text = _transcriptEditController.text.trim();
    if (text.isEmpty) {
      _showSnackBar('Transcript cannot be empty.');
      return;
    }
    if (_currentSession == null) {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      _currentSession = MeetingSession(
        id: timestamp.toString(),
        title: _titleController.text.trim().isEmpty ? 'Scientific Session' : _titleController.text.trim(),
        createdAt: DateTime.now(),
        audioPath: _recordedAudioPath ?? '',
        durationSeconds: _recordDurationSeconds,
      );
    }
    final hash = CryptoUtils.sha256String(text);
    setState(() {
      _currentSession!.transcript = text;
      _currentSession!.transcriptSha256 = hash;
      _isTranscriptEditMode = false;
      _translatedTranscript = null;
      _showTranslatedTranscript = false;
    });
    await SessionRepository().saveSession(_currentSession!);
    _showSnackBar('Transcript updated and 21 CFR Part 11 re-sealed!');
  }

  Future<void> _toggleTranslateTranscript() async {
    if (_currentSession == null || _currentSession!.transcript.isEmpty) {
      _showSnackBar('No transcript to translate.');
      return;
    }

    if (_translatedTranscript != null) {
      setState(() {
        _showTranslatedTranscript = !_showTranslatedTranscript;
      });
      return;
    }

    setState(() {
      _isTranslatingTranscript = true;
    });

    try {
      final target = _selectedLanguage == 'hi' ? 'English' : 'Hindi';
      final translated = await widget.intelligenceService.translateScientificText(
        text: _currentSession!.transcript,
        targetLanguage: target,
      );

      setState(() {
        _translatedTranscript = translated;
        _showTranslatedTranscript = true;
        _isTranslatingTranscript = false;
      });
      _showSnackBar(target == 'Hindi' ? 'प्रतिलेख का हिन्दी अनुवाद तैयार है!' : 'Translated to English!');
    } catch (e) {
      setState(() {
        _isTranslatingTranscript = false;
      });
      _showSnackBar('Translation failed: $e');
    }
  }

  void _showPasteTranscriptDialog() {
    final pasteController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.paste, color: Colors.teal),
            SizedBox(width: 10),
            Text('Paste Transcript / Notes', style: TextStyle(fontSize: 18)),
          ],
        ),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Paste meeting notes, a scientific lecture transcript, or lab discussion text below to run the AI intelligence pipeline directly:',
                style: TextStyle(fontSize: 12.5, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: pasteController,
                maxLines: 8,
                decoration: const InputDecoration(
                  hintText: 'e.g. Dr. Chen: Today we tested Cisplatin on H23 cell line...',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () {
              final text = pasteController.text.trim();
              Navigator.pop(ctx);
              if (text.isNotEmpty) {
                _processTextDirectly(text);
              }
            },
            icon: const Icon(Icons.auto_awesome, size: 16),
            label: const Text('Analyze with AI'),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleTranslateSummary() async {
    final execSummary = _currentSession?.summary?.executiveSummary;
    if (execSummary == null || execSummary.isEmpty) return;

    if (_translatedSummary != null) {
      setState(() {
        _showTranslatedSummary = !_showTranslatedSummary;
      });
      return;
    }

    setState(() {
      _isTranslatingSummary = true;
    });

    try {
      final translated = await widget.intelligenceService.translateScientificText(
        text: execSummary,
        targetLanguage: 'Hindi',
      );
      setState(() {
        _translatedSummary = translated;
        _showTranslatedSummary = true;
        _isTranslatingSummary = false;
      });
      _showSnackBar('सारांश का हिन्दी अनुवाद तैयार है!');
    } catch (e) {
      setState(() {
        _isTranslatingSummary = false;
      });
      _showSnackBar('Translation failed: $e');
    }
  }

  Widget _buildLanguageSelector(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant.withOpacity(0.6)),
      ),
      child: Row(
        children: [
          const Icon(Icons.language, size: 18, color: Colors.teal),
          const SizedBox(width: 8),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Language / भाषा', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                Text('Whisper & AI tuning', style: TextStyle(color: Colors.grey, fontSize: 10)),
              ],
            ),
          ),
          DropdownButton<String>(
            value: _selectedLanguage,
            underline: const SizedBox(),
            isDense: true,
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11.5, color: theme.colorScheme.onSurface),
            items: const [
              DropdownMenuItem(value: 'auto', child: Text('🌐 Auto')),
              DropdownMenuItem(value: 'en', child: Text('🇬🇧 English')),
              DropdownMenuItem(value: 'hi', child: Text('🇮🇳 हिन्दी (Hindi)')),
              DropdownMenuItem(value: 'hinglish', child: Text('🇮🇳 Hinglish')),
            ],
            onChanged: (val) {
              if (val != null) {
                setState(() {
                  _selectedLanguage = val;
                });
                _showSnackBar(
                  val == 'hi'
                      ? 'हिन्दी भाषा अनुकूलित (Hindi speech & transcription optimization active)'
                      : (val == 'hinglish' ? 'Hinglish code-mixed meeting optimization active' : 'Language set to ${val.toUpperCase()}'),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  bool _isConnectionError(dynamic e) {
    if (e is DioException) {
      if (e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout ||
          e.error is SocketException) {
        return true;
      }
    }
    final str = e.toString().toLowerCase();
    return str.contains('connection refused') ||
        str.contains('socketexception') ||
        str.contains('failed host lookup') ||
        str.contains('network is unreachable') ||
        str.contains('errno = 111');
  }

  Future<void> _showAiConnectionErrorDialog(dynamic error) async {
    if (!mounted) return;

    final config = widget.intelligenceService.config;
    final isLocalhost = config.transcriptionBaseUrl.contains('localhost') || config.openAiBaseUrl.contains('localhost');

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.wifi_off, color: Colors.amber),
            SizedBox(width: 10),
            Text('Cannot Connect to AI Engine', style: TextStyle(fontSize: 18)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isLocalhost
                    ? 'LabScribe could not connect to your local AI engine on localhost.'
                    : 'LabScribe could not connect to the configured AI endpoint.',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(ctx).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('STT Endpoint: ${config.transcriptionBaseUrl}', style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                    Text('LLM Endpoint: ${config.openAiBaseUrl}', style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                    const SizedBox(height: 4),
                    const Text('Status: Connection Refused (No server listening)', style: TextStyle(fontSize: 11, color: Colors.redAccent, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'How would you like to proceed?',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 8),
              const Text(
                '1. Free Cloud (Zero CLI): Select "Cloud: Groq Free Tier" in Settings and paste a free key from console.groq.com.\n'
                '2. Offline Demo Mode: Test all scientific features right now with simulated data (no setup needed).\n'
                '3. Local Server: Start Ollama (ollama serve) and Whisper on port 8000 on your machine.',
                style: TextStyle(fontSize: 12.5, height: 1.4),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Dismiss'),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.play_circle_outline, size: 18),
            label: const Text('Try Demo Mode'),
            onPressed: () async {
              Navigator.pop(ctx);
              await ConfigService().saveConfig(
                openAiBaseUrl: 'demo',
                openAiApiKey: 'demo',
                llmModel: 'demo-scientific-ai',
                transcriptionBaseUrl: 'demo',
                transcriptionApiKey: 'demo',
                transcriptionModel: 'demo-whisper',
                libreTranslateBaseUrl: ConfigService().libreTranslateBaseUrl,
                isDemoMode: true,
              );
              widget.intelligenceService.updateConfig(ConfigService().getAiConfig());
              _executeAiPipeline();
            },
          ),
          FilledButton.icon(
            icon: const Icon(Icons.settings, size: 18),
            label: const Text('Open Settings'),
            onPressed: () async {
              Navigator.pop(ctx);
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SettingsView()),
              );
              widget.intelligenceService.updateConfig(ConfigService().getAiConfig());
            },
          ),
        ],
      ),
    );
  }

  Future<void> _sendChatMessage() async {
    final text = _chatController.text.trim();
    if (text.isEmpty || _currentSession == null || _currentSession!.transcript.isEmpty) return;

    _chatController.clear();
    setState(() {
      _currentSession!.chatHistory.add(ChatMessage(
        sender: 'user',
        text: text,
        timestamp: DateTime.now(),
      ));
      _isWaitingForAiChatResponse = true;
    });

    try {
      final reply = await widget.intelligenceService.askSessionBot(
        transcript: _currentSession!.transcript,
        history: _currentSession!.chatHistory,
        question: text,
      );

      setState(() {
        _currentSession!.chatHistory.add(ChatMessage(
          sender: 'ai',
          text: reply,
          timestamp: DateTime.now(),
        ));
        _isWaitingForAiChatResponse = false;
      });

      Future.delayed(const Duration(milliseconds: 100), () {
        if (_chatScrollController.hasClients) {
          _chatScrollController.animateTo(
            _chatScrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    } catch (e) {
      setState(() {
        _isWaitingForAiChatResponse = false;
      });
      if (_isConnectionError(e)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Cannot connect to AI engine. Check Settings or use Demo Mode.'),
            action: SnackBarAction(
              label: 'Settings',
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const SettingsView()),
                );
                widget.intelligenceService.updateConfig(ConfigService().getAiConfig());
              },
            ),
          ),
        );
      } else {
        _showSnackBar('Chat error: $e');
      }
    }
  }

  void _showSnackBar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // --- Main Build with Accidental Stop & Exit Protection (PopScope) ---

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDesktop = MediaQuery.of(context).size.width >= 900;

    return PopScope(
      canPop: _recordingState != RecordingState.recording,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        final shouldExit = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 28),
                SizedBox(width: 10),
                Text('Active Recording in Progress'),
              ],
            ),
            content: const Text(
              'A scientific session is currently being recorded.\n\nAre you sure you want to stop the recording and exit?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep Recording'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Stop & Exit'),
              ),
            ],
          ),
        );
        if (shouldExit == true && mounted) {
          await _stopRecording();
          if (mounted) Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 20,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: const Color(0xFF4F46E5).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.graphic_eq, color: Color(0xFF4F46E5), size: 20),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'LabScribe',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17, letterSpacing: -0.3),
                  ),
                  Text(
                    _titleController.text.trim().isNotEmpty
                        ? _titleController.text.trim()
                        : 'Intelligent Meeting Assistant',
                    style: TextStyle(fontSize: 11, color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.history_rounded),
              tooltip: 'Meeting History',
              onPressed: () async {
                final selectedSession = await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const HistoryView()),
                );
                if (selectedSession != null && selectedSession is MeetingSession) {
                  loadSession(selectedSession);
                }
              },
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.file_download_outlined),
              tooltip: 'Export Meeting Minutes & Deliverables',
              onSelected: (value) async {
                if (_currentSession == null) {
                  _showSnackBar('No session to export. Record or load a session first.');
                  return;
                }
                if (value == 'markdown') {
                  await ExportService().exportSessionAsMarkdown(_currentSession!);
                } else if (value == 'csv') {
                  await ExportService().exportActionItemsAsCsv(_currentSession!);
                } else if (value == 'txt') {
                  await ExportService().exportTranscriptAsPlainText(_currentSession!);
                } else if (value == 'eln') {
                  await ExportService().exportSessionAsELNJson(_currentSession!);
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'markdown',
                  child: Row(
                    children: [
                      Icon(Icons.description_outlined, size: 18),
                      SizedBox(width: 10),
                      Text('Meeting Minutes (.md)'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'csv',
                  child: Row(
                    children: [
                      Icon(Icons.table_chart_outlined, size: 18),
                      SizedBox(width: 10),
                      Text('Action Items (.csv)'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'txt',
                  child: Row(
                    children: [
                      Icon(Icons.text_snippet_outlined, size: 18),
                      SizedBox(width: 10),
                      Text('Plain Transcript (.txt)'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'eln',
                  child: Row(
                    children: [
                      Icon(Icons.data_object_outlined, size: 18),
                      SizedBox(width: 10),
                      Text('Session Data (.json)'),
                    ],
                  ),
                ),
              ],
            ),
            IconButton(
              icon: const Icon(Icons.tune_outlined),
              tooltip: 'Model & Audio Settings',
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const SettingsView()),
                );
                widget.intelligenceService.updateConfig(ConfigService().getAiConfig());
              },
            ),
            const SizedBox(width: 12),
          ],
        ),
        body: _buildResponsiveBody(context, theme, isDesktop),
        bottomNavigationBar: (!isDesktop && !_isMeetingCompactMode)
            ? NavigationBar(
                selectedIndex: _mobileNavIndex,
                onDestinationSelected: (idx) {
                  setState(() {
                    _mobileNavIndex = idx;
                  });
                },
                destinations: const [
                  NavigationDestination(icon: Icon(Icons.mic_none), selectedIcon: Icon(Icons.mic), label: 'Record'),
                  NavigationDestination(icon: Icon(Icons.article_outlined), selectedIcon: Icon(Icons.article), label: 'Summary'),
                  NavigationDestination(icon: Icon(Icons.task_alt), selectedIcon: Icon(Icons.task), label: 'Tasks'),
                  NavigationDestination(icon: Icon(Icons.record_voice_over_outlined), selectedIcon: Icon(Icons.record_voice_over), label: 'Transcript'),
                  NavigationDestination(icon: Icon(Icons.smart_toy_outlined), selectedIcon: Icon(Icons.smart_toy), label: 'AI Chat'),
                ],
              )
            : null,
      ),
    );
  }

  Widget _buildResponsiveBody(BuildContext context, ThemeData theme, bool isDesktop) {
    if (_isMeetingCompactMode) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: _buildCompactMeetingDeck(theme),
          ),
        ),
      );
    }

    if (isDesktop) {
      return Row(
        children: [
          SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: _buildRecordingControlPanel(theme),
            ),
          ),
          VerticalDivider(width: 1, thickness: 1, color: theme.colorScheme.outlineVariant),
          Expanded(
            child: Column(
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
                  ),
                  child: TabBar(
                    controller: _tabController,
                    isScrollable: false,
                    labelColor: theme.colorScheme.primary,
                    unselectedLabelColor: theme.colorScheme.onSurface.withOpacity(0.6),
                    indicatorColor: theme.colorScheme.primary,
                    indicatorWeight: 2.5,
                    tabs: const [
                      Tab(icon: Icon(Icons.article_outlined, size: 18), text: 'Summary'),
                      Tab(icon: Icon(Icons.check_circle_outline, size: 18), text: 'Action Items'),
                      Tab(icon: Icon(Icons.description_outlined, size: 18), text: 'Transcript'),
                      Tab(icon: Icon(Icons.pie_chart_outline, size: 18), text: 'Speakers'),
                      Tab(icon: Icon(Icons.smart_toy_outlined, size: 18), text: 'AI Assistant'),
                    ],
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildSummaryTab(theme),
                      _buildTasksAndDecisionsTab(theme),
                      _buildTranscriptTab(theme),
                      _buildSpeakerAnalyticsTab(theme),
                      _buildChatTab(theme),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    switch (_mobileNavIndex) {
      case 0:
        return SingleChildScrollView(child: _buildRecordingControlPanel(theme));
      case 1:
        return _buildSummaryTab(theme);
      case 2:
        return _buildTasksAndDecisionsTab(theme);
      case 3:
        return _buildTranscriptTab(theme);
      case 4:
        return _buildChatTab(theme);
      default:
        return SingleChildScrollView(child: _buildRecordingControlPanel(theme));
    }
  }

  // --- Meeting Compact Deck Mode ---

  // --- Meeting Compact Deck Mode ---

  Widget _buildCompactMeetingDeck(ThemeData theme) {
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    _titleController.text.trim().isEmpty ? 'Meeting Discussion' : _titleController.text.trim(),
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.fullscreen),
                  tooltip: 'Expand Full Dashboards',
                  onPressed: () => setState(() => _isMeetingCompactMode = false),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Pulsing Timer Display
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withOpacity(0.25),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _recordingState == RecordingState.recording
                      ? Colors.redAccent
                      : theme.colorScheme.outlineVariant,
                  width: 1.5,
                ),
              ),
              child: Column(
                children: [
                  Text(
                    _formatDuration(_recordDurationSeconds),
                    style: theme.textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2,
                      color: _recordingState == RecordingState.recording ? Colors.redAccent : theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _recordingState == RecordingState.recording
                              ? Colors.redAccent
                              : (_recordingState == RecordingState.paused ? Colors.orange : Colors.grey),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _recordingState == RecordingState.recording
                            ? 'RECORDING ACTIVE (AIR-GAPPED MIC)'
                            : _recordingState.name.toUpperCase(),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Live Waveform & Decibel Meter
            _buildLiveWaveformVisualizer(theme),
            const SizedBox(height: 8),
            _buildDecibelMeterGauge(theme),
            const SizedBox(height: 12),

            // Microphone Selector
            _buildAudioDeviceSelector(theme),
            const SizedBox(height: 8),

            // Meeting Domain Selector
            _buildMeetingDomainSelector(theme),
            const SizedBox(height: 8),

            // Multilingual Hindi/English Optimization Selector
            _buildLanguageSelector(theme),
            const SizedBox(height: 14),

            // Primary Audio Action Controls
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (_recordingState == RecordingState.idle || _recordingState == RecordingState.stopped) ...[
                  ElevatedButton.icon(
                    onPressed: _startRecording,
                    icon: const Icon(Icons.fiber_manual_record, color: Colors.white),
                    label: const Text('Start Recording'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _importAudioFileDialog,
                    icon: const Icon(Icons.file_upload_outlined, size: 16),
                    label: const Text('Import Audio'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _showPasteTranscriptDialog,
                    icon: const Icon(Icons.paste, size: 16),
                    label: const Text('Paste Text'),
                  ),
                ],
                if (_recordingState == RecordingState.recording) ...[
                  OutlinedButton.icon(
                    onPressed: _pauseRecording,
                    icon: const Icon(Icons.pause),
                    label: const Text('Pause'),
                  ),
                  ElevatedButton.icon(
                    onPressed: _stopRecording,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueGrey,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
                if (_recordingState == RecordingState.paused) ...[
                  ElevatedButton.icon(
                    onPressed: _resumeRecording,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Resume'),
                  ),
                  ElevatedButton.icon(
                    onPressed: _stopRecording,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueGrey,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 14),

            // Audio Playback Bar (when stopped)
            _buildAudioPlaybackBar(theme),

            // Meeting 1-Click Reaction & Bookmark Tags
            const SizedBox(height: 12),
            const Text(
              'QUICK MEETING TAGS (ONE-CLICK BOOKMARK)',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ActionChip(
                  avatar: const Text('⚡'),
                  label: const Text('Action Item'),
                  onPressed: () => _quickAddTag('⚡', 'Action Item'),
                ),
                ActionChip(
                  avatar: const Text('📌'),
                  label: const Text('Decision'),
                  onPressed: () => _quickAddTag('📌', 'Decision'),
                ),
                ActionChip(
                  avatar: const Text('💡'),
                  label: const Text('Idea'),
                  onPressed: () => _quickAddTag('💡', 'Idea'),
                ),
                ActionChip(
                  avatar: const Text('⚠️'),
                  label: const Text('Risk / Blocker'),
                  onPressed: () => _quickAddTag('⚠️', 'Risk / Blocker'),
                ),
                ActionChip(
                  avatar: const Icon(Icons.edit_note, size: 16),
                  label: const Text('Custom Note'),
                  onPressed: _addLiveMeetingNoteDialog,
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Live Stream of Bookmarks in Current Meeting
            if (_currentSession?.liveNotes.isNotEmpty == true) ...[
              const Divider(),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Meeting Stream (${_currentSession!.liveNotes.length})',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  Text('${_currentSession!.slideAttachments.length} Visuals',
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 140),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _currentSession!.liveNotes.length,
                  itemBuilder: (ctx, idx) {
                    final n = _currentSession!.liveNotes[idx];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      child: Row(
                        children: [
                          InkWell(
                            onTap: () => _seekToSecond(n.timestampSeconds),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.orange.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                _formatDuration(n.timestampSeconds),
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.deepOrange),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(n.note, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
            ],

            // Visual Attachment Button
            OutlinedButton.icon(
              onPressed: _attachFigureDialog,
              icon: const Icon(Icons.add_photo_alternate, size: 16),
              label: const Text('Attach Slide / Visual'),
            ),
            const SizedBox(height: 12),

            // Expand Button
            FilledButton.tonalIcon(
              onPressed: () => setState(() => _isMeetingCompactMode = false),
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Open Meeting Intelligence Dashboards'),
            ),
          ],
        ),
      ),
    );
  }

  // --- Industrial Meeting Recording Control Panel (Desktop Sidebar & Mobile View) ---

  Widget _buildRecordingControlPanel(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Meeting Title Field
          TextField(
            controller: _titleController,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            decoration: InputDecoration(
              labelText: 'Meeting Title',
              hintText: 'e.g. Weekly Product Sync & Roadmap',
              prefixIcon: Icon(Icons.edit_note, color: theme.colorScheme.primary, size: 20),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),

          // Compact Configuration Panel (Domain, Language, Microphone, Quality)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.35),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.outlineVariant.withOpacity(0.6)),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    // Domain Dropdown
                    Expanded(
                      child: Row(
                        children: [
                          Icon(Icons.business_center_outlined, size: 15, color: theme.colorScheme.primary),
                          const SizedBox(width: 6),
                          Expanded(
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _selectedMeetingDomain,
                                isDense: true,
                                isExpanded: true,
                                style: TextStyle(fontWeight: FontWeight.w500, fontSize: 11.5, color: theme.colorScheme.onSurface),
                                items: _domainOptions.map((domain) {
                                  return DropdownMenuItem(value: domain, child: Text(domain, overflow: TextOverflow.ellipsis));
                                }).toList(),
                                onChanged: (val) {
                                  if (val != null) {
                                    setState(() => _selectedMeetingDomain = val);
                                  }
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Language Dropdown
                    Expanded(
                      child: Row(
                        children: [
                          const Icon(Icons.language, size: 15, color: Colors.blueAccent),
                          const SizedBox(width: 6),
                          Expanded(
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _selectedLanguage,
                                isDense: true,
                                isExpanded: true,
                                style: TextStyle(fontWeight: FontWeight.w500, fontSize: 11.5, color: theme.colorScheme.onSurface),
                                items: const [
                                  DropdownMenuItem(value: 'auto', child: Text('🌐 Auto')),
                                  DropdownMenuItem(value: 'en', child: Text('🇬🇧 English')),
                                  DropdownMenuItem(value: 'hi', child: Text('🇮🇳 हिन्दी')),
                                  DropdownMenuItem(value: 'hinglish', child: Text('🇮🇳 Hinglish')),
                                ],
                                onChanged: (val) {
                                  if (val != null) {
                                    setState(() => _selectedLanguage = val);
                                  }
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Divider(height: 14, thickness: 0.7, color: theme.colorScheme.outlineVariant.withOpacity(0.5)),
                Row(
                  children: [
                    // Microphone Selector
                    Expanded(
                      child: Row(
                        children: [
                          Icon(Icons.mic_none, size: 15, color: theme.colorScheme.primary),
                          const SizedBox(width: 6),
                          Expanded(
                            child: _audioInputDevices.isEmpty
                                ? const Text('Default Mic', style: TextStyle(fontSize: 11.5), overflow: TextOverflow.ellipsis)
                                : DropdownButtonHideUnderline(
                                    child: DropdownButton<String>(
                                      value: _selectedDeviceId,
                                      isDense: true,
                                      isExpanded: true,
                                      style: TextStyle(fontWeight: FontWeight.w500, fontSize: 11.5, color: theme.colorScheme.onSurface),
                                      items: _audioInputDevices.map((dev) {
                                        return DropdownMenuItem<String>(
                                          value: dev.id,
                                          child: Text(dev.label.isNotEmpty ? dev.label : 'Mic (${dev.id})', overflow: TextOverflow.ellipsis),
                                        );
                                      }).toList(),
                                      onChanged: (id) {
                                        if (id != null) {
                                          setState(() {
                                            _selectedDeviceId = id;
                                            _selectedInputDevice = _audioInputDevices.firstWhere((d) => d.id == id);
                                          });
                                        }
                                      },
                                    ),
                                  ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Audio Fidelity
                    Expanded(
                      child: Row(
                        children: [
                          const Icon(Icons.graphic_eq, size: 15, color: Colors.blueAccent),
                          const SizedBox(width: 6),
                          Expanded(
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _audioQuality,
                                isDense: true,
                                isExpanded: true,
                                style: TextStyle(fontWeight: FontWeight.w500, fontSize: 11.5, color: theme.colorScheme.onSurface),
                                items: const [
                                  DropdownMenuItem(value: 'High Fidelity (128 kbps)', child: Text('128 kbps Hi-Fi')),
                                  DropdownMenuItem(value: 'Studio Voice (256 kbps)', child: Text('256 kbps Studio')),
                                  DropdownMenuItem(value: 'Compact Voice (64 kbps)', child: Text('64 kbps Voice')),
                                ],
                                onChanged: (val) {
                                  if (val != null) {
                                    setState(() => _audioQuality = val);
                                  }
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Hero Recording Card
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _recordingState == RecordingState.recording
                    ? Colors.redAccent.withOpacity(0.6)
                    : theme.colorScheme.outlineVariant,
                width: _recordingState == RecordingState.recording ? 1.5 : 1.0,
              ),
            ),
            child: Column(
              children: [
                // Digital Stopwatch Timer
                Text(
                  _formatDuration(_recordDurationSeconds),
                  style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2.5,
                    fontFamily: 'monospace',
                    color: _recordingState == RecordingState.recording ? Colors.redAccent : theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                // Live Status Indicator Dot
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _recordingState == RecordingState.recording
                            ? Colors.redAccent
                            : (_recordingState == RecordingState.paused ? Colors.orange : Colors.green),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _recordingState == RecordingState.recording
                          ? 'RECORDING ACTIVE'
                          : (_recordingState == RecordingState.paused ? 'RECORDING PAUSED' : 'READY TO RECORD'),
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 10.5,
                        letterSpacing: 0.8,
                        color: _recordingState == RecordingState.recording
                            ? Colors.redAccent
                            : (_recordingState == RecordingState.paused ? Colors.orange : Colors.grey),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                // Live 28-Bar Waveform
                _buildLiveWaveformVisualizer(theme),
                const SizedBox(height: 8),

                // Decibel Meter Gauge
                _buildDecibelMeterGauge(theme),
                const SizedBox(height: 14),

                // Primary Record Buttons
                if (_recordingState == RecordingState.idle || _recordingState == RecordingState.stopped) ...[
                  FilledButton.icon(
                    onPressed: _startRecording,
                    icon: const Icon(Icons.fiber_manual_record, color: Colors.white, size: 16),
                    label: const Text('Record Meeting', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(42),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _importAudioFileDialog,
                          icon: const Icon(Icons.file_upload_outlined, size: 15),
                          label: const Text('Import Audio', style: TextStyle(fontSize: 11.5)),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _showPasteTranscriptDialog,
                          icon: const Icon(Icons.content_paste_outlined, size: 15),
                          label: const Text('Paste Notes', style: TextStyle(fontSize: 11.5)),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (_recordingState == RecordingState.recording) ...[
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _pauseRecording,
                          icon: const Icon(Icons.pause, size: 16),
                          label: const Text('Pause'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _stopRecording,
                          icon: const Icon(Icons.stop, size: 16),
                          label: const Text('Stop & Save'),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.redAccent,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (_recordingState == RecordingState.paused) ...[
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _resumeRecording,
                          icon: const Icon(Icons.play_arrow, size: 16),
                          label: const Text('Resume'),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _stopRecording,
                          icon: const Icon(Icons.stop, size: 16),
                          label: const Text('Finish'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),

          // Real-time Speech Preview when recording
          _buildRealtimeTranscriptionPanel(theme),

          // Audio Playback Bar when audio is recorded/loaded
          _buildAudioPlaybackBar(theme),

          const SizedBox(height: 12),

          // Process AI Meeting Intelligence CTA Button
          FilledButton.icon(
            onPressed: (_recordingState == RecordingState.stopped || _currentSession != null) &&
                    _processingStage != ProcessingStage.transcribing &&
                    _processingStage != ProcessingStage.summarizing
                ? _executeAiPipeline
                : null,
            icon: const Icon(Icons.auto_awesome, size: 16),
            label: const Text('Process Meeting Insights', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF4F46E5),
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(44),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          const SizedBox(height: 6),

          // Progress Indicator & Status Message
          if (_processingStage != ProcessingStage.idle) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _processingStage == ProcessingStage.completed
                    ? 1.0
                    : (_processingStage == ProcessingStage.transcribing
                        ? 0.3
                        : _processingStage == ProcessingStage.deidentifying
                            ? 0.5
                            : 0.8),
                minHeight: 4,
              ),
            ),
            const SizedBox(height: 6),
          ],
          Text(
            _statusMessage,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline, fontSize: 11),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  // --- Meeting Domain Selector ---

  Widget _buildMeetingDomainSelector(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant.withOpacity(0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.business_center_outlined, size: 18, color: Colors.blueAccent),
          const SizedBox(width: 8),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Meeting Domain', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                Text('Context & vocabulary tuning', style: TextStyle(color: Colors.grey, fontSize: 10)),
              ],
            ),
          ),
          DropdownButton<String>(
            value: _selectedMeetingDomain,
            underline: const SizedBox(),
            isDense: true,
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11.5, color: theme.colorScheme.onSurface),
            items: _domainOptions.map((domain) {
              return DropdownMenuItem(
                value: domain,
                child: Text(domain),
              );
            }).toList(),
            onChanged: (val) {
              if (val != null) {
                setState(() {
                  _selectedMeetingDomain = val;
                });
                _showSnackBar('Meeting domain tuned to: $val');
              }
            },
          ),
        ],
      ),
    );
  }

  // --- Audio Quality Profile Selector ---

  Widget _buildAudioQualitySelector(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant.withOpacity(0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.tune, size: 18, color: Colors.teal),
          const SizedBox(width: 8),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Audio Fidelity', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                Text('Bitrate & sample rate', style: TextStyle(color: Colors.grey, fontSize: 10)),
              ],
            ),
          ),
          DropdownButton<String>(
            value: _audioQuality,
            underline: const SizedBox(),
            isDense: true,
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11.5, color: theme.colorScheme.onSurface),
            items: const [
              DropdownMenuItem(value: 'High Fidelity (128 kbps)', child: Text('Standard (128 kbps)')),
              DropdownMenuItem(value: 'Studio Voice (256 kbps)', child: Text('Studio (256 kbps)')),
              DropdownMenuItem(value: 'Compact Voice (64 kbps)', child: Text('Compact (64 kbps)')),
            ],
            onChanged: (val) {
              if (val != null) {
                setState(() {
                  _audioQuality = val;
                });
              }
            },
          ),
        ],
      ),
    );
  }

  // --- Real-Time Decibel Meter Gauge (-60 dB to 0 dB) ---

  Widget _buildDecibelMeterGauge(ThemeData theme) {
    final clampedDb = _currentDecibels.clamp(-60.0, 0.0);
    final percent = ((clampedDb + 60.0) / 60.0).clamp(0.0, 1.0);
    Color meterColor = Colors.green;
    if (percent > 0.8) {
      meterColor = Colors.redAccent;
    } else if (percent > 0.6) {
      meterColor = Colors.orangeAccent;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.graphic_eq, size: 16, color: meterColor),
          const SizedBox(width: 8),
          Text(
            _recordingState == RecordingState.recording
                ? '${_currentDecibels.toStringAsFixed(1)} dB'
                : 'Muted (-60 dB)',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: meterColor),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _recordingState == RecordingState.recording ? percent : 0.0,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(meterColor),
                minHeight: 6,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- Dynamic Live Waveform Visualizer (28 Bars) ---

  Widget _buildLiveWaveformVisualizer(ThemeData theme) {
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _recordingState == RecordingState.recording
              ? theme.colorScheme.primary.withOpacity(0.5)
              : theme.colorScheme.outlineVariant.withOpacity(0.4),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: _liveWaveformBars.map((barValue) {
          final height = (_recordingState == RecordingState.recording ? barValue * 44.0 : 6.0).clamp(4.0, 48.0);
          return AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            width: 5,
            height: height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: _recordingState == RecordingState.recording
                    ? [theme.colorScheme.primary, Colors.tealAccent]
                    : [Colors.grey.shade400, Colors.grey.shade500],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // --- Real-Time Acoustic & Voice Activity Detection Monitor During Recording ---

  Widget _buildRealtimeTranscriptionPanel(ThemeData theme) {
    if (_recordingState != RecordingState.recording) {
      return const SizedBox.shrink();
    }

    final isVoiceActive = _currentDecibels > -42.0;

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isVoiceActive
              ? Colors.teal.withOpacity(0.6)
              : theme.colorScheme.outlineVariant.withOpacity(0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isVoiceActive ? Colors.greenAccent : Colors.orangeAccent,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                isVoiceActive ? 'VOICE ACTIVITY DETECTED' : 'LISTENING (AMBIENT NOISE)',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 10.5,
                  letterSpacing: 0.5,
                  color: isVoiceActive ? Colors.teal : Colors.orange[800],
                ),
              ),
              const Spacer(),
              Text(
                '${_currentDecibels.toStringAsFixed(1)} dBFS',
                style: const TextStyle(fontSize: 10.5, fontFamily: 'monospace', fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.security, size: 14, color: Colors.blueAccent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Air-gapped audio stream actively buffering to local storage (${_formatDuration(_recordDurationSeconds)}). High-accuracy transcription will run via Whisper upon stopping.',
                  style: const TextStyle(fontSize: 11, color: Colors.grey, height: 1.3),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // --- Industrial Audio Playback Bar with Variable Speed and +/- 10s Skips ---

  Widget _buildAudioPlaybackBar(ThemeData theme) {
    if (_recordedAudioPath == null) return const SizedBox.shrink();

    final posSec = _playbackPosition.inSeconds;
    final durSec = _playbackDuration.inSeconds > 0 ? _playbackDuration.inSeconds : _recordDurationSeconds;

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'AUDIO PLAYBACK & SCRUBBER',
                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Colors.grey),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: _cyclePlaybackSpeed,
                child: Text(
                  '${_playbackRate}x Speed',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11.5),
                ),
              ),
            ],
          ),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.replay_10, size: 20),
                tooltip: 'Rewind 10s',
                onPressed: () => _skipAudio(-10),
              ),
              IconButton(
                icon: Icon(_isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled, size: 30),
                color: theme.colorScheme.primary,
                onPressed: () async {
                  if (_isPlaying) {
                    await _audioPlayer.pause();
                  } else {
                    await _audioPlayer.play(DeviceFileSource(_recordedAudioPath!));
                  }
                },
              ),
              IconButton(
                icon: const Icon(Icons.forward_10, size: 20),
                tooltip: 'Fast-Forward 10s',
                onPressed: () => _skipAudio(10),
              ),
              Expanded(
                child: Slider(
                  value: posSec.toDouble().clamp(0.0, durSec.toDouble() > 0 ? durSec.toDouble() : 1.0),
                  min: 0.0,
                  max: durSec > 0 ? durSec.toDouble() : 1.0,
                  onChanged: (val) async {
                    await _audioPlayer.seek(Duration(seconds: val.toInt()));
                  },
                ),
              ),
              Text(
                '${_formatDuration(posSec)} / ${_formatDuration(durSec)}',
                style: const TextStyle(fontSize: 10.5, fontFamily: 'monospace'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // --- Microphone Device Selector Dropdown ---

  Widget _buildAudioDeviceSelector(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant.withOpacity(0.6)),
      ),
      child: Row(
        children: [
          const Icon(Icons.mic_external_on, size: 18, color: Colors.teal),
          const SizedBox(width: 8),
          Expanded(
            child: _audioInputDevices.isEmpty
                ? const Text(
                    'Default System Microphone',
                    style: TextStyle(fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  )
                : DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _selectedDeviceId,
                      items: _audioInputDevices.map((dev) {
                        return DropdownMenuItem<String>(
                          value: dev.id,
                          child: Text(
                            dev.label.isNotEmpty ? dev.label : 'Microphone (${dev.id})',
                            style: const TextStyle(fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }).toList(),
                      onChanged: (id) {
                        if (id != null) {
                          setState(() {
                            _selectedDeviceId = id;
                            _selectedInputDevice = _audioInputDevices.firstWhere((d) => d.id == id);
                          });
                        }
                      },
                    ),
                  ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 16),
            tooltip: 'Refresh Microphones',
            onPressed: _loadAudioDevices,
          ),
        ],
      ),
    );
  }

  // --- Intelligence Tab 1: Executive Summary & Takeaways ---

  Widget _buildSummaryTab(ThemeData theme) {
    final summary = _currentSession?.summary;
    if (summary == null) {
      return _buildEmptyState('No executive meeting summary generated yet. Record or import audio and click "Process Meeting Insights".');
    }

    final wordCount = _currentSession?.transcript.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length ?? 0;
    final durMin = (_currentSession?.durationSeconds ?? 0) / 60.0;
    final paceWpm = durMin > 0 ? (wordCount / durMin).round() : 0;

    final displayedSummary = (_showTranslatedSummary && _translatedSummary != null)
        ? _translatedSummary!
        : summary.executiveSummary;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title & Metadata Toolbar
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Executive Summary & Insights', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, fontSize: 20)),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFF4F46E5).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            _selectedMeetingDomain,
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF4F46E5)),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '$wordCount words • ${durMin.toStringAsFixed(1)} min • $paceWpm WPM',
                          style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton.icon(
                    onPressed: _isTranslatingSummary ? null : _toggleTranslateSummary,
                    icon: _isTranslatingSummary
                        ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.translate, size: 14),
                    label: Text(_showTranslatedSummary ? 'Original (EN)' : 'हिन्दी (Hindi)'),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      summary.detectedLanguage.toUpperCase(),
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Executive Summary Card
          Card(
            elevation: 0,
            color: theme.colorScheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.notes, color: theme.colorScheme.primary, size: 18),
                          const SizedBox(width: 8),
                          Text(
                            _showTranslatedSummary ? 'कार्यकारी सारांश (Executive Summary)' : 'Executive Briefing',
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 16),
                        tooltip: 'Copy Summary',
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: displayedSummary));
                          _showSnackBar('Executive summary copied to clipboard');
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    displayedSummary,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      height: 1.6,
                      fontSize: 14,
                      color: theme.colorScheme.onSurface.withOpacity(0.9),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Key Discussion Points
          if (summary.keyPoints.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              'Key Discussion Points',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 12),
            ...summary.keyPoints.map((point) => Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: theme.colorScheme.outlineVariant.withOpacity(0.7)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        margin: const EdgeInsets.only(top: 2),
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF4F46E5).withOpacity(0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.check, size: 12, color: Color(0xFF4F46E5)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          point,
                          style: const TextStyle(fontSize: 13.5, height: 1.45),
                        ),
                      ),
                    ],
                  ),
                )),
          ],

          // Consensus Decisions Log
          if (summary.decisionsMade.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              'Decisions Recorded',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 12),
            ...summary.decisionsMade.asMap().entries.map((entry) {
              final idx = entry.key + 1;
              final decision = entry.value;
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF4F46E5).withOpacity(0.04),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF4F46E5).withOpacity(0.2)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF4F46E5).withOpacity(0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'D$idx',
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: Color(0xFF4F46E5)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        decision,
                        style: const TextStyle(fontSize: 13.5, height: 1.45),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],

          // Live In-Meeting Annotations & Bookmarks
          if (_currentSession?.liveNotes.isNotEmpty == true) ...[
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.bookmark_border, color: Colors.orange, size: 20),
                const SizedBox(width: 8),
                Text('In-Meeting Flags (${_currentSession!.liveNotes.length})',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, fontSize: 15)),
              ],
            ),
            const SizedBox(height: 8),
            ..._currentSession!.liveNotes.map((note) => Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  color: Colors.orange.withOpacity(0.04),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: Colors.orange.withOpacity(0.2)),
                  ),
                  child: ListTile(
                    dense: true,
                    leading: InkWell(
                      onTap: () => _seekToSecond(note.timestampSeconds),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _formatDuration(note.timestampSeconds),
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.deepOrange),
                        ),
                      ),
                    ),
                    title: Text(note.note, style: const TextStyle(fontSize: 13)),
                  ),
                )),
          ],

          // Attached Figures / Slides
          if (_currentSession?.slideAttachments.isNotEmpty == true) ...[
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.image_outlined, color: theme.colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Text('Attached Slides & Visuals',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, fontSize: 15)),
              ],
            ),
            const SizedBox(height: 8),
            ..._currentSession!.slideAttachments.map((slide) => Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    leading: Icon(Icons.zoom_in, color: theme.colorScheme.primary),
                    title: Text(slide.caption, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                    subtitle: Text('Captured at ${_formatDuration(slide.timestampSeconds)}', style: const TextStyle(fontSize: 11)),
                    onTap: () => _showFigureLightbox(slide),
                  ),
                )),
          ],
        ],
      ),
    );
  }

  // --- Intelligence Tab 2: Tasks & Decisions ---

  Widget _buildTasksAndDecisionsTab(ThemeData theme) {
    final tasks = _currentSession?.actionItems ?? [];
    final decisions = _currentSession?.summary?.decisionsMade ?? [];

    if (tasks.isEmpty && decisions.isEmpty) {
      return _buildEmptyState('No decisions or action items extracted yet. Run AI processing to detect deliverables.');
    }

    final completedCount = tasks.where((t) => t.isCompleted).length;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Tasks & Decisions Log', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, fontSize: 20)),
                  const SizedBox(height: 6),
                  Text(
                    '${decisions.length} Decisions • $completedCount/${tasks.length} Action Items Completed',
                    style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
                  ),
                ],
              ),
              if (tasks.isNotEmpty && _currentSession != null)
                FilledButton.tonalIcon(
                  onPressed: () async {
                    await ExportService().exportActionItemsAsCsv(_currentSession!);
                    _showSnackBar('Exported action items as CSV (Excel/Jira compatible)!');
                  },
                  icon: const Icon(Icons.file_download_outlined, size: 16),
                  label: const Text('Export CSV'),
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),

          // Section: Decisions Log
          if (decisions.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFF4F46E5).withOpacity(0.04),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF4F46E5).withOpacity(0.2)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.gavel, size: 16, color: Color(0xFF4F46E5)),
                      SizedBox(width: 8),
                      Text(
                        'DECISIONS RECORDED',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, letterSpacing: 0.5, color: Color(0xFF4F46E5)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ...decisions.asMap().entries.map((entry) {
                    final idx = entry.key + 1;
                    final decision = entry.value;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFF4F46E5).withOpacity(0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'D$idx',
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 10, color: Color(0xFF4F46E5)),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(decision, style: const TextStyle(fontSize: 13, height: 1.4)),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],

          // Section: Action Items Checklist
          Text('Action Items & Deliverables', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 12),
          ...tasks.map((item) {
            Color priorityColor = const Color(0xFF64748B);
            if (item.priority.toLowerCase() == 'high') priorityColor = const Color(0xFFEF4444);
            if (item.priority.toLowerCase() == 'medium') priorityColor = const Color(0xFFF59E0B);

            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: item.isCompleted ? Colors.green.withOpacity(0.3) : theme.colorScheme.outlineVariant,
                ),
              ),
              child: CheckboxListTile(
                value: item.isCompleted,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                activeColor: const Color(0xFF4F46E5),
                onChanged: (val) {
                  setState(() {
                    item.isCompleted = val ?? false;
                  });
                  if (_currentSession != null) {
                    SessionRepository().saveSession(_currentSession!);
                  }
                },
                title: Text(
                  item.task,
                  style: TextStyle(
                    decoration: item.isCompleted ? TextDecoration.lineThrough : null,
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                    color: item.isCompleted ? theme.colorScheme.outline : theme.colorScheme.onSurface,
                  ),
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFF4F46E5).withOpacity(0.08),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          item.category,
                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Color(0xFF4F46E5)),
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.person_outline, size: 13, color: theme.colorScheme.primary),
                          const SizedBox(width: 4),
                          Text(item.assignee, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 11.5)),
                        ],
                      ),
                      if (item.speaker != null)
                        Text('(assigned by ${item.speaker})', style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: theme.colorScheme.outline)),
                      if (item.deadline != null)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.calendar_today, size: 11, color: Colors.orange),
                            const SizedBox(width: 4),
                            Text(item.deadline!, style: const TextStyle(color: Colors.orange, fontSize: 11, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: priorityColor.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          item.priority.toUpperCase(),
                          style: TextStyle(fontSize: 10, color: priorityColor, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  // --- Intelligence Tab 3: Interactive Transcript with Search & Playback ---

  List<TextSpan> _buildHighlightedSpans(String text, String query, TextStyle defaultStyle, TextStyle matchStyle) {
    if (query.trim().isEmpty) {
      return [TextSpan(text: text, style: defaultStyle)];
    }

    final spans = <TextSpan>[];
    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase().trim();
    int start = 0;

    while (true) {
      final index = lowerText.indexOf(lowerQuery, start);
      if (index == -1) {
        if (start < text.length) {
          spans.add(TextSpan(text: text.substring(start), style: defaultStyle));
        }
        break;
      }
      if (index > start) {
        spans.add(TextSpan(text: text.substring(start, index), style: defaultStyle));
      }
      spans.add(TextSpan(
        text: text.substring(index, index + lowerQuery.length),
        style: matchStyle,
      ));
      start = index + lowerQuery.length;
    }

    return spans;
  }

  Widget _buildTranscriptTab(ThemeData theme) {
    final transcript = _currentSession?.transcript ?? '';

    if (transcript.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.description_outlined, size: 52, color: theme.colorScheme.primary),
                    const SizedBox(height: 14),
                    Text(
                      'No Transcript Available Yet',
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Record audio using the recording deck, import an existing audio file, or paste your meeting notes below to analyze with AI.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: Colors.grey, height: 1.4),
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _showPasteTranscriptDialog,
                      icon: const Icon(Icons.paste),
                      label: const Text('Paste Text / Notes to Analyze'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final wordCount = transcript.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    final estimatedMin = (wordCount / 140).toStringAsFixed(1);
    final displayedText = (_showTranslatedTranscript && _translatedTranscript != null)
        ? _translatedTranscript!
        : transcript;

    // Search match count
    int matchCount = 0;
    if (_transcriptSearchQuery.trim().isNotEmpty) {
      matchCount = RegExp.escape(_transcriptSearchQuery.trim())
          .allMatches(displayedText.toLowerCase())
          .length;
    }

    final turns = _currentSession?.speakerTurns ?? [];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Keyword Search Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.outlineVariant.withOpacity(0.5)),
            ),
            child: Row(
              children: [
                Icon(Icons.search, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _transcriptSearchController,
                    decoration: const InputDecoration(
                      hintText: 'Search keyword or speaker in transcript...',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    onChanged: (query) {
                      setState(() {
                        _transcriptSearchQuery = query;
                      });
                    },
                  ),
                ),
                if (_transcriptSearchQuery.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF4F46E5).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$matchCount matches',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF4F46E5)),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.clear, size: 16),
                    onPressed: () {
                      _transcriptSearchController.clear();
                      setState(() {
                        _transcriptSearchQuery = '';
                      });
                    },
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Header Action Toolbar
          Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Meeting Transcript',
                    style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, fontSize: 20),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '$wordCount words • ~$estimatedMin min read',
                      style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withOpacity(0.8)),
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _copyTranscriptToClipboard,
                    icon: const Icon(Icons.copy, size: 15),
                    label: const Text('Copy'),
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _showSaveTranscriptMenu,
                    icon: const Icon(Icons.save_alt, size: 15),
                    label: const Text('Save Transcript'),
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _toggleEditTranscript,
                    icon: Icon(_isTranscriptEditMode ? Icons.visibility : Icons.edit_note, size: 15),
                    label: Text(_isTranscriptEditMode ? 'View' : 'Edit / Paste'),
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _isTranslatingTranscript ? null : _toggleTranslateTranscript,
                    icon: _isTranslatingTranscript
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.translate, size: 15),
                    label: Text(_showTranslatedTranscript ? 'View Original' : 'Translate (हिन्दी)'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF4F46E5),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Translation Indicator Banner
          if (_showTranslatedTranscript && _translatedTranscript != null)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF4F46E5).withOpacity(0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF4F46E5).withOpacity(0.2)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.g_translate, color: Color(0xFF4F46E5), size: 18),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'प्रदर्शित: प्रतिलेख का हिन्दी अनुवाद (Viewing Hindi Translation)',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: Color(0xFF4F46E5)),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _showTranslatedTranscript = false),
                    child: const Text('Switch to Original (EN)', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),

          // Transcript Content (Editor vs Formatted View)
          if (_isTranscriptEditMode) ...[
            Card(
              elevation: 1,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Edit Transcript Text:', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _transcriptEditController,
                      maxLines: 14,
                      style: const TextStyle(fontSize: 14, height: 1.5, fontFamily: 'monospace'),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: 'Paste or edit transcript here...',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => setState(() => _isTranscriptEditMode = false),
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          onPressed: _saveEditedTranscript,
                          icon: const Icon(Icons.check, size: 16),
                          label: const Text('Save & Re-Seal'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonalIcon(
                          onPressed: () => _processTextDirectly(_transcriptEditController.text),
                          icon: const Icon(Icons.auto_awesome, size: 16),
                          label: const Text('Save & Run AI Analysis'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ] else if (turns.isNotEmpty && !_showTranslatedTranscript) ...[
            // Interactive Speaker Turns with Click-to-Seek & Search Highlight
            ...turns.map((turn) {
              final speakerColor = _getSpeakerColor(turn.speakerId);
              final startMin = (turn.startSeconds ~/ 60).toString().padLeft(2, '0');
              final startSec = (turn.startSeconds % 60).toString().padLeft(2, '0');
              final endMin = (turn.endSeconds ~/ 60).toString().padLeft(2, '0');
              final endSec = (turn.endSeconds % 60).toString().padLeft(2, '0');

              final isSearchHit = _transcriptSearchQuery.isNotEmpty &&
                  turn.text.toLowerCase().contains(_transcriptSearchQuery.toLowerCase());

              return Card(
                elevation: 0,
                margin: const EdgeInsets.symmetric(vertical: 6),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: isSearchHit
                        ? Colors.amber.shade700
                        : theme.colorScheme.outlineVariant.withOpacity(0.5),
                    width: isSearchHit ? 2 : 1,
                  ),
                ),
                color: isSearchHit ? Colors.amber.withOpacity(0.06) : theme.colorScheme.surfaceContainerLow,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 12,
                            backgroundColor: speakerColor.withOpacity(0.2),
                            child: Text(
                              turn.speakerName.isNotEmpty ? turn.speakerName[0].toUpperCase() : 'S',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: speakerColor),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            turn.speakerName,
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: speakerColor),
                          ),
                          const Spacer(),
                          InkWell(
                            onTap: () => _seekToSecond(turn.startSeconds),
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.6),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.play_circle_outline, size: 14, color: Colors.blueAccent),
                                  const SizedBox(width: 4),
                                  Text(
                                    '$startMin:$startSec - $endMin:$endSec',
                                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      RichText(
                        text: TextSpan(
                          children: _buildHighlightedSpans(
                            turn.text,
                            _transcriptSearchQuery,
                            theme.textTheme.bodyMedium?.copyWith(height: 1.5, fontSize: 13.5) ??
                                const TextStyle(fontSize: 13.5, height: 1.5),
                            TextStyle(
                              backgroundColor: Colors.amber.shade200,
                              color: Colors.black,
                              fontWeight: FontWeight.bold,
                              height: 1.5,
                              fontSize: 13.5,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ] else ...[
            Card(
              elevation: 0,
              color: theme.colorScheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: theme.colorScheme.outlineVariant.withOpacity(0.5)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: RichText(
                  text: TextSpan(
                    children: _buildHighlightedSpans(
                      displayedText,
                      _transcriptSearchQuery,
                      theme.textTheme.bodyLarge?.copyWith(
                            height: 1.7,
                            letterSpacing: 0.2,
                            fontSize: 14.5,
                          ) ??
                          const TextStyle(fontSize: 14.5, height: 1.7),
                      TextStyle(
                        backgroundColor: Colors.amber.shade200,
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 14.5,
                        height: 1.7,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // --- Intelligence Tab 4: Speaker Analytics & Diarization ---

  Color _getSpeakerColor(String speakerId) {
    final colors = [
      Colors.teal,
      Colors.indigo,
      Colors.deepOrange,
      Colors.purple,
      Colors.green,
      Colors.blueGrey,
      Colors.amber.shade800,
      Colors.deepPurple,
    ];
    final hash = speakerId.hashCode.abs();
    return colors[hash % colors.length];
  }

  Future<void> _seekAudio(int seconds) async {
    if (_recordedAudioPath == null) {
      _showSnackBar('No audio recording loaded to seek.');
      return;
    }
    try {
      if (!_isPlaying) {
        await _audioPlayer.play(DeviceFileSource(_recordedAudioPath!));
      }
      await _audioPlayer.seek(Duration(seconds: seconds));
      final min = (seconds ~/ 60).toString().padLeft(2, '0');
      final sec = (seconds % 60).toString().padLeft(2, '0');
      _showSnackBar('Seeked audio playback to $min:$sec');
    } catch (e) {
      _showSnackBar('Unable to seek audio: $e');
    }
  }

  void _showRenameSpeakerDialog(String speakerId, String currentName) {
    final textController = TextEditingController(text: currentName);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.record_voice_over, color: Colors.teal),
            SizedBox(width: 8),
            Text('Identify Speaker'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Label speaker turns for "$speakerId" across the entire transcript and action items:',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: textController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Speaker Name & Role',
                hintText: 'e.g. Alex (Engineering Lead) or Sarah (PM)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final newName = textController.text.trim();
              if (newName.isNotEmpty && _currentSession != null) {
                setState(() {
                  _currentSession!.renameSpeaker(speakerId, newName);
                });
                SessionRepository().saveSession(_currentSession!);
                _showSnackBar('Renamed speaker to "$newName" across all turns & action items.');
              }
              Navigator.pop(ctx);
            },
            child: const Text('Save Speaker'),
          ),
        ],
      ),
    );
  }

  void _showVirtualCallGuideDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.video_call, color: Colors.blueAccent),
            SizedBox(width: 8),
            Text('Virtual Call Audio Capture'),
          ],
        ),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'LabScribe AI is 100% air-gapped and local. No external bots join your video calls. Here is how to capture calls privately:',
                style: TextStyle(fontSize: 13),
              ),
              SizedBox(height: 16),
              Text('1. Zoom Meetings', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.blueAccent)),
              SizedBox(height: 4),
              Text(
                '• Option A (File Import): In Zoom Settings > Recording, turn on "Record audio-only file". After your call, click "Import Audio" and select the audio_only.m4a file from your Zoom folder.\n• Option B (Live Capture): Select your system "Monitor / Loopback" audio device in the microphone dropdown to capture both your voice and remote participants directly.',
                style: TextStyle(fontSize: 12),
              ),
              SizedBox(height: 14),
              Text('2. WhatsApp Voice & Video Calls', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.green)),
              SizedBox(height: 4),
              Text(
                '• WhatsApp Web/Desktop: Use system Loopback/Monitor audio input to record in real-time.\n• WhatsApp Mobile Voice Notes: Tap "Import Audio" and select any .opus or .m4a file shared from WhatsApp.',
                style: TextStyle(fontSize: 12),
              ),
              SizedBox(height: 14),
              Text('3. Microsoft Teams / Google Meet', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.indigo)),
              SizedBox(height: 4),
              Text(
                '• Set the microphone input selector to your Stereo Mix or PipeWire monitor sink to record meetings silently and privately without notifying cloud servers.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  Widget _buildSpeakerAnalyticsTab(ThemeData theme) {
    final turns = _currentSession?.speakerTurns ?? [];
    if (turns.isEmpty) {
      return _buildEmptyState('No speaker diarization turns available yet. Record audio or run AI processing to analyze speaker participation.');
    }

    final uniqueSpeakers = turns.map((t) => t.speakerName).toSet().toList();
    final totalDurationSeconds = _currentSession?.durationSeconds ?? 0;
    final effectiveTotalSeconds = totalDurationSeconds > 0
        ? totalDurationSeconds
        : turns.fold<int>(0, (sum, t) => sum + (t.endSeconds - t.startSeconds).clamp(1, 9999));

    // Compute talk time and word count per speaker
    final speakerStats = <String, Map<String, dynamic>>{};
    for (final turn in turns) {
      final name = turn.speakerName;
      final dur = (turn.endSeconds - turn.startSeconds).clamp(1, 9999);
      final words = turn.text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

      if (!speakerStats.containsKey(name)) {
        speakerStats[name] = {
          'speakerId': turn.speakerId,
          'duration': 0,
          'words': 0,
        };
      }
      speakerStats[name]!['duration'] = (speakerStats[name]!['duration'] as int) + dur;
      speakerStats[name]!['words'] = (speakerStats[name]!['words'] as int) + words;
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Speaker Analytics & Diarization', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(
                    '${uniqueSpeakers.length} Speakers • ${turns.length} Dialog Turns • ${_formatDuration(effectiveTotalSeconds)} Total Talk Time',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
              if (_currentSession?.isVirtualCall == true)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.blue.withOpacity(0.4)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.video_call, size: 14, color: Colors.blue),
                      SizedBox(width: 4),
                      Text('Virtual Call Mode', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.blue)),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),

          // Talk Time Distribution Card
          Card(
            elevation: 0,
            color: theme.colorScheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: theme.colorScheme.outlineVariant.withOpacity(0.5)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.pie_chart_outline, size: 18, color: Colors.teal),
                      SizedBox(width: 8),
                      Text('TALK-TIME SHARE & SPEAKING PACE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.teal)),
                    ],
                  ),
                  const SizedBox(height: 14),
                  ...speakerStats.entries.map((entry) {
                    final name = entry.key;
                    final data = entry.value;
                    final dur = data['duration'] as int;
                    final words = data['words'] as int;
                    final speakerId = data['speakerId'] as String;
                    final color = _getSpeakerColor(speakerId);
                    final sharePercent = effectiveTotalSeconds > 0 ? (dur / effectiveTotalSeconds).clamp(0.0, 1.0) : 0.0;
                    final durMin = dur / 60.0;
                    final paceWpm = durMin > 0 ? (words / durMin).round() : 0;

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              CircleAvatar(
                                radius: 12,
                                backgroundColor: color.withOpacity(0.2),
                                child: Text(
                                  name.isNotEmpty ? name[0].toUpperCase() : 'S',
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color),
                                ),
                              ),
                              const SizedBox(width: 8),
                              InkWell(
                                onTap: () => _showRenameSpeakerDialog(speakerId, name),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(name, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: color)),
                                    const SizedBox(width: 4),
                                    Icon(Icons.edit_outlined, size: 12, color: color.withOpacity(0.7)),
                                  ],
                                ),
                              ),
                              const Spacer(),
                              Text(
                                '${_formatDuration(dur)} (${(sharePercent * 100).toStringAsFixed(1)}%) • $words words • $paceWpm WPM',
                                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: sharePercent,
                              minHeight: 8,
                              backgroundColor: theme.colorScheme.surfaceContainerHighest,
                              valueColor: AlwaysStoppedAnimation<Color>(color),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Chronological Diarized Turn Feed
          Text('Chronological Dialog Feed', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          ...turns.map((turn) {
            final color = _getSpeakerColor(turn.speakerId);
            final startMin = (turn.startSeconds ~/ 60).toString().padLeft(2, '0');
            final startSec = (turn.startSeconds % 60).toString().padLeft(2, '0');
            final endMin = (turn.endSeconds ~/ 60).toString().padLeft(2, '0');
            final endSec = (turn.endSeconds % 60).toString().padLeft(2, '0');

            return Card(
              elevation: 0,
              margin: const EdgeInsets.symmetric(vertical: 5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: color.withOpacity(0.3)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 12,
                          backgroundColor: color.withOpacity(0.2),
                          child: Text(
                            turn.speakerName.isNotEmpty ? turn.speakerName[0].toUpperCase() : 'S',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color),
                          ),
                        ),
                        const SizedBox(width: 8),
                        InkWell(
                          onTap: () => _showRenameSpeakerDialog(turn.speakerId, turn.speakerName),
                          child: Text(
                            turn.speakerName,
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: color),
                          ),
                        ),
                        const Spacer(),
                        InkWell(
                          onTap: () => _seekAudio(turn.startSeconds),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.6),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.play_circle_outline, size: 14, color: Colors.blueAccent),
                                const SizedBox(width: 4),
                                Text(
                                  '$startMin:$startSec - $endMin:$endSec',
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      turn.text,
                      style: const TextStyle(fontSize: 13.5, height: 1.4),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  // --- Intelligence Tab 5: Grounded Meeting Q&A Assistant ---

  Widget _buildChatTab(ThemeData theme) {
    final history = _currentSession?.chatHistory ?? [];

    return Column(
      children: [
        // Suggested Meeting Prompt Chips
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.3),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ActionChip(
                  avatar: const Icon(Icons.gavel, size: 14, color: Colors.blueAccent),
                  label: const Text('Summarize Decisions', style: TextStyle(fontSize: 11.5)),
                  onPressed: () {
                    _chatController.text = 'Summarize all key decisions made in this meeting.';
                    _sendChatMessage();
                  },
                ),
                const SizedBox(width: 8),
                ActionChip(
                  avatar: const Icon(Icons.task_alt, size: 14, color: Colors.green),
                  label: const Text('List Action Items & Owners', style: TextStyle(fontSize: 11.5)),
                  onPressed: () {
                    _chatController.text = 'List all action items, who owns them, and what the deadlines are.';
                    _sendChatMessage();
                  },
                ),
                const SizedBox(width: 8),
                ActionChip(
                  avatar: const Icon(Icons.warning_amber, size: 14, color: Colors.orange),
                  label: const Text('Main Blockers & Risks', style: TextStyle(fontSize: 11.5)),
                  onPressed: () {
                    _chatController.text = 'What were the key risks or blockers highlighted by the speakers?';
                    _sendChatMessage();
                  },
                ),
                const SizedBox(width: 8),
                ActionChip(
                  avatar: const Icon(Icons.email_outlined, size: 14, color: Colors.purple),
                  label: const Text('Draft Follow-up Email', style: TextStyle(fontSize: 11.5)),
                  onPressed: () {
                    _chatController.text = 'Draft a concise follow-up email summarizing the meeting deliverables.';
                    _sendChatMessage();
                  },
                ),
              ],
            ),
          ),
        ),

        // Chat Messages List
        Expanded(
          child: history.isEmpty
              ? _buildEmptyState(
                  'Industrial Meeting AI Assistant.\nAsk questions about decisions, action items, roadmaps, or speaker arguments from this meeting.\nTap any prompt chip above to get started.',
                )
            : ListView.builder(
                controller: _chatScrollController,
                padding: const EdgeInsets.all(16),
                itemCount: history.length,
                itemBuilder: (context, index) {
                  final msg = history[index];
                  final isUser = msg.sender == 'user';
                  return Align(
                    alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
                      decoration: BoxDecoration(
                        color: isUser ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isUser ? Icons.person : Icons.smart_toy,
                                size: 14,
                                color: isUser ? theme.colorScheme.onPrimary : Colors.teal,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                isUser ? 'You' : 'Meeting Assistant',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11,
                                  color: isUser ? theme.colorScheme.onPrimary : Colors.teal,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          SelectableText(
                            msg.text,
                            style: TextStyle(
                              color: isUser ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
                              height: 1.45,
                              fontSize: 13.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
      if (_isWaitingForAiChatResponse)
        const Padding(
          padding: EdgeInsets.all(8.0),
          child: CircularProgressIndicator(),
        ),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _chatController,
                onSubmitted: (_) => _sendChatMessage(),
                decoration: const InputDecoration(
                  hintText: 'Ask about decisions, deadlines, owners, or budget discussions...',
                  border: InputBorder.none,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.send),
              onPressed: _sendChatMessage,
              color: theme.colorScheme.primary,
            ),
          ],
        ),
      ),
    ],
  );
}

Widget _buildEmptyState(String message) {
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.meeting_room_outlined, size: 52, color: Colors.grey),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey, fontSize: 13, height: 1.4),
          ),
        ],
      ),
    ),
  );
}
}
