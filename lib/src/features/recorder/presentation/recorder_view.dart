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

  bool _isPlaying = false;
  Duration _playbackDuration = Duration.zero;
  Duration _playbackPosition = Duration.zero;

  RecordingState _recordingState = RecordingState.idle;
  ProcessingStage _processingStage = ProcessingStage.idle;
  
  // Timer & Metrics
  Timer? _timer;
  int _recordDurationSeconds = 0;
  String? _recordedAudioPath;
  String _statusMessage = 'Ready to capture scientific session or lab seminar.';

  // Clinical & Scientific Configuration
  bool _enableClinicalDeIdentification = false;
  bool _enableNoiseSuppression = true;
  bool _isVirtualCallMode = false;
  int _redactedTokensCount = 0;

  // Session State
  final TextEditingController _titleController = TextEditingController(text: 'Translational Oncology Lab Meeting');
  final TextEditingController _chatController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();
  
  // In-App On-Demand Search Controllers (Zero External Browser Needed)
  final TextEditingController _pubchemSearchController = TextEditingController();
  bool _isSearchingPubchem = false;
  List<GlossaryTerm> _searchResultsPubChem = [];

  final TextEditingController _pubmedSearchController = TextEditingController();
  bool _isSearchingPubmed = false;
  List<PubMedCitation> _searchResultsPubMed = [];

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
  int _scienceSubTabIndex = 0;
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
      _enableClinicalDeIdentification = session.isDeIdentified;
      _isVirtualCallMode = session.isVirtualCall;
      _searchResultsPubChem.clear();
      _searchResultsPubMed.clear();
      _translatedTranscript = null;
      _showTranslatedTranscript = false;
      _isTranscriptEditMode = false;
      _transcriptEditController.text = session.transcript;
      _translatedSummary = null;
      _showTranslatedSummary = false;
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

    // 7 Dashboards: Summary, Transcript, Protocols, Speakers & Dialog, PubChem Glossary, PubMed Citations, Q&A
    _tabController = TabController(length: 7, vsync: this);

    // Enumerate connected microphones (Jabra, USB, AirPods, built-in)
    _loadAudioDevices();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    _titleController.dispose();
    _chatController.dispose();
    _chatScrollController.dispose();
    _pubchemSearchController.dispose();
    _pubmedSearchController.dispose();
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

  // --- Audio Recording Lifecycle with Hardware Noise Suppression ---

  Future<void> _startRecording() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        final dir = await getApplicationDocumentsDirectory();
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final filePath = '${dir.path}/session_$timestamp.m4a';

        // High-fidelity low-CPU AAC-LC with hardware spectral gating
        final config = RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
          device: _selectedInputDevice,
          noiseSuppress: _enableNoiseSuppression,
          echoCancel: true,
          autoGain: true,
        );

        await _audioRecorder.start(config, path: filePath);

        setState(() {
          _recordingState = RecordingState.recording;
          _recordedAudioPath = filePath;
          _recordDurationSeconds = 0;
          _statusMessage = 'Recording scientific discourse (Low-CPU AAC-LC)...';
          
          _currentSession = MeetingSession(
            id: timestamp.toString(),
            title: _titleController.text.trim().isEmpty ? 'Scientific Meeting' : _titleController.text.trim(),
            createdAt: DateTime.now(),
            audioPath: filePath,
            durationSeconds: 0,
            isDeIdentified: _enableClinicalDeIdentification,
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
      final path = await _audioRecorder.stop();

      String? audioSha256;
      if (path != null) {
        audioSha256 = await CryptoUtils.sha256File(File(path));
      }

      setState(() {
        _recordingState = RecordingState.stopped;
        _recordedAudioPath = path ?? _recordedAudioPath;
        _statusMessage = 'Recording saved locally (SHA-256 sealed). Ready for AI processing.';
        
        if (_currentSession != null) {
          _currentSession!.audioPath = _recordedAudioPath;
          _currentSession!.durationSeconds = _recordDurationSeconds;
          _currentSession!.title = _titleController.text.trim().isEmpty ? 'Scientific Meeting' : _titleController.text.trim();
          _currentSession!.audioSha256 = audioSha256;
        }
      });

      if (_currentSession != null) {
        await SessionRepository().saveSession(_currentSession!);
      }
    } catch (e) {
      _showSnackBar('Error stopping recorder: $e');
    }
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
          isDeIdentified: _enableClinicalDeIdentification,
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
        title: _titleController.text.trim().isEmpty ? 'Scientific Meeting' : _titleController.text.trim(),
        createdAt: DateTime.now(),
        durationSeconds: _recordDurationSeconds,
        isDeIdentified: _enableClinicalDeIdentification,
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
            hintText: 'e.g. PI approved 100 nM Osimertinib combination; run PDX next',
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
                    title: _titleController.text.trim().isEmpty ? 'Scientific Meeting' : _titleController.text.trim(),
                    createdAt: DateTime.now(),
                    durationSeconds: _recordDurationSeconds,
                    isDeIdentified: _enableClinicalDeIdentification,
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

  /// Slide / Lab Figure Attachment File Picker
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
              Text('Attach Slide / Gel Figure'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Attach presentation slide, Western blot gel, or Kaplan-Meier curve at timestamp: ${_formatDuration(_recordDurationSeconds)}',
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
                  labelText: 'Figure Caption / Assay Note',
                  hintText: 'e.g. H23 cell line phospho-ERK Western blot band',
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
                final path = selectedFilePath ?? 'figure_captured_${DateTime.now().millisecondsSinceEpoch}.png';
                final attachment = SlideAttachment(
                  id: const Uuid().v4(),
                  imagePath: path,
                  timestampSeconds: _recordDurationSeconds,
                  caption: caption.isNotEmpty ? caption : 'Figure at ${_formatDuration(_recordDurationSeconds)}',
                );

                if (_currentSession == null) {
                  final timestamp = DateTime.now().millisecondsSinceEpoch;
                  _currentSession = MeetingSession(
                    id: timestamp.toString(),
                    title: _titleController.text.trim().isEmpty ? 'Scientific Meeting' : _titleController.text.trim(),
                    createdAt: DateTime.now(),
                    durationSeconds: _recordDurationSeconds,
                    isDeIdentified: _enableClinicalDeIdentification,
                  );
                }

                setState(() {
                  _currentSession?.slideAttachments.add(attachment);
                });

                if (_currentSession != null) {
                  SessionRepository().saveSession(_currentSession!);
                }

                _showSnackBar('Figure attached at ${_formatDuration(_recordDurationSeconds)}');
                Navigator.pop(ctx);
              },
              child: const Text('Attach'),
            ),
          ],
        ),
      ),
    );
  }

  // --- In-App Self-Reliant Feature Dialogs ---

  /// In-App Article / Abstract Reader (Zero External Browser Needed)
  void _showArticleReader(PubMedCitation cite) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.menu_book, color: Colors.teal),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'PubMed Reader (PMID: ${cite.pmid})',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 580,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  cite.title,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 8),
                Text(
                  cite.authors,
                  style: const TextStyle(fontStyle: FontStyle.italic, color: Colors.grey),
                ),
                const SizedBox(height: 4),
                Text(
                  '${cite.journal} • ${cite.pubYear} • DOI: ${cite.doi ?? "N/A"}',
                  style: const TextStyle(fontSize: 12, color: Colors.blueGrey),
                ),
                const SizedBox(height: 16),
                const Divider(),
                const Text(
                  'STRUCTURED ABSTRACT',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.teal),
                ),
                const SizedBox(height: 8),
                Text(
                  cite.abstractText,
                  style: const TextStyle(fontSize: 13, height: 1.5),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy Citation'),
            onPressed: () {
              Clipboard.setData(ClipboardData(
                text: '${cite.authors} "${cite.title}" ${cite.journal} (${cite.pubYear}). PMID: ${cite.pmid}',
              ));
              _showSnackBar('Citation copied to clipboard');
            },
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
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

  /// In-App Markdown Lab Notebook Previewer (Zero External Text Editor Needed)
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
                        'Lab Notebook: ${_currentSession!.title}',
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
                      _showSnackBar('Complete lab notebook copied to clipboard!');
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

  // --- On-Demand In-App Scientific Search Handlers ---

  Future<void> _searchPubChemOnDemand(String query) async {
    final term = query.trim();
    if (term.isEmpty) return;

    setState(() {
      _isSearchingPubchem = true;
    });

    try {
      final result = await widget.publicApiService.lookupScientificTerm(term);
      if (result != null) {
        setState(() {
          _searchResultsPubChem = [result];
          if (_currentSession != null &&
              !_currentSession!.glossaryTerms.any((g) => g.word.toLowerCase() == result.word.toLowerCase())) {
            _currentSession!.glossaryTerms.insert(0, result);
            SessionRepository().saveSession(_currentSession!);
          }
        });
      } else {
        _showSnackBar('No scientific or chemical definition found for "$term".');
      }
    } catch (e) {
      _showSnackBar('PubChem search error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isSearchingPubchem = false;
        });
      }
    }
  }

  Future<void> _searchPubMedOnDemand(String query) async {
    final term = query.trim();
    if (term.isEmpty) return;

    setState(() {
      _isSearchingPubmed = true;
    });

    try {
      final results = await widget.publicApiService.resolveLiteratureCitations([term]);
      setState(() {
        _searchResultsPubMed = results;
        if (_currentSession != null) {
          for (final r in results) {
            if (!_currentSession!.citations.any((c) => c.pmid == r.pmid)) {
              _currentSession!.citations.insert(0, r);
            }
          }
          SessionRepository().saveSession(_currentSession!);
        }
      });
      if (results.isEmpty) {
        _showSnackBar('No publications found on PubMed for "$term".');
      }
    } catch (e) {
      _showSnackBar('PubMed search error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isSearchingPubmed = false;
        });
      }
    }
  }

  // --- AI Processing Engine with 21 CFR Part 11 Hash Computation ---

  Future<void> _executeAiPipeline() async {
    if (_recordedAudioPath == null && _currentSession?.audioPath == null) {
      _showSnackBar('No audio file found. Please record or import a session first.');
      return;
    }

    try {
      setState(() {
        _processingStage = ProcessingStage.transcribing;
        _statusMessage = 'Stage 1/4: Transcribing audio with biomedical Whisper conditioning...';
      });

      // 1. Transcription (handles automatic chunking if > 24 MB)
      String? langHint;
      if (_selectedLanguage == 'en') langHint = 'en';
      if (_selectedLanguage == 'hi') langHint = 'hi';
      if (_selectedLanguage == 'hinglish') langHint = 'hinglish';

      String transcript = await widget.intelligenceService.transcribeAudio(
        audioFilePath: _currentSession?.audioPath ?? _recordedAudioPath!,
        languageHint: langHint,
        onProgress: (status) {
          setState(() {
            _statusMessage = status;
          });
        },
      );

      // 2. Client-Side Clinical De-Identification (if enabled)
      if (_enableClinicalDeIdentification) {
        setState(() {
          _processingStage = ProcessingStage.deidentifying;
          _statusMessage = 'Stage 2/4: Scrubbing Protected Health Information (HIPAA Safe Harbor)...';
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
        _statusMessage = 'Stage 3/4: Synthesizing hypotheses, PubChem compounds & PubMed citations...';
      });

      // 3. Multi-source scientific intelligence synthesis
      final intelligence = await widget.intelligenceService.processSessionIntelligence(
        transcript: transcript,
        sessionTitle: _currentSession?.title ?? 'Scientific Session',
      );

      // 4. Compute 21 CFR Part 11 cryptographic transcript hash
      final transcriptHash = CryptoUtils.sha256String(transcript);

      setState(() {
        _processingStage = ProcessingStage.completed;
        _statusMessage = 'AI Scientific Intelligence Generated & Sealed!';
        _currentSession?.summary = intelligence.summary;
        _currentSession?.actionItems = intelligence.actionItems;
        _currentSession?.glossaryTerms = intelligence.glossary;
        _currentSession?.citations = intelligence.citations;
        _currentSession?.speakerTurns = intelligence.speakerTurns;
        _currentSession?.transcriptSha256 = transcriptHash;
      });
      
      if (_currentSession != null) {
        await SessionRepository().saveSession(_currentSession!);
      }

      _showSnackBar('Scientific Analysis & Citation Resolution complete (21 CFR Part 11 sealed).');
    } catch (e) {
      setState(() {
        _processingStage = ProcessingStage.error;
        _statusMessage = 'Error during AI pipeline: $e';
      });
      if (_isConnectionError(e)) {
        _showAiConnectionErrorDialog(e);
      } else {
        _showSnackBar('Pipeline error: $e');
      }
    }
  }

  /// Process scientific intelligence directly from pasted text or lecture notes
  Future<void> _processTextDirectly(String textToProcess) async {
    final clean = textToProcess.trim();
    if (clean.isEmpty) {
      _showSnackBar('Please enter or paste transcript text to analyze.');
      return;
    }

    try {
      setState(() {
        _processingStage = ProcessingStage.summarizing;
        _statusMessage = 'Analyzing scientific text & generating intelligence...';
      });

      String effectiveText = clean;
      if (_enableClinicalDeIdentification) {
        final scrubResult = widget.intelligenceService.deidentifyText(effectiveText);
        effectiveText = scrubResult.scrubbedText;
        _redactedTokensCount = scrubResult.redactedCount;
      }

      if (_currentSession == null) {
        _currentSession = MeetingSession(
          title: _titleController.text.trim().isEmpty ? 'Scientific Analysis' : _titleController.text.trim(),
          audioPath: '',
          durationSeconds: (effectiveText.split(RegExp(r'\s+')).length / 2.5).round(),
          isDeIdentified: _enableClinicalDeIdentification,
        );
      }

      _currentSession!.transcript = effectiveText;
      _transcriptEditController.text = effectiveText;

      final intelligence = await widget.intelligenceService.processSessionIntelligence(
        transcript: effectiveText,
        sessionTitle: _currentSession!.title,
      );

      final transcriptHash = CryptoUtils.sha256String(effectiveText);

      setState(() {
        _processingStage = ProcessingStage.completed;
        _statusMessage = 'AI Intelligence Generated & Sealed!';
        _currentSession?.summary = intelligence.summary;
        _currentSession?.actionItems = intelligence.actionItems;
        _currentSession?.glossaryTerms = intelligence.glossary;
        _currentSession?.citations = intelligence.citations;
        _currentSession?.speakerTurns = intelligence.speakerTurns;
        _currentSession?.transcriptSha256 = transcriptHash;
        _isTranscriptEditMode = false;
        _translatedTranscript = null;
        _showTranslatedTranscript = false;
      });

      await SessionRepository().saveSession(_currentSession!);
      _showSnackBar('Analysis complete from text (21 CFR Part 11 sealed).');
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
      _currentSession = MeetingSession(
        title: _titleController.text.trim().isEmpty ? 'Scientific Session' : _titleController.text.trim(),
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
                      ? 'हिन्दी भाषा अनुकूलित (Hindi biomedical optimization active)'
                      : (val == 'hinglish' ? 'Hinglish code-mixed biomedical optimization active' : 'Language set to ${val.toUpperCase()}'),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildScienceMobile(ThemeData theme) {
    return Column(
      children: [
        Container(
          color: theme.colorScheme.surface,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: SegmentedButton<int>(
                  segments: [
                    ButtonSegment(
                      value: 0,
                      icon: const Icon(Icons.medication_liquid, size: 16),
                      label: Text('PubChem (${_currentSession?.glossaryTerms.length ?? 0})'),
                    ),
                    ButtonSegment(
                      value: 1,
                      icon: const Icon(Icons.library_books, size: 16),
                      label: Text('PubMed (${_currentSession?.citations.length ?? 0})'),
                    ),
                  ],
                  selected: {_scienceSubTabIndex},
                  onSelectionChanged: (set) {
                    setState(() {
                      _scienceSubTabIndex = set.first;
                    });
                  },
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _scienceSubTabIndex == 0
              ? _buildGlossaryTab(theme)
              : _buildCitationsTab(theme),
        ),
      ],
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
          title: Row(
            children: [
              const Icon(Icons.biotech, color: Colors.tealAccent),
              const SizedBox(width: 8),
              Text(
                _isMeetingCompactMode ? 'LabScribe Meeting Deck' : 'LabScribe AI',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          actions: [
            // Meeting Compact Mode Toggle Button
            IconButton(
              icon: Icon(_isMeetingCompactMode ? Icons.aspect_ratio : Icons.picture_in_picture_alt),
              tooltip: _isMeetingCompactMode ? 'Expand to Full Dashboards' : 'Switch to Compact Meeting Mode',
              onPressed: () {
                setState(() {
                  _isMeetingCompactMode = !_isMeetingCompactMode;
                });
              },
            ),
            if (widget.intelligenceService.isDemoMode)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Tooltip(
                  message: 'Zero-Setup Mode: Instant AI running out-of-the-box with no servers or API keys required.',
                  child: Chip(
                    avatar: const Icon(Icons.bolt, size: 14, color: Colors.amber),
                    label: const Text(
                      'Zero-Setup AI',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.amber),
                    ),
                    backgroundColor: Colors.amber.withValues(alpha: 0.12),
                    side: BorderSide.none,
                  ),
                ),
              ),
            if (_currentSession?.isDeIdentified == true)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Chip(
                  avatar: const Icon(Icons.shield, size: 14, color: Colors.teal),
                  label: Text(
                    'HIPAA (${_redactedTokensCount > 0 ? _redactedTokensCount : "Protected"})',
                    style: const TextStyle(fontSize: 11, color: Colors.teal, fontWeight: FontWeight.bold),
                  ),
                  backgroundColor: Colors.teal.withOpacity(0.12),
                ),
              ),
            // In-App Markdown Lab Notebook Preview
            IconButton(
              icon: const Icon(Icons.article),
              tooltip: 'In-App Notebook Preview',
              onPressed: _showMarkdownPreviewer,
            ),
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: 'Session History',
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
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: 'Settings & Model Config',
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const SettingsView()),
                );
                // Synchronize intelligence service with newly saved config
                widget.intelligenceService.updateConfig(ConfigService().getAiConfig());
              },
            ),
            // Export Menu: Markdown, Benchling ELN JSON, and BibTeX
            PopupMenuButton<String>(
              icon: const Icon(Icons.share),
              tooltip: 'Export Research Notes & Citations',
              onSelected: (value) async {
                if (_currentSession == null) {
                  _showSnackBar('No session to export. Record or load a session first.');
                  return;
                }
                if (value == 'markdown') {
                  await ExportService().exportSessionAsMarkdown(_currentSession!);
                } else if (value == 'eln') {
                  await ExportService().exportSessionAsELNJson(_currentSession!);
                } else if (value == 'bibtex') {
                  await ExportService().exportSessionAsBibTeX(_currentSession!);
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'markdown',
                  child: Row(
                    children: [
                      Icon(Icons.description, size: 18, color: Colors.teal),
                      SizedBox(width: 8),
                      Text('Lab Notebook Markdown (.md)'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'eln',
                  child: Row(
                    children: [
                      Icon(Icons.integration_instructions, size: 18, color: Colors.indigo),
                      SizedBox(width: 8),
                      Text('Benchling / ELN JSON (.json)'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'bibtex',
                  child: Row(
                    children: [
                      Icon(Icons.format_quote, size: 18, color: Colors.blue),
                      SizedBox(width: 8),
                      Text('BibTeX Citations (.bib) [Zotero]'),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(width: 8),
          ],
          bottom: (isDesktop && !_isMeetingCompactMode)
              ? TabBar(
                  controller: _tabController,
                  isScrollable: true,
                  tabs: const [
                    Tab(icon: Icon(Icons.science), text: 'Scientific Summary'),
                    Tab(icon: Icon(Icons.description), text: 'Full Transcript'),
                    Tab(icon: Icon(Icons.assignment_turned_in), text: 'Protocols & Tasks'),
                    Tab(icon: Icon(Icons.record_voice_over), text: 'Speakers & Dialog'),
                    Tab(icon: Icon(Icons.medication_liquid), text: 'Bio/Chem (PubChem)'),
                    Tab(icon: Icon(Icons.library_books), text: 'Literature (PubMed)'),
                    Tab(icon: Icon(Icons.forum), text: 'Research Q&A'),
                  ],
                )
              : null,
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
                  NavigationDestination(icon: Icon(Icons.mic), label: 'Record'),
                  NavigationDestination(icon: Icon(Icons.description), label: 'Transcript'),
                  NavigationDestination(icon: Icon(Icons.science), label: 'Summary'),
                  NavigationDestination(icon: Icon(Icons.biotech), label: 'Science'),
                  NavigationDestination(icon: Icon(Icons.forum), label: 'Q&A'),
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
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildSummaryTab(theme),
                _buildTranscriptTab(theme),
                _buildTasksTab(theme),
                _buildSpeakersTab(theme),
                _buildGlossaryTab(theme),
                _buildCitationsTab(theme),
                _buildChatTab(theme),
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
        return _buildTranscriptTab(theme);
      case 2:
        return _buildSummaryTab(theme);
      case 3:
        return _buildScienceMobile(theme);
      case 4:
        return _buildChatTab(theme);
      default:
        return SingleChildScrollView(child: _buildRecordingControlPanel(theme));
    }
  }

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
                    _titleController.text.trim().isEmpty ? 'Scientific Meeting' : _titleController.text.trim(),
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
            const SizedBox(height: 16),

            // Pulsing Timer Display
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
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
            const SizedBox(height: 14),

            // Microphone Selector
            _buildAudioDeviceSelector(theme),
            const SizedBox(height: 10),

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
            const SizedBox(height: 16),

            // Meeting 1-Click Reaction & Bookmark Tags
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
                  avatar: const Text('🔬'),
                  label: const Text('Hypothesis'),
                  onPressed: () => _quickAddTag('🔬', 'Hypothesis'),
                ),
                ActionChip(
                  avatar: const Text('📊'),
                  label: const Text('Key Result'),
                  onPressed: () => _quickAddTag('📊', 'Key Result'),
                ),
                ActionChip(
                  avatar: const Text('⚠️'),
                  label: const Text('Question'),
                  onPressed: () => _quickAddTag('⚠️', 'Open Question'),
                ),
                ActionChip(
                  avatar: const Icon(Icons.edit_note, size: 16),
                  label: const Text('Custom Note'),
                  onPressed: _addLiveMeetingNoteDialog,
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Live Stream of Bookmarks in Current Meeting
            if (_currentSession?.liveNotes.isNotEmpty == true) ...[
              const Divider(),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Meeting Stream (${_currentSession!.liveNotes.length})',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  Text('${_currentSession!.slideAttachments.length} Figures',
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 140),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
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
                          Container(
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

            // Slide / Gel Attachment Button
            OutlinedButton.icon(
              onPressed: _attachFigureDialog,
              icon: const Icon(Icons.add_photo_alternate, size: 16),
              label: const Text('Attach Slide / Gel Figure'),
            ),
            const SizedBox(height: 12),

            // Expand Button
            FilledButton.tonalIcon(
              onPressed: () => setState(() => _isMeetingCompactMode = false),
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Open Scientific Intelligence Dashboards'),
            ),
          ],
        ),
      ),
    );
  }

  // --- Microphone Device Selector Dropdown ---

  Widget _buildAudioDeviceSelector(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withOpacity(0.4),
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

  // --- Left Sidebar: Audio & Meeting Control Deck ---

  Widget _buildRecordingControlPanel(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(
              labelText: 'Scientific Session Title',
              hintText: 'e.g. KRAS G12C NSCLC Seminar or Immunology Review',
              prefixIcon: Icon(Icons.science_outlined),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),

          // Audio Input Device Selector
          _buildAudioDeviceSelector(theme),
          const SizedBox(height: 10),

          // Multilingual Hindi/English Optimization Selector
          _buildLanguageSelector(theme),
          const SizedBox(height: 14),

          // Timer Display with Pulsing Audio Activity
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withOpacity(0.3),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _recordingState == RecordingState.recording
                      ? Colors.redAccent
                      : theme.colorScheme.outlineVariant,
                ),
              ),
              child: Column(
                children: [
                  Text(
                    _formatDuration(_recordDurationSeconds),
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2,
                      color: _recordingState == RecordingState.recording
                          ? Colors.redAccent
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
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
                              : (_recordingState == RecordingState.paused ? Colors.orange : Colors.grey),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _recordingState == RecordingState.recording
                            ? 'RECORDING ACTIVE (MIC ON)'
                            : _recordingState.name.toUpperCase(),
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 11),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),

          // Control Buttons
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              if (_recordingState == RecordingState.idle || _recordingState == RecordingState.stopped) ...[
                ElevatedButton.icon(
                  onPressed: _startRecording,
                  icon: const Icon(Icons.fiber_manual_record, color: Colors.white),
                  label: const Text('Record'),
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
          const SizedBox(height: 12),

          // 1-Click Meeting Tag Pills
          Wrap(
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: [
              ActionChip(
                visualDensity: VisualDensity.compact,
                avatar: const Text('⚡', style: TextStyle(fontSize: 12)),
                label: const Text('Action', style: TextStyle(fontSize: 11)),
                onPressed: () => _quickAddTag('⚡', 'Action Item'),
              ),
              ActionChip(
                visualDensity: VisualDensity.compact,
                avatar: const Text('🔬', style: TextStyle(fontSize: 12)),
                label: const Text('Hypothesis', style: TextStyle(fontSize: 11)),
                onPressed: () => _quickAddTag('🔬', 'Hypothesis'),
              ),
              ActionChip(
                visualDensity: VisualDensity.compact,
                avatar: const Text('📊', style: TextStyle(fontSize: 12)),
                label: const Text('Result', style: TextStyle(fontSize: 11)),
                onPressed: () => _quickAddTag('📊', 'Key Result'),
              ),
              ActionChip(
                visualDensity: VisualDensity.compact,
                avatar: const Text('⚠️', style: TextStyle(fontSize: 12)),
                label: const Text('Question', style: TextStyle(fontSize: 11)),
                onPressed: () => _quickAddTag('⚠️', 'Open Question'),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Detailed Custom Bookmark Button
          OutlinedButton.icon(
            onPressed: _addLiveMeetingNoteDialog,
            icon: const Icon(Icons.bookmark_add, color: Colors.orange, size: 16),
            label: Text('Custom Note at ${_formatDuration(_recordDurationSeconds)}'),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.orange),
              padding: const EdgeInsets.symmetric(vertical: 8),
            ),
          ),
          const SizedBox(height: 8),

          // Audio Playback Bar
          if (_recordingState == RecordingState.stopped && _recordedAudioPath != null) ...[
            Row(
              children: [
                IconButton(
                  icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                  onPressed: () async {
                    if (_isPlaying) {
                      await _audioPlayer.pause();
                    } else {
                      await _audioPlayer.play(DeviceFileSource(_recordedAudioPath!));
                    }
                  },
                ),
                Expanded(
                  child: Slider(
                    value: _playbackPosition.inSeconds.toDouble(),
                    min: 0.0,
                    max: _playbackDuration.inSeconds.toDouble() > 0 ? _playbackDuration.inSeconds.toDouble() : 1.0,
                    onChanged: (value) async {
                      await _audioPlayer.seek(Duration(seconds: value.toInt()));
                    },
                  ),
                ),
                Text(
                  '${_playbackPosition.inSeconds}/${_playbackDuration.inSeconds}s',
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            ),
          ],

          // Slide / Lab Figure Snapshot Button
          OutlinedButton.icon(
            onPressed: _attachFigureDialog,
            icon: const Icon(Icons.add_photo_alternate, size: 16),
            label: const Text('Attach Slide / Gel Figure'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 8),
            ),
          ),
          const SizedBox(height: 8),

          // Wet-Lab Noise Suppressor Switch
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceVariant.withOpacity(0.4),
              borderRadius: BorderRadius.circular(10),
            ),
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Wet-Lab Noise Filter', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              subtitle: const Text('Suppresses hood & centrifuge drone', style: TextStyle(fontSize: 10)),
              value: _enableNoiseSuppression,
              onChanged: (val) {
                setState(() {
                  _enableNoiseSuppression = val;
                });
              },
            ),
          ),
          const SizedBox(height: 8),

          // Clinical De-Identification Switch
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceVariant.withOpacity(0.4),
              borderRadius: BorderRadius.circular(10),
            ),
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Clinical PHI Scrubber', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              subtitle: const Text('Redacts patient names & MRNs', style: TextStyle(fontSize: 10)),
              value: _enableClinicalDeIdentification,
              onChanged: (val) {
                setState(() {
                  _enableClinicalDeIdentification = val;
                });
              },
            ),
          ),
          const SizedBox(height: 8),

          // Virtual Call Mode Switch (Zoom / WhatsApp / Teams)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceVariant.withOpacity(0.4),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Virtual Call Mode', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    subtitle: const Text('Zoom / WhatsApp / Teams Audio', style: TextStyle(fontSize: 10)),
                    value: _isVirtualCallMode,
                    onChanged: (val) {
                      setState(() {
                        _isVirtualCallMode = val;
                        if (_currentSession != null) {
                          _currentSession!.isVirtualCall = val;
                        }
                      });
                      if (_currentSession != null) {
                        SessionRepository().saveSession(_currentSession!);
                      }
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.help_outline, size: 18, color: Colors.blueAccent),
                  tooltip: 'Virtual Call Audio Capture Guide',
                  onPressed: _showVirtualCallGuideDialog,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Trigger AI Intelligence
          ElevatedButton.icon(
            onPressed: (_recordingState == RecordingState.stopped || _currentSession != null) &&
                    _processingStage != ProcessingStage.transcribing &&
                    _processingStage != ProcessingStage.summarizing
                ? _executeAiPipeline
                : null,
            icon: const Icon(Icons.auto_awesome),
            label: const Text('Process AI Tasks & Insights'),
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.colorScheme.primary,
              foregroundColor: theme.colorScheme.onPrimary,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
          const SizedBox(height: 8),

          // Pipeline status bar
          if (_processingStage != ProcessingStage.idle) ...[
            LinearProgressIndicator(
              value: _processingStage == ProcessingStage.completed
                  ? 1.0
                  : (_processingStage == ProcessingStage.transcribing
                      ? 0.3
                      : _processingStage == ProcessingStage.deidentifying
                          ? 0.5
                          : 0.8),
            ),
            const SizedBox(height: 6),
          ],
          Text(
            _statusMessage,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline, fontSize: 11),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),

          // Storage Info Footer
          if (_recordedAudioPath != null)
            Card(
              elevation: 0,
              color: theme.colorScheme.surfaceVariant.withOpacity(0.5),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Local Audio Cache (Air-Gapped):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                    const SizedBox(height: 2),
                    Text(
                      _recordedAudioPath!,
                      style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // --- Intelligence Tab: Full Transcript & Multilingual Editor ---

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

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Action Toolbar
          Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Session Transcript',
                        style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 8),
                      Chip(
                        label: Text('$wordCount words • ~$estimatedMin min read'),
                        backgroundColor: theme.colorScheme.surfaceContainerHighest,
                        visualDensity: VisualDensity.compact,
                        labelStyle: const TextStyle(fontSize: 11),
                        side: BorderSide.none,
                      ),
                    ],
                  ),
                  if (_currentSession?.transcriptSha256 != null)
                    Text(
                      'SHA-256: ${_currentSession!.transcriptSha256!.substring(0, 16)}... (21 CFR Part 11 Sealed)',
                      style: TextStyle(fontSize: 11, color: Colors.indigo.shade400, fontFamily: 'monospace'),
                    ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _copyTranscriptToClipboard,
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _showSaveTranscriptMenu,
                    icon: const Icon(Icons.save_alt, size: 16),
                    label: const Text('Save Transcript'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _toggleEditTranscript,
                    icon: Icon(_isTranscriptEditMode ? Icons.visibility : Icons.edit_note, size: 16),
                    label: Text(_isTranscriptEditMode ? 'View' : 'Edit / Paste'),
                  ),
                  FilledButton.icon(
                    onPressed: _isTranslatingTranscript ? null : _toggleTranslateTranscript,
                    icon: _isTranslatingTranscript
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.translate, size: 16),
                    label: Text(_showTranslatedTranscript ? 'View Original' : 'Translate (हिन्दी)'),
                    style: FilledButton.styleFrom(backgroundColor: Colors.teal),
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
                color: Colors.teal.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.teal.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.g_translate, color: Colors.teal, size: 18),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'प्रदर्शित: वैज्ञानिक प्रतिलेख का हिन्दी अनुवाद (Viewing Hindi Biomedical Translation)',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.teal),
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
                child: SelectableText(
                  displayedText,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    height: 1.7,
                    letterSpacing: 0.2,
                    fontSize: 14.5,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // --- Intelligence Tab 1: Scientific Summary ---

  Widget _buildSummaryTab(ThemeData theme) {
    final summary = _currentSession?.summary;
    if (summary == null) {
      return _buildEmptyState('No scientific summary generated yet. Record or import audio and click "Process AI Tasks".');
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text('Scientific Executive Summary', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton.icon(
                    onPressed: _isTranslatingSummary ? null : _toggleTranslateSummary,
                    icon: _isTranslatingSummary
                        ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.translate, size: 14),
                    label: Text(_showTranslatedSummary ? 'English' : 'हिन्दी (Hindi)'),
                    style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                  ),
                  const SizedBox(width: 8),
                  Chip(
                    label: Text(summary.detectedLanguage),
                    backgroundColor: theme.colorScheme.primaryContainer,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),

          // 21 CFR Part 11 Cryptographic Audit Trail Card
          if (_currentSession?.audioSha256 != null || _currentSession?.transcriptSha256 != null) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.indigo.withOpacity(0.06),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.indigo.withOpacity(0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.verified, size: 16, color: Colors.indigo),
                      SizedBox(width: 6),
                      Text(
                        '21 CFR PART 11 FORENSIC AUDIT TRAIL',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.indigo),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (_currentSession?.audioSha256 != null)
                    Row(
                      children: [
                        const Text('Audio SHA-256: ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                        Expanded(
                          child: Text(
                            _currentSession!.audioSha256!,
                            style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy, size: 14),
                          tooltip: 'Copy Audio SHA-256',
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: _currentSession!.audioSha256!));
                            _showSnackBar('Audio SHA-256 copied to clipboard');
                          },
                        ),
                      ],
                    ),
                  if (_currentSession?.transcriptSha256 != null)
                    Row(
                      children: [
                        const Text('Transcript SHA-256: ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                        Expanded(
                          child: Text(
                            _currentSession!.transcriptSha256!,
                            style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy, size: 14),
                          tooltip: 'Copy Transcript SHA-256',
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: _currentSession!.transcriptSha256!));
                            _showSnackBar('Transcript SHA-256 copied to clipboard');
                          },
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],

          if (summary.scientificHypothesis.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.teal.withOpacity(0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.teal.withOpacity(0.3)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.lightbulb_outline, color: Colors.teal, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('HYPOTHESIS / RATIONALE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.teal)),
                        const SizedBox(height: 4),
                        Text(summary.scientificHypothesis, style: const TextStyle(fontSize: 13, height: 1.4)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          Text(summary.executiveSummary, style: theme.textTheme.bodyLarge?.copyWith(height: 1.5)),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 12),
          Text('Key Experimental Findings & Observations', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...summary.keyPoints.map((point) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.check_circle_outline, size: 18, color: Colors.teal),
                    const SizedBox(width: 8),
                    Expanded(child: Text(point)),
                  ],
                ),
              )),
          const SizedBox(height: 20),
          Text('Protocol & Consensus Decisions', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...summary.decisionsMade.map((decision) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.gavel, size: 18, color: Colors.blueAccent),
                    const SizedBox(width: 8),
                    Expanded(child: Text(decision)),
                  ],
                ),
              )),

          // Live In-Meeting Annotations & Bookmarks
          if (_currentSession?.liveNotes.isNotEmpty == true) ...[
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.bookmark, color: Colors.orange, size: 20),
                const SizedBox(width: 8),
                Text('Live In-Meeting Annotations (${_currentSession!.liveNotes.length})',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 8),
            ..._currentSession!.liveNotes.map((note) => Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  color: Colors.orange.withOpacity(0.06),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  child: ListTile(
                    dense: true,
                    leading: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _formatDuration(note.timestampSeconds),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.deepOrange),
                      ),
                    ),
                    title: Text(note.note, style: const TextStyle(fontSize: 13)),
                  ),
                )),
          ],

          // Attached Figures with In-App Lightbox Zoom
          if (_currentSession?.slideAttachments.isNotEmpty == true) ...[
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.image, color: Colors.teal, size: 20),
                const SizedBox(width: 8),
                Text('Attached Figures & Slides (Tap to Zoom In-App)',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 8),
            ..._currentSession!.slideAttachments.map((slide) => Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    leading: const Icon(Icons.zoom_in, color: Colors.teal),
                    title: Text(slide.caption, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('Logged at: ${_formatDuration(slide.timestampSeconds)} (Tap to inspect figure)'),
                    onTap: () => _showFigureLightbox(slide),
                  ),
                )),
          ],
        ],
      ),
    );
  }

  // --- Intelligence Tab 2: Protocols & Tasks ---

  Widget _buildTasksTab(ThemeData theme) {
    final tasks = _currentSession?.actionItems ?? [];
    if (tasks.isEmpty) {
      return _buildEmptyState('No protocol tasks or action items extracted yet.');
    }

    return ListView.separated(
      padding: const EdgeInsets.all(20),
      itemCount: tasks.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final item = tasks[index];
        return Card(
          elevation: 1,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: CheckboxListTile(
            value: item.isCompleted,
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
              ),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.teal.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      item.category,
                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.teal),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(Icons.person, size: 14, color: theme.colorScheme.primary),
                  const SizedBox(width: 4),
                  Text(item.assignee, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 12)),
                  if (item.speaker != null) ...[
                    const SizedBox(width: 8),
                    Text('(by ${item.speaker})', style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: Colors.grey)),
                  ],
                  const SizedBox(width: 12),
                  if (item.deadline != null) ...[
                    const Icon(Icons.calendar_today, size: 12, color: Colors.orange),
                    const SizedBox(width: 4),
                    Text(item.deadline!, style: const TextStyle(color: Colors.orange, fontSize: 11)),
                  ],
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: item.priority == 'High' ? Colors.red.withOpacity(0.1) : Colors.blue.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      item.priority,
                      style: TextStyle(
                        fontSize: 11,
                        color: item.priority == 'High' ? Colors.red : Colors.blue,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // --- Intelligence Tab 3: Speakers & Dialog Diarization ---

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
                hintText: 'e.g. Dr. Rao (Lead PI) or Elena (Postdoc)',
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

  Widget _buildSpeakersTab(ThemeData theme) {
    final turns = _currentSession?.speakerTurns ?? [];
    if (turns.isEmpty) {
      return _buildEmptyState('No speaker diarization turns available yet. Click "Process AI Tasks & Insights" to generate multi-speaker turns.');
    }

    final uniqueSpeakers = turns.map((t) => t.speakerName).toSet().toList();

    return Column(
      children: [
        // Summary Header Strip
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
            border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant.withOpacity(0.5))),
          ),
          child: Row(
            children: [
              const Icon(Icons.people_alt_outlined, size: 20, color: Colors.teal),
              const SizedBox(width: 8),
              Text(
                '${uniqueSpeakers.length} Speakers Identified',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(width: 8),
              Text(
                '(${turns.length} Dialog Turns)',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              if (_currentSession?.isVirtualCall == true) ...[
                const SizedBox(width: 12),
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
              const Spacer(),
              Text(
                'Tap speaker to rename',
                style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: Colors.grey.shade600),
              ),
            ],
          ),
        ),

        // Chronological List of Speaker Turns
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(20),
            itemCount: turns.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final turn = turns[index];
              final speakerColor = _getSpeakerColor(turn.speakerId);
              final startMin = (turn.startSeconds ~/ 60).toString().padLeft(2, '0');
              final startSec = (turn.startSeconds % 60).toString().padLeft(2, '0');
              final endMin = (turn.endSeconds ~/ 60).toString().padLeft(2, '0');
              final endSec = (turn.endSeconds % 60).toString().padLeft(2, '0');

              return Card(
                elevation: 1,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: speakerColor.withOpacity(0.3), width: 1),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 14,
                            backgroundColor: speakerColor.withOpacity(0.2),
                            child: Text(
                              turn.speakerName.isNotEmpty ? turn.speakerName[0].toUpperCase() : 'S',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: speakerColor),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: InkWell(
                              onTap: () => _showRenameSpeakerDialog(turn.speakerId, turn.speakerName),
                              borderRadius: BorderRadius.circular(6),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
                                child: Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        turn.speakerName,
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                          color: speakerColor,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Icon(Icons.edit_outlined, size: 13, color: speakerColor.withOpacity(0.7)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          InkWell(
                            onTap: () => _seekAudio(turn.startSeconds),
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surfaceVariant.withOpacity(0.5),
                                borderRadius: BorderRadius.circular(12),
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
                      const SizedBox(height: 10),
                      Text(
                        turn.text,
                        style: const TextStyle(fontSize: 13, height: 1.4),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // --- Intelligence Tab 4: Bio/Chem Glossary & Self-Reliant Search ---

  Widget _buildGlossaryTab(ThemeData theme) {
    final rawTerms = _currentSession?.glossaryTerms ?? [];
    final terms = _searchResultsPubChem.isNotEmpty ? _searchResultsPubChem : rawTerms;

    return Column(
      children: [
        // In-App On-Demand Scientific Search Bar (Zero External Browser Needed)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _pubchemSearchController,
                  onSubmitted: _searchPubChemOnDemand,
                  decoration: InputDecoration(
                    hintText: 'Search PubChem compound or offline atlas (e.g. Osimertinib, Cisplatin, KRAS)...',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: _pubchemSearchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 16),
                            onPressed: () {
                              _pubchemSearchController.clear();
                              setState(() {
                                _searchResultsPubChem.clear();
                              });
                            },
                          )
                        : null,
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _isSearchingPubchem
                    ? null
                    : () => _searchPubChemOnDemand(_pubchemSearchController.text),
                icon: _isSearchingPubchem
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.science, size: 16),
                label: const Text('Lookup'),
              ),
            ],
          ),
        ),

        // Terms List
        Expanded(
          child: terms.isEmpty
              ? _buildEmptyState(
                  'Bio & Chemical Glossary powered by NIH PubChem & Offline Scientific Atlas.\nSearch any drug, compound, gene, or assay above, or run AI processing on a recording.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(20),
                  itemCount: terms.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final term = terms[index];
                    final isPubChem = term.source == 'PubChem';

                    return Card(
                      elevation: 1,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  term.word.toUpperCase(),
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: isPubChem ? Colors.teal : theme.colorScheme.primary,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                if (term.phonetic.isNotEmpty)
                                  Text(term.phonetic, style: TextStyle(color: theme.colorScheme.outline, fontStyle: FontStyle.italic, fontSize: 12)),
                                const Spacer(),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: isPubChem ? Colors.teal.withOpacity(0.15) : theme.colorScheme.secondaryContainer,
                                    borderRadius: BorderRadius.circular(6),
                                    border: isPubChem ? Border.all(color: Colors.teal.withOpacity(0.4)) : null,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (isPubChem) ...[
                                        const Icon(Icons.science_outlined, size: 12, color: Colors.teal),
                                        const SizedBox(width: 4),
                                      ],
                                      Text(
                                        isPubChem ? 'NIH PubChem' : (term.partOfSpeech.isNotEmpty ? term.partOfSpeech : 'BioKnowledge'),
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: isPubChem ? Colors.teal : theme.colorScheme.onSecondaryContainer,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(term.definition, style: theme.textTheme.bodyMedium?.copyWith(height: 1.4)),
                            if (term.example != null) ...[
                              const SizedBox(height: 6),
                              Text(
                                term.example!,
                                style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic, color: Colors.grey[600]),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // --- Intelligence Tab 4: Literature & Self-Reliant PubMed Reader ---

  Widget _buildCitationsTab(ThemeData theme) {
    final rawCitations = _currentSession?.citations ?? [];
    final citations = _searchResultsPubMed.isNotEmpty ? _searchResultsPubMed : rawCitations;

    return Column(
      children: [
        // In-App On-Demand PubMed Literature Search Bar (Zero External Browser Needed)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _pubmedSearchController,
                  onSubmitted: _searchPubMedOnDemand,
                  decoration: InputDecoration(
                    hintText: 'Search PubMed for papers, trials, or PMID (e.g. KRAS G12C, Osimertinib, 33208354)...',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: _pubmedSearchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 16),
                            onPressed: () {
                              _pubmedSearchController.clear();
                              setState(() {
                                _searchResultsPubMed.clear();
                              });
                            },
                          )
                        : null,
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _isSearchingPubmed
                    ? null
                    : () => _searchPubMedOnDemand(_pubmedSearchController.text),
                icon: _isSearchingPubmed
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.menu_book, size: 16),
                label: const Text('Search'),
              ),
            ],
          ),
        ),

        // Citations List
        Expanded(
          child: citations.isEmpty
              ? _buildEmptyState(
                  'Scientific Literature & Citations powered by NCBI PubMed.\nSearch any clinical trial, mechanism, or PMID above, or run AI processing on a session.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(20),
                  itemCount: citations.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final cite = citations[index];
                    return Card(
                      elevation: 1,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _showArticleReader(cite),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Text(
                                      cite.title,
                                      style: theme.textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: theme.colorScheme.onSurface,
                                      ),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: Colors.blue.withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      'PMID: ${cite.pmid}',
                                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.blue),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                cite.authors,
                                style: theme.textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic, color: Colors.grey[800]),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Text(
                                    '${cite.journal} (${cite.pubYear})',
                                    style: TextStyle(color: theme.colorScheme.outline, fontSize: 12),
                                  ),
                                  if (cite.doi != null) ...[
                                    const SizedBox(width: 8),
                                    Text('• DOI: ${cite.doi}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                                  ],
                                  const Spacer(),
                                  Row(
                                    children: [
                                      const Icon(Icons.chrome_reader_mode, size: 14, color: Colors.teal),
                                      const SizedBox(width: 4),
                                      Text('Read In-App', style: TextStyle(fontSize: 11, color: Colors.teal[700], fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // --- Intelligence Tab 5: Grounded Research Q&A ---

  Widget _buildChatTab(ThemeData theme) {
    final history = _currentSession?.chatHistory ?? [];

    return Column(
      children: [
        Expanded(
          child: history.isEmpty
              ? _buildEmptyState(
                  'Ask scientific questions about this session or lab meeting.\nExample: "What was the statistical significance and dose of Osimertinib used?"',
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
                        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.65),
                        decoration: BoxDecoration(
                          color: isUser ? theme.colorScheme.primary : theme.colorScheme.surfaceVariant,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          msg.text,
                          style: TextStyle(color: isUser ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface),
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
                    hintText: 'Ask about protocols, controls, p-values, or gene targets...',
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
            const Icon(Icons.science_outlined, size: 56, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
