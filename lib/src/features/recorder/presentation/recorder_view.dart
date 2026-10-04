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
import '../../../core/widgets/labscribe_ui.dart';
import '../../settings/presentation/settings_view.dart';
import '../../export/services/export_service.dart';
import '../../history/presentation/history_view.dart';
import '../../../models/meeting_session.dart';
import '../../intelligence/services/meeting_intelligence_service.dart';
import '../../public_apis/services/public_api_service.dart';

/// Main interactive UI managing session recording, audio device selection,
/// meeting-compatible compact mode, clinical de-identification, in-app literature/figure reading,
/// SHA-256 reference hashes, and responsive intelligence dashboards.
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
  int _mobileNotesTab = 0; // 0 Summary, 1 Transcript
  int _mobileTasksTab = 0; // 0 Protocols, 1 Speakers
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
          _statusMessage = 'Recording...';
          
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
        _statusMessage = 'Recording saved on-device with a SHA-256 reference. Ready for analysis.';
        
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
          _statusMessage = 'Imported: $fileName (SHA-256 recorded). Ready for analysis.';
        });

        await SessionRepository().saveSession(newSession);
        _showSnackBar('Imported $fileName with a SHA-256 reference.');
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

  String _formatDuration(int seconds) => formatHMS(seconds);

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

  // --- In-app article and figure dialogs ---

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

  // --- AI processing with SHA-256 reference computation ---

  Future<void> _executeAiPipeline() async {
    if (_recordedAudioPath == null && _currentSession?.audioPath == null) {
      _showSnackBar('No audio file found. Please record or import a session first.');
      return;
    }

    try {
      setState(() {
        _processingStage = ProcessingStage.transcribing;
        _statusMessage = 'Step 1: Transcribing audio...';
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
          _statusMessage = 'Step 2: Applying optional pattern-based redaction...';
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
        _statusMessage = 'Step 3: Synthesizing summary, tasks, and references...';
      });

      // 3. Multi-source scientific intelligence synthesis
      final intelligence = await widget.intelligenceService.processSessionIntelligence(
        transcript: transcript,
        sessionTitle: _currentSession?.title ?? 'Scientific Session',
      );

      // 4. Compute transcript SHA-256 reference
      final transcriptHash = CryptoUtils.sha256String(transcript);

      setState(() {
        _processingStage = ProcessingStage.completed;
        _statusMessage = 'Analysis complete.';
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

      _showSnackBar('Analysis complete. References resolved where available.');
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
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        _currentSession = MeetingSession(
          id: timestamp.toString(),
          title: _titleController.text.trim().isEmpty ? 'Scientific Analysis' : _titleController.text.trim(),
          createdAt: DateTime.now(),
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
        _statusMessage = 'Analysis complete.';
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
      _showSnackBar('Analysis complete from text.');
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
              subtitle: const Text('Formatted lab record with SHA-256 references'),
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
    _showSnackBar('Transcript updated and hash refreshed.');
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
    return LabCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: theme.colorScheme.primary.withValues(alpha: 0.12),
            ),
            child: Icon(Icons.language, size: 17, color: theme.colorScheme.primary),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Language / भाषा', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
                Text('Whisper & AI tuning', style: TextStyle(color: Colors.grey, fontSize: 10.5)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: DropdownButton<String>(
              value: _selectedLanguage,
              underline: const SizedBox(),
              isDense: true,
              borderRadius: BorderRadius.circular(14),
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: theme.colorScheme.onSurface),
              items: const [
                DropdownMenuItem(value: 'auto', child: Text('Auto')),
                DropdownMenuItem(value: 'en', child: Text('English')),
                DropdownMenuItem(value: 'hi', child: Text('हिन्दी')),
                DropdownMenuItem(value: 'hinglish', child: Text('Hinglish')),
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
          ),
        ],
      ),
    );
  }

  Widget _buildScienceMobile(ThemeData theme) {
    return Column(
      children: [
        _segmentedHeader(
          theme,
          ['PubChem (${_currentSession?.glossaryTerms.length ?? 0})', 'PubMed (${_currentSession?.citations.length ?? 0})'],
          [Icons.medication_liquid_outlined, Icons.library_books_outlined],
          _scienceSubTabIndex,
          (v) => setState(() => _scienceSubTabIndex = v),
        ),
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

  int get _pipelineStage {
    switch (_processingStage) {
      case ProcessingStage.transcribing:
        return 1;
      case ProcessingStage.deidentifying:
      case ProcessingStage.summarizing:
      case ProcessingStage.extractingTasks:
      case ProcessingStage.buildingGlossary:
      case ProcessingStage.resolvingCitations:
        return 2;
      case ProcessingStage.completed:
        return 4;
      case ProcessingStage.error:
        return 2;
      case ProcessingStage.idle:
        return _currentSession?.summary != null ? 4 : 0;
    }
  }

  void _syncTab(int index) {
    if (_tabController.index != index) {
      _tabController.animateTo(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = MediaQuery.of(context).size.width;
    final isDesktop = width >= 900;
    final isCompactAction = width < 620;

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
                style: FilledButton.styleFrom(backgroundColor: Color(0xFFD92D20)),
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
              const BrandMark(size: 34),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _isMeetingCompactMode ? 'Meeting Deck' : 'LabScribe AI',
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (!isCompactAction)
                      Text(
                        _titleController.text.trim().isEmpty
                            ? 'Translational research companion'
                            : _titleController.text.trim(),
                        style: TextStyle(
                          fontSize: 11.5,
                          color: theme.colorScheme.outline,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            if (widget.intelligenceService.isDemoMode && !isCompactAction)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Tooltip(
                  message: 'Demo mode: built-in responses without configured endpoints.',
                  child: StatusPill(
                    icon: Icons.bolt,
                    label: 'Demo mode',
                    color: theme.colorScheme.tertiary,
                  ),
                ),
              ),
            if (_currentSession?.isDeIdentified == true && !isCompactAction)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: StatusPill(
                  icon: Icons.shield,
                  label: 'Redaction ${_redactedTokensCount > 0 ? _redactedTokensCount : ""}'.trim(),
                  color: theme.colorScheme.primary,
                ),
              ),
            IconButton(
              icon: Icon(_isMeetingCompactMode ? Icons.open_in_full : Icons.picture_in_picture_alt),
              tooltip: _isMeetingCompactMode ? 'Expand to Full Dashboards' : 'Compact Meeting Mode',
              onPressed: () {
                setState(() {
                  _isMeetingCompactMode = !_isMeetingCompactMode;
                });
              },
            ),
            if (!isCompactAction) ...[
              IconButton(
                icon: const Icon(Icons.auto_stories_outlined),
                tooltip: 'Notebook Preview',
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
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Settings & Model Config',
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const SettingsView()),
                  );
                  widget.intelligenceService.updateConfig(ConfigService().getAiConfig());
                },
              ),
            ],
            PopupMenuButton<String>(
              icon: const Icon(Icons.ios_share),
              tooltip: 'Export Research Notes & Citations',
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              onSelected: (value) async {
                if (value == 'preview') {
                  _showMarkdownPreviewer();
                  return;
                }
                if (value == 'history') {
                  final selectedSession = await Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const HistoryView()),
                  );
                  if (selectedSession != null && selectedSession is MeetingSession) {
                    loadSession(selectedSession);
                  }
                  return;
                }
                if (value == 'settings') {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const SettingsView()),
                  );
                  widget.intelligenceService.updateConfig(ConfigService().getAiConfig());
                  return;
                }
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
              itemBuilder: (context) => [
                if (isCompactAction)
                  const PopupMenuItem(
                    value: 'preview',
                    child: Row(
                      children: [
                        Icon(Icons.auto_stories_outlined, size: 18),
                        SizedBox(width: 8),
                        Text('Notebook Preview'),
                      ],
                    ),
                  ),
                if (isCompactAction)
                  const PopupMenuItem(
                    value: 'history',
                    child: Row(
                      children: [
                        Icon(Icons.history, size: 18),
                        SizedBox(width: 8),
                        Text('Session History'),
                      ],
                    ),
                  ),
                if (isCompactAction)
                  const PopupMenuItem(
                    value: 'settings',
                    child: Row(
                      children: [
                        Icon(Icons.settings_outlined, size: 18),
                        SizedBox(width: 8),
                        Text('Settings'),
                      ],
                    ),
                  ),
                const PopupMenuItem(
                  value: 'markdown',
                  child: Row(
                    children: [
                      Icon(Icons.description_outlined, size: 18, color: Color(0xFF0A7C6B)),
                      SizedBox(width: 8),
                      Text('Lab Notebook (.md)'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'eln',
                  child: Row(
                    children: [
                      Icon(Icons.integration_instructions, size: 18, color: Color(0xFF3B5BFF)),
                      SizedBox(width: 8),
                      Text('Benchling ELN (.json)'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'bibtex',
                  child: Row(
                    children: [
                      Icon(Icons.format_quote, size: 18, color: Colors.blue),
                      SizedBox(width: 8),
                      Text('BibTeX (.bib)'),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(width: 6),
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
                  NavigationDestination(icon: Icon(Icons.mic_outlined), selectedIcon: Icon(Icons.mic), label: 'Record'),
                  NavigationDestination(icon: Icon(Icons.summarize_outlined), selectedIcon: Icon(Icons.summarize), label: 'Notes'),
                  NavigationDestination(icon: Icon(Icons.fact_check_outlined), selectedIcon: Icon(Icons.fact_check), label: 'Tasks'),
                  NavigationDestination(icon: Icon(Icons.science_outlined), selectedIcon: Icon(Icons.science), label: 'Library'),
                  NavigationDestination(icon: Icon(Icons.forum_outlined), selectedIcon: Icon(Icons.forum), label: 'Q&A'),
                ],
              )
            : null,
      ),
    );
  }

  Widget _railDestination(ThemeData theme, int tabIndex, IconData icon, String label) {
    final selected = _tabController.index == tabIndex;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => setState(() => _tabController.animateTo(tabIndex)),
        child: Container(
          width: 68,
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: selected ? theme.colorScheme.primaryContainer.withValues(alpha: 0.6) : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: selected
                ? Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.3))
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: selected ? theme.colorScheme.primary : theme.colorScheme.outline),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: selected ? theme.colorScheme.onSurface : theme.colorScheme.outline,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopRail(ThemeData theme) {
    return Container(
      width: 84,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(right: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6))),
      ),
      child: AnimatedBuilder(
        animation: _tabController,
        builder: (context, _) => SingleChildScrollView(
          child: Column(
            children: [
              _railDestination(theme, 0, Icons.summarize_outlined, 'Summary'),
              _railDestination(theme, 1, Icons.description_outlined, 'Transcript'),
              _railDestination(theme, 2, Icons.fact_check_outlined, 'Protocols'),
              _railDestination(theme, 3, Icons.record_voice_over_outlined, 'Speakers'),
              _railDestination(theme, 4, Icons.medication_liquid_outlined, 'Compounds'),
              _railDestination(theme, 5, Icons.library_books_outlined, 'Papers'),
              _railDestination(theme, 6, Icons.forum_outlined, 'Q&A'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResponsiveBody(BuildContext context, ThemeData theme, bool isDesktop) {
    if (_isMeetingCompactMode) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: _buildCompactMeetingDeck(theme),
          ),
        ),
      );
    }

    if (isDesktop) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildDesktopRail(theme),
          Container(
            width: 372,
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(
                right: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6)),
              ),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: _buildRecordingControlPanel(theme),
            ),
          ),
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
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: _buildRecordingControlPanel(theme),
        );
      case 1:
        return _buildMobileNotes(theme);
      case 2:
        return _buildMobileTasks(theme);
      case 3:
        return _buildScienceMobile(theme);
      case 4:
        return _buildChatTab(theme);
      default:
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: _buildRecordingControlPanel(theme),
        );
    }
  }

  Widget _segmentedHeader(ThemeData theme, List<String> labels, List<IconData> icons, int selected, ValueChanged<int> onSelect) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6))),
      ),
      child: SegmentedButton<int>(
        segments: List.generate(
          labels.length,
          (i) => ButtonSegment(
            value: i,
            icon: Icon(icons[i], size: 15),
            label: Text(labels[i], style: const TextStyle(fontSize: 12)),
          ),
        ),
        selected: {selected},
        onSelectionChanged: (s) => onSelect(s.first),
        showSelectedIcon: false,
        style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
      ),
    );
  }

  Widget _buildMobileNotes(ThemeData theme) {
    return Column(
      children: [
        _segmentedHeader(
          theme,
          ['Summary', 'Transcript'],
          [Icons.summarize_outlined, Icons.description_outlined],
          _mobileNotesTab,
          (v) {
            setState(() => _mobileNotesTab = v);
            _syncTab(v == 0 ? 0 : 1);
          },
        ),
        Expanded(child: _mobileNotesTab == 0 ? _buildSummaryTab(theme) : _buildTranscriptTab(theme)),
      ],
    );
  }

  Widget _buildMobileTasks(ThemeData theme) {
    final protoCount = _currentSession?.actionItems.length ?? 0;
    final spkCount = _currentSession?.speakerTurns.length ?? 0;
    return Column(
      children: [
        _segmentedHeader(
          theme,
          ['Protocols ($protoCount)', 'Speakers ($spkCount)'],
          [Icons.fact_check_outlined, Icons.record_voice_over_outlined],
          _mobileTasksTab,
          (v) {
            setState(() => _mobileTasksTab = v);
            _syncTab(v == 0 ? 2 : 3);
          },
        ),
        Expanded(child: _mobileTasksTab == 0 ? _buildTasksTab(theme) : _buildSpeakersTab(theme)),
      ],
    );
  }

  // --- Meeting Compact Deck Mode ---

  Widget _buildCompactMeetingDeck(ThemeData theme) {
    return LabCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const BrandMark(size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _titleController.text.trim().isEmpty ? 'Scientific Meeting' : _titleController.text.trim(),
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const Text('Compact dock · stays beside Zoom / Meet', style: TextStyle(fontSize: 11, color: Colors.grey)),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.open_in_full, size: 18),
                tooltip: 'Expand Full Dashboards',
                onPressed: () => setState(() => _isMeetingCompactMode = false),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _timerHero(theme, large: true),
          const SizedBox(height: 12),
          _buildAudioDeviceSelector(theme),
          const SizedBox(height: 8),
          _buildLanguageSelector(theme),
          const SizedBox(height: 12),
          _recordActions(theme),
          const SizedBox(height: 14),
          _quickTags(theme, dense: true),
          const SizedBox(height: 12),
          if (_currentSession?.liveNotes.isNotEmpty == true) ...[
            SectionLabel('Live stream · ${_currentSession!.liveNotes.length}', icon: Icons.bolt_outlined),
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(maxHeight: 132),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _currentSession!.liveNotes.length,
                itemBuilder: (ctx, idx) {
                  final n = _currentSession!.liveNotes[idx];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.tertiary.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Text(
                            formatMS(n.timestampSeconds),
                            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 10.5, color: theme.colorScheme.tertiary, fontFeatures: const [FontFeature.tabularFigures()]),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(n.note, style: const TextStyle(fontSize: 12.5), overflow: TextOverflow.ellipsis)),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
          ],
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _attachFigureDialog,
                  icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
                  label: const Text('Slide / Gel'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () => setState(() => _isMeetingCompactMode = false),
                  icon: const Icon(Icons.auto_awesome, size: 16),
                  label: const Text('Dashboards'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // --- Microphone Device Selector Dropdown ---

  Widget _buildAudioDeviceSelector(ThemeData theme) {
    return LabCard(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: theme.colorScheme.primary.withValues(alpha: 0.12),
            ),
            child: Icon(Icons.mic_external_on, size: 17, color: theme.colorScheme.primary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _audioInputDevices.isEmpty
                ? const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Default System Microphone', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
                      Text('On-device local input', style: TextStyle(fontSize: 10.5, color: Colors.grey)),
                    ],
                  )
                : DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _selectedDeviceId,
                      borderRadius: BorderRadius.circular(14),
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface),
                      items: _audioInputDevices.map((dev) {
                        return DropdownMenuItem<String>(
                          value: dev.id,
                          child: Text(
                            dev.label.isNotEmpty ? dev.label : 'Microphone (${dev.id})',
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
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _timerHero(ThemeData theme, {bool large = false}) {
    final isRec = _recordingState == RecordingState.recording;
    final isPaused = _recordingState == RecordingState.paused;
    final dot = isRec
        ? const Color(0xFFD92D20)
        : (isPaused ? Colors.orange : Colors.grey);
    final status = isRec
        ? 'RECORDING'
        : _recordingState.name.toUpperCase();
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 20, vertical: large ? 18 : 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.primaryContainer.withValues(alpha: 0.55),
            theme.colorScheme.secondaryContainer.withValues(alpha: 0.45),
          ],
        ),
        border: Border.all(
          color: isRec ? const Color(0xFFD92D20).withValues(alpha: 0.6) : theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
          width: 1.2,
        ),
      ),
      child: Column(
        children: [
          Text(
            formatHMS(_recordDurationSeconds),
            style: TextStyle(
              fontSize: large ? 38 : 30,
              fontWeight: FontWeight.w800,
              letterSpacing: 2.5,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: isRec ? const Color(0xFFD92D20) : theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
              ),
              const SizedBox(width: 8),
              Text(
                status,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 10.5, letterSpacing: 0.8),
              ),
            ],
          ),
          if (_currentSession != null && (_currentSession!.liveNotes.isNotEmpty || _currentSession!.slideAttachments.isNotEmpty)) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                StatusPill(icon: Icons.bookmark, label: '${_currentSession!.liveNotes.length} notes', color: theme.colorScheme.tertiary),
                const SizedBox(width: 8),
                StatusPill(icon: Icons.image_outlined, label: '${_currentSession!.slideAttachments.length} figs', color: theme.colorScheme.secondary),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _recordActions(ThemeData theme, {bool compact = false}) {
    final idle = _recordingState == RecordingState.idle || _recordingState == RecordingState.stopped;
    if (idle) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: _startRecording,
            icon: const Icon(Icons.fiber_manual_record, size: 16),
            label: const Text('Start Recording'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFD92D20),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 15),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _importAudioFileDialog(),
                  icon: const Icon(Icons.file_upload_outlined, size: 15),
                  label: const Text('Import'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _showPasteTranscriptDialog,
                  icon: const Icon(Icons.paste_outlined, size: 15),
                  label: const Text('Paste'),
                ),
              ),
            ],
          ),
        ],
      );
    }
    if (_recordingState == RecordingState.recording) {
      return Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _pauseRecording,
              icon: const Icon(Icons.pause, size: 16),
              label: const Text('Pause'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.icon(
              onPressed: _stopRecording,
              icon: const Icon(Icons.stop, size: 16),
              label: const Text('Stop'),
              style: FilledButton.styleFrom(backgroundColor: theme.colorScheme.onSurface),
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: _resumeRecording,
            icon: const Icon(Icons.play_arrow, size: 16),
            label: const Text('Resume'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _stopRecording,
            icon: const Icon(Icons.stop, size: 16),
            label: const Text('Stop'),
          ),
        ),
      ],
    );
  }

  Widget _quickTags(ThemeData theme, {bool dense = false}) {
    Widget tag(IconData icon, String label, String emoji, String tagLabel, Color color) {
      return InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _quickAddTag(emoji, tagLabel),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 10, vertical: dense ? 7 : 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withValues(alpha: 0.28)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 5),
              Text(label, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(
          'Quick tags',
          icon: Icons.bolt_outlined,
          trailing: TextButton(
            onPressed: _addLiveMeetingNoteDialog,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('Custom note', style: TextStyle(fontSize: 11.5)),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: [
            tag(Icons.flash_on_outlined, 'Action', '⚡', 'Action Item', theme.colorScheme.tertiary),
            tag(Icons.lightbulb_outline, 'Hypothesis', '🔬', 'Hypothesis', theme.colorScheme.primary),
            tag(Icons.query_stats_outlined, 'Result', '📊', 'Key Result', theme.colorScheme.secondary),
            tag(Icons.help_outline, 'Question', '⚠️', 'Open Question', theme.colorScheme.error),
          ],
        ),
      ],
    );
  }

  // --- Left Sidebar: Audio & Meeting Control Deck ---

  Widget _buildRecordingControlPanel(ThemeData theme) {
    final canProcess = (_recordingState == RecordingState.stopped || _currentSession != null) &&
        _processingStage != ProcessingStage.transcribing &&
        _processingStage != ProcessingStage.summarizing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Session', icon: null),
        const SizedBox(height: 8),
        TextField(
          controller: _titleController,
          decoration: const InputDecoration(
            labelText: 'Session title',
            hintText: 'e.g. KRAS G12C NSCLC seminar',
            prefixIcon: Icon(Icons.science_outlined, size: 18),
          ),
        ),
        const SizedBox(height: 10),
        _buildAudioDeviceSelector(theme),
        const SizedBox(height: 8),
        _buildLanguageSelector(theme),
        const SizedBox(height: 12),
        _timerHero(theme),
        const SizedBox(height: 12),
        _recordActions(theme),
        const SizedBox(height: 12),
        if (_recordingState == RecordingState.stopped && _recordedAudioPath != null)
          LabCard(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: theme.colorScheme.primary.withValues(alpha: 0.14)),
                  child: IconButton(
                    icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow, size: 18),
                    onPressed: () async {
                      if (_isPlaying) {
                        await _audioPlayer.pause();
                      } else {
                        await _audioPlayer.play(DeviceFileSource(_recordedAudioPath!));
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                        ),
                        child: Slider(
                          value: _playbackPosition.inSeconds.toDouble().clamp(0.0, (_playbackDuration.inSeconds.toDouble() > 0 ? _playbackDuration.inSeconds.toDouble() : 1.0)),
                          min: 0.0,
                          max: _playbackDuration.inSeconds.toDouble() > 0 ? _playbackDuration.inSeconds.toDouble() : 1.0,
                          onChanged: (value) async {
                            await _audioPlayer.seek(Duration(seconds: value.toInt()));
                          },
                        ),
                      ),
                      Text('${formatMS(_playbackPosition.inSeconds)} / ${formatMS(_playbackDuration.inSeconds)} · local playback', style: TextStyle(fontSize: 10.5, color: theme.colorScheme.outline)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (_recordingState == RecordingState.stopped && _recordedAudioPath != null) const SizedBox(height: 12),
        LabCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _quickTags(theme, dense: true),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _addLiveMeetingNoteDialog,
                  icon: const Icon(Icons.bookmark_add_outlined, size: 15),
                  label: Text('Note at ${formatHMS(_recordDurationSeconds)}'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _attachFigureDialog,
                  icon: const Icon(Icons.add_photo_alternate_outlined, size: 15),
                  label: const Text('Attach slide / gel figure'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        LabCard(
          child: Column(
            children: [
              const SectionLabel('Capture lab', icon: null),
              SettingRow(
                icon: Icons.graphic_eq,
                iconColor: theme.colorScheme.primary,
                title: 'Wet-lab noise filter',
                subtitle: 'Hood · centrifuge · freezer hum',
                trailing: Switch(value: _enableNoiseSuppression, onChanged: (v) => setState(() => _enableNoiseSuppression = v)),
              ),
              const Divider(height: 8),
              SettingRow(
                icon: Icons.shield_outlined,
                iconColor: theme.colorScheme.tertiary,
                title: 'PHI scrubber',
                subtitle: 'Redaction Safe Harbor on-device',
                trailing: Switch(value: _enableClinicalDeIdentification, onChanged: (v) => setState(() => _enableClinicalDeIdentification = v)),
              ),
              const Divider(height: 8),
              SettingRow(
                icon: Icons.video_call_outlined,
                iconColor: theme.colorScheme.secondary,
                title: 'Virtual call mode',
                subtitle: 'Zoom · WhatsApp · Teams',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(icon: const Icon(Icons.help_outline, size: 17), tooltip: 'Capture guide', onPressed: _showVirtualCallGuideDialog, visualDensity: VisualDensity.compact),
                    Switch(
                      value: _isVirtualCallMode,
                      onChanged: (val) {
                        setState(() {
                          _isVirtualCallMode = val;
                          if (_currentSession != null) _currentSession!.isVirtualCall = val;
                        });
                        if (_currentSession != null) SessionRepository().saveSession(_currentSession!);
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: canProcess ? _executeAiPipeline : null,
          icon: const Icon(Icons.auto_awesome, size: 16),
          label: const Text('Process AI insights'),
          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 15)),
        ),
        const SizedBox(height: 10),
        LabCard(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PipelineSteps(activeStage: _pipelineStage, hasError: _processingStage == ProcessingStage.error),
              const SizedBox(height: 8),
              Text(_statusMessage, style: TextStyle(fontSize: 11.5, color: theme.colorScheme.outline, height: 1.4)),
              if (_processingStage != ProcessingStage.idle && _processingStage != ProcessingStage.completed && _processingStage != ProcessingStage.error) ...[
                const SizedBox(height: 8),
                const LinearProgressIndicator(),
              ],
            ],
          ),
        ),
        if (_recordedAudioPath != null) ...[
          const SizedBox(height: 10),
          Text('On-device cache · ${_recordedAudioPath!.split(RegExp(r"[/\\\\]")).last}', style: TextStyle(fontSize: 10, color: theme.colorScheme.outline, fontFamily: 'monospace'), overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
        ],
        const SizedBox(height: 8),
      ],
    );
  }

  // --- Intelligence Tab: Full Transcript & Multilingual Editor ---

  Widget _buildTranscriptTab(ThemeData theme) {
    final transcript = _currentSession?.transcript ?? '';

    if (transcript.isEmpty) {
      return EmptyState(
        icon: Icons.description_outlined,
        title: 'No transcript yet',
        body: 'Record audio, import a Zoom / WhatsApp file, or paste notes to run biomedical transcription and AI synthesis.',
        primaryLabel: 'Paste notes to analyze',
        onPrimary: _showPasteTranscriptDialog,
        secondaryLabel: 'Import audio file',
        onSecondary: () => _importAudioFileDialog(),
      );
    }

    final wordCount = transcript.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    final estimatedMin = (wordCount / 140).toStringAsFixed(1);
    final displayedText = (_showTranslatedTranscript && _translatedTranscript != null)
        ? _translatedTranscript!
        : transcript;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Session transcript', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 7,
                          runSpacing: 7,
                          children: [
                            StatusPill(icon: Icons.text_snippet_outlined, label: '$wordCount words · ~$estimatedMin min', color: theme.colorScheme.primary),
                            if (_currentSession?.transcriptSha256 != null)
                              StatusPill(icon: Icons.verified_outlined, label: 'Ref ${_currentSession!.transcriptSha256!.substring(0, 8)}', color: theme.colorScheme.secondary),
                            if (_showTranslatedTranscript) StatusPill(icon: Icons.translate, label: 'Hindi view', color: theme.colorScheme.tertiary),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    alignment: WrapAlignment.end,
                    children: [
                      OutlinedButton.icon(onPressed: _copyTranscriptToClipboard, icon: const Icon(Icons.copy_outlined, size: 14), label: const Text('Copy')),
                      FilledButton.tonalIcon(onPressed: _showSaveTranscriptMenu, icon: const Icon(Icons.save_alt_outlined, size: 14), label: const Text('Save')),
                      OutlinedButton.icon(
                        onPressed: _toggleEditTranscript,
                        icon: Icon(_isTranscriptEditMode ? Icons.visibility_outlined : Icons.edit_note_outlined, size: 14),
                        label: Text(_isTranscriptEditMode ? 'View' : 'Edit'),
                      ),
                      FilledButton.icon(
                        onPressed: _isTranslatingTranscript ? null : _toggleTranslateTranscript,
                        icon: _isTranslatingTranscript
                            ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.translate, size: 14),
                        label: Text(_showTranslatedTranscript ? 'Original' : 'Hindi'),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (_showTranslatedTranscript && _translatedTranscript != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.g_translate, color: theme.colorScheme.primary, size: 17),
                      const SizedBox(width: 8),
                      const Expanded(child: Text('Hindi biomedical translation · gene & drug casing preserved', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
                      TextButton(onPressed: () => setState(() => _showTranslatedTranscript = false), child: const Text('Original', style: TextStyle(fontSize: 12))),
                    ],
                  ),
                ),
              if (_isTranscriptEditMode) ...[
                LabCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SectionLabel('Edit transcript'),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _transcriptEditController,
                        maxLines: 14,
                        style: const TextStyle(fontSize: 13.5, height: 1.6, fontFamily: 'monospace'),
                        decoration: const InputDecoration(hintText: 'Paste or edit transcript here...'),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 8,
                        children: [
                          TextButton(onPressed: () => setState(() => _isTranscriptEditMode = false), child: const Text('Cancel')),
                          FilledButton.tonalIcon(onPressed: _saveEditedTranscript, icon: const Icon(Icons.check, size: 15), label: const Text('Save & update hash')),
                          FilledButton.icon(onPressed: () => _processTextDirectly(_transcriptEditController.text), icon: const Icon(Icons.auto_awesome, size: 15), label: const Text('Run AI analysis')),
                        ],
                      ),
                    ],
                  ),
                ),
              ] else ...[
                LabCard(
                  color: theme.colorScheme.surfaceContainerLowest,
                  padding: const EdgeInsets.all(22),
                  child: SelectableText(
                    displayedText,
                    style: theme.textTheme.bodyLarge?.copyWith(height: 1.75, letterSpacing: 0.15, fontSize: 14.5),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // --- Intelligence Tab 1: Scientific Summary ---

  Widget _buildSummaryTab(ThemeData theme) {
    final summary = _currentSession?.summary;
    if (summary == null) {
      final hasAudio = _recordedAudioPath != null || (_currentSession?.audioPath?.isNotEmpty == true);
      return EmptyState(
        icon: Icons.science_outlined,
        title: 'No synthesis yet',
        body: hasAudio
            ? 'Audio is ready. Run the biomedical pipeline to extract hypothesis, findings, protocols, compounds and citations.'
            : 'Record, import or paste a session, then synthesize hypotheses, assays and bench tasks.',
        primaryLabel: hasAudio ? 'Synthesize with AI' : 'Paste notes to analyze',
        onPrimary: hasAudio ? _executeAiPipeline : _showPasteTranscriptDialog,
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Expanded(child: Text('Executive synthesis', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20))),
                  OutlinedButton.icon(
                    onPressed: _isTranslatingSummary ? null : _toggleTranslateSummary,
                    icon: _isTranslatingSummary
                        ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.translate, size: 13),
                    label: Text(_showTranslatedSummary ? 'English' : 'Hindi', style: const TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                  ),
                  const SizedBox(width: 8),
                  StatusPill(icon: Icons.language_outlined, label: summary.detectedLanguage.split('/').first.trim(), color: theme.colorScheme.primary),
                ],
              ),
              const SizedBox(height: 12),
              if (_currentSession?.audioSha256 != null || _currentSession?.transcriptSha256 != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondary.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: theme.colorScheme.secondary.withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.verified, size: 15, color: theme.colorScheme.secondary),
                          const SizedBox(width: 6),
                          Text('INTEGRITY REFERENCES', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 10.5, letterSpacing: 1.0, color: theme.colorScheme.secondary)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (_currentSession?.audioSha256 != null)
                        Row(
                          children: [
                            const Text('Audio  ', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11)),
                            Expanded(child: Text(_currentSession!.audioSha256!, style: const TextStyle(fontSize: 10.5, fontFamily: 'monospace'), overflow: TextOverflow.ellipsis)),
                            IconButton(
                              icon: const Icon(Icons.copy_outlined, size: 14),
                              visualDensity: VisualDensity.compact,
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: _currentSession!.audioSha256!));
                                _showSnackBar('Audio SHA-256 copied');
                              },
                            ),
                          ],
                        ),
                      if (_currentSession?.transcriptSha256 != null)
                        Row(
                          children: [
                            const Text('Transcript  ', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11)),
                            Expanded(child: Text(_currentSession!.transcriptSha256!, style: const TextStyle(fontSize: 10.5, fontFamily: 'monospace'), overflow: TextOverflow.ellipsis)),
                            IconButton(
                              icon: const Icon(Icons.copy_outlined, size: 14),
                              visualDensity: VisualDensity.compact,
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: _currentSession!.transcriptSha256!));
                                _showSnackBar('Transcript SHA-256 copied');
                              },
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              if (summary.scientificHypothesis.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.all(15),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(borderRadius: BorderRadius.circular(11), color: theme.colorScheme.primary.withValues(alpha: 0.15)),
                        child: Icon(Icons.lightbulb_outline, color: theme.colorScheme.primary, size: 18),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('HYPOTHESIS', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 10.5, letterSpacing: 1.1, color: theme.colorScheme.primary)),
                            const SizedBox(height: 4),
                            Text(summary.scientificHypothesis, style: const TextStyle(fontSize: 13.5, height: 1.5)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
              LabCard(
                padding: const EdgeInsets.all(18),
                child: Text(
                  (_showTranslatedSummary && _translatedSummary != null) ? _translatedSummary! : summary.executiveSummary,
                  style: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
                ),
              ),
              const SizedBox(height: 18),
              SectionLabel('Key findings', icon: Icons.query_stats_outlined),
              const SizedBox(height: 8),
              ...summary.keyPoints.map((point) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: LabCard(
                      padding: const EdgeInsets.all(13),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.check_circle_outline, size: 18, color: theme.colorScheme.primary),
                          const SizedBox(width: 10),
                          Expanded(child: Text(point, style: const TextStyle(fontSize: 13.2, height: 1.5))),
                        ],
                      ),
                    ),
                  )),
              const SizedBox(height: 12),
              SectionLabel('Protocol decisions', icon: Icons.gavel_outlined),
              const SizedBox(height: 8),
              ...summary.decisionsMade.map((decision) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: LabCard(
                      padding: const EdgeInsets.all(13),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.gavel_outlined, size: 17, color: theme.colorScheme.secondary),
                          const SizedBox(width: 10),
                          Expanded(child: Text(decision, style: const TextStyle(fontSize: 13.2, height: 1.5))),
                        ],
                      ),
                    ),
                  )),
              if (_currentSession?.liveNotes.isNotEmpty == true) ...[
                const SizedBox(height: 12),
                SectionLabel('Live annotations · ${_currentSession!.liveNotes.length}', icon: Icons.bookmark_outline),
                const SizedBox(height: 8),
                ..._currentSession!.liveNotes.map((note) => Padding(
                      padding: const EdgeInsets.only(bottom: 7),
                      child: LabCard(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(color: theme.colorScheme.tertiary.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(8)),
                              child: Text(formatMS(note.timestampSeconds), style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11, color: theme.colorScheme.tertiary, fontFeatures: const [FontFeature.tabularFigures()])),
                            ),
                            const SizedBox(width: 10),
                            Expanded(child: Text(note.note, style: const TextStyle(fontSize: 13))),
                          ],
                        ),
                      ),
                    )),
              ],
              if (_currentSession?.slideAttachments.isNotEmpty == true) ...[
                const SizedBox(height: 12),
                SectionLabel('Figures · tap to inspect', icon: Icons.image_outlined),
                const SizedBox(height: 8),
                ..._currentSession!.slideAttachments.map((slide) => Padding(
                      padding: const EdgeInsets.only(bottom: 7),
                      child: LabCard(
                        onTap: () => _showFigureLightbox(slide),
                        child: Row(
                          children: [
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: theme.colorScheme.primary.withValues(alpha: 0.12)),
                              child: Icon(Icons.zoom_in, color: theme.colorScheme.primary, size: 18),
                            ),
                            const SizedBox(width: 11),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(slide.caption, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                                  Text('Logged at ${formatHMS(slide.timestampSeconds)}', style: TextStyle(fontSize: 11.5, color: theme.colorScheme.outline)),
                                ],
                              ),
                            ),
                            const Icon(Icons.chevron_right, size: 18),
                          ],
                        ),
                      ),
                    )),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // --- Intelligence Tab 2: Protocols & Tasks ---

  Widget _buildTasksTab(ThemeData theme) {
    final tasks = _currentSession?.actionItems ?? [];
    if (tasks.isEmpty) {
      return const EmptyState(
        icon: Icons.fact_check_outlined,
        title: 'No bench tasks yet',
        body: 'Run AI synthesis to extract assays, reagent orders, IRB steps and manuscript tasks with owners and priorities.',
      );
    }

    final done = tasks.where((e) => e.isCompleted).length;
    Color prioColor(String p) {
      if (p.toLowerCase() == 'high') return theme.colorScheme.error;
      if (p.toLowerCase() == 'medium') return theme.colorScheme.tertiary;
      return theme.colorScheme.secondary;
    }

    return ListView.separated(
      padding: const EdgeInsets.all(20),
      itemCount: tasks.length + 1,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(child: Text('Bench protocols', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 19))),
                  StatusPill(icon: Icons.task_alt_outlined, label: '$done/${tasks.length} done', color: theme.colorScheme.primary),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(value: tasks.isEmpty ? 0 : done / tasks.length, minHeight: 6),
              ),
              const SizedBox(height: 6),
            ],
          );
        }
        final item = tasks[index - 1];
        final pc = prioColor(item.priority);
        return LabCard(
          padding: const EdgeInsets.all(13),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: item.isCompleted,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
                onChanged: (val) {
                  setState(() {
                    item.isCompleted = val ?? false;
                  });
                  if (_currentSession != null) {
                    SessionRepository().saveSession(_currentSession!);
                  }
                },
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.task,
                      style: TextStyle(
                        decoration: item.isCompleted ? TextDecoration.lineThrough : null,
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                        height: 1.4,
                        color: item.isCompleted ? theme.colorScheme.outline : theme.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        StatusPill(icon: Icons.science_outlined, label: item.category, color: theme.colorScheme.primary),
                        StatusPill(icon: Icons.flag_outlined, label: item.priority, color: pc),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircleAvatar(
                              radius: 10,
                              backgroundColor: theme.colorScheme.secondaryContainer,
                              child: Text(item.assignee.isNotEmpty ? item.assignee[0].toUpperCase() : '?', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w800)),
                            ),
                            const SizedBox(width: 5),
                            Text(item.assignee, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                          ],
                        ),
                        if (item.speaker != null) Text('by ${item.speaker}', style: const TextStyle(fontSize: 11.5, fontStyle: FontStyle.italic, color: Colors.grey)),
                        if (item.deadline != null)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.calendar_today_outlined, size: 12, color: Colors.orange),
                              const SizedBox(width: 4),
                              Text(item.deadline!, style: const TextStyle(color: Colors.orange, fontSize: 11.5, fontWeight: FontWeight.w700)),
                            ],
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // --- Intelligence Tab 3: Speakers & Dialog Diarization ---

  Color _getSpeakerColor(String speakerId) {
    final colors = [
      const Color(0xFF0A7C6B),
      const Color(0xFF3B5BFF),
      const Color(0xFFC2410C),
      const Color(0xFF7C3AED),
      const Color(0xFF15803D),
      const Color(0xFF475569),
      const Color(0xFFB77900),
      const Color(0xFF6D28D9),
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
            Icon(Icons.record_voice_over_outlined, color: Color(0xFF0A7C6B)),
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
                prefixIcon: Icon(Icons.person_outline),
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
            Icon(Icons.video_call_outlined, color: Color(0xFF3B5BFF)),
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
                'LabScribe stores recordings and notes on-device. Here is how to capture call audio for import:',
                style: TextStyle(fontSize: 13),
              ),
              SizedBox(height: 16),
              Text('1. Zoom Meetings', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF3B5BFF))),
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
      return EmptyState(
        icon: Icons.record_voice_over_outlined,
        title: 'No diarization yet',
        body: 'Run AI synthesis to segment who said what, rename speakers once, and tap any turn to seek audio.',
        primaryLabel: 'Generate speaker turns',
        onPrimary: (_recordedAudioPath != null || (_currentSession?.transcript.isNotEmpty == true)) ? _executeAiPipeline : null,
      );
    }

    final uniqueSpeakers = turns.map((t) => t.speakerName).toSet().toList();

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6))),
          ),
          child: Row(
            children: [
              Icon(Icons.people_alt_outlined, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('${uniqueSpeakers.length} speakers', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
              Text(' · ${turns.length} turns', style: TextStyle(fontSize: 12, color: theme.colorScheme.outline)),
              if (_currentSession?.isVirtualCall == true) ...[
                const SizedBox(width: 10),
                StatusPill(icon: Icons.video_call_outlined, label: 'Virtual call', color: theme.colorScheme.secondary),
              ],
              const Spacer(),
              Text('Tap name to rename', style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: theme.colorScheme.outline)),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(20),
            itemCount: turns.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final turn = turns[index];
              final speakerColor = _getSpeakerColor(turn.speakerId);
              return LabCard(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 14,
                          backgroundColor: speakerColor.withValues(alpha: 0.15),
                          child: Text(
                            turn.speakerName.isNotEmpty ? turn.speakerName[0].toUpperCase() : 'S',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: speakerColor),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: InkWell(
                            onTap: () => _showRenameSpeakerDialog(turn.speakerId, turn.speakerName),
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
                              child: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      turn.speakerName,
                                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: speakerColor),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Icon(Icons.edit_outlined, size: 13, color: speakerColor.withValues(alpha: 0.7)),
                                ],
                              ),
                            ),
                          ),
                        ),
                        InkWell(
                          onTap: () => _seekAudio(turn.startSeconds),
                          borderRadius: BorderRadius.circular(99),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(99),
                              border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.play_circle_outline, size: 13, color: Color(0xFF3B5BFF)),
                                const SizedBox(width: 4),
                                Text(
                                  '${formatMS(turn.startSeconds)}–${formatMS(turn.endSeconds)}',
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Container(width: 28, height: 3, decoration: BoxDecoration(borderRadius: BorderRadius.circular(3), color: speakerColor.withValues(alpha: 0.5))),
                    const SizedBox(height: 8),
                    Text(turn.text, style: const TextStyle(fontSize: 13.2, height: 1.55)),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // --- Glossary tab ---

  Widget _searchBar(ThemeData theme, TextEditingController controller, String hint, bool loading, VoidCallback onSearch, VoidCallback onClear) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6))),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              onSubmitted: (_) => onSearch(),
              onChanged: (_) { if (mounted) setState(() {}); },
              decoration: InputDecoration(
                hintText: hint,
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: controller.text.isNotEmpty
                    ? IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: onClear)
                    : null,
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: loading ? null : onSearch,
            icon: loading
                ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.science_outlined, size: 15),
            label: const Text('Lookup'),
          ),
        ],
      ),
    );
  }

  Widget _buildGlossaryTab(ThemeData theme) {
    final rawTerms = _currentSession?.glossaryTerms ?? [];
    final terms = _searchResultsPubChem.isNotEmpty ? _searchResultsPubChem : rawTerms;

    return Column(
      children: [
        _searchBar(
          theme,
          _pubchemSearchController,
          'Compound, gene or assay · e.g. Osimertinib, KRAS…',
          _isSearchingPubchem,
          () => _searchPubChemOnDemand(_pubchemSearchController.text),
          () {
            _pubchemSearchController.clear();
            setState(() => _searchResultsPubChem.clear());
          },
        ),
        Expanded(
          child: terms.isEmpty
              ? const EmptyState(
                  icon: Icons.medication_liquid_outlined,
                  title: 'Compound atlas',
                  body: 'Search NIH PubChem or the offline atlas above — or run AI synthesis to auto-extract drugs, genes and assays.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(20),
                  itemCount: terms.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final term = terms[index];
                    final isPubChem = term.source == 'PubChem';
                    return LabCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  term.word.toUpperCase(),
                                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: isPubChem ? theme.colorScheme.primary : theme.colorScheme.onSurface),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              StatusPill(
                                icon: isPubChem ? Icons.science_outlined : Icons.menu_book_outlined,
                                label: isPubChem ? 'NIH PubChem' : (term.partOfSpeech.isNotEmpty ? term.partOfSpeech : 'Atlas'),
                                color: isPubChem ? theme.colorScheme.primary : theme.colorScheme.secondary,
                              ),
                            ],
                          ),
                          if (term.phonetic.isNotEmpty) Text(term.phonetic, style: TextStyle(color: theme.colorScheme.outline, fontStyle: FontStyle.italic, fontSize: 12)),
                          const SizedBox(height: 8),
                          Text(term.definition, style: theme.textTheme.bodyMedium?.copyWith(height: 1.5)),
                          if (term.example != null) ...[
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerLow, borderRadius: BorderRadius.circular(12)),
                              child: Text(term.example!, style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic, height: 1.45)),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // --- Citations tab ---

  Widget _buildCitationsTab(ThemeData theme) {
    final rawCitations = _currentSession?.citations ?? [];
    final citations = _searchResultsPubMed.isNotEmpty ? _searchResultsPubMed : rawCitations;

    return Column(
      children: [
        _searchBar(
          theme,
          _pubmedSearchController,
          'Paper, trial or PMID · e.g. KRAS G12C, 33208354…',
          _isSearchingPubmed,
          () => _searchPubMedOnDemand(_pubmedSearchController.text),
          () {
            _pubmedSearchController.clear();
            setState(() => _searchResultsPubMed.clear());
          },
        ),
        Expanded(
          child: citations.isEmpty
              ? const EmptyState(
                  icon: Icons.library_books_outlined,
                  title: 'Literature shelf',
                  body: 'Search NCBI PubMed above for trials and mechanisms — or run AI synthesis to auto-resolve citations.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(20),
                  itemCount: citations.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final cite = citations[index];
                    return LabCard(
                      onTap: () => _showArticleReader(cite),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: Text(cite.title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5, height: 1.45))),
                              const SizedBox(width: 10),
                              StatusPill(icon: Icons.tag_outlined, label: cite.pmid, color: theme.colorScheme.secondary),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(cite.authors, style: theme.textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic)),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Expanded(child: Text('${cite.journal} (${cite.pubYear})${cite.doi != null ? ' · DOI ${cite.doi}' : ''}', style: TextStyle(color: theme.colorScheme.outline, fontSize: 12))),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.chrome_reader_mode_outlined, size: 14, color: theme.colorScheme.primary),
                                  const SizedBox(width: 4),
                                  Text('Read', style: TextStyle(fontSize: 11.5, color: theme.colorScheme.primary, fontWeight: FontWeight.w800)),
                                ],
                              ),
                            ],
                          ),
                        ],
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
    final hasTranscript = _currentSession?.transcript.isNotEmpty == true;

    void suggest(String q) {
      if (!hasTranscript) {
        _showSnackBar('Add a transcript first — paste notes or process audio.');
        return;
      }
      _chatController.text = q;
      _sendChatMessage();
    }

    return Column(
      children: [
        if (history.isEmpty)
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    children: [
                      const SizedBox(height: 12),
                      Container(
                        width: 66,
                        height: 66,
                        decoration: BoxDecoration(shape: BoxShape.circle, color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5), border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.3))),
                        child: Icon(Icons.forum_outlined, size: 28, color: theme.colorScheme.primary),
                      ),
                      const SizedBox(height: 14),
                      const Text('Grounded research Q&A', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                      const SizedBox(height: 6),
                      Text(
                        hasTranscript ? 'Ask about doses, controls, p-values or mechanisms — answers stay grounded in this session.' : 'Paste or transcribe a session first, then interrogate it with strict context grounding.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: theme.colorScheme.outline, height: 1.5),
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.center,
                        children: [
                          ActionChip(label: const Text('Resistance mechanism?'), onPressed: () => suggest('What resistance mechanism was discussed?')),
                          ActionChip(label: const Text('Dose & p-value?'), onPressed: () => suggest('What dose and statistical significance were reported?')),
                          ActionChip(label: const Text('List action items'), onPressed: () => suggest('List all bench action items and owners')),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              controller: _chatScrollController,
              padding: const EdgeInsets.all(16),
              itemCount: history.length,
              itemBuilder: (context, index) {
                final msg = history[index];
                final isUser = msg.sender == 'user';
                return Align(
                  alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!isUser) ...[
                        Container(
                          width: 28,
                          height: 28,
                          margin: const EdgeInsets.only(right: 8, top: 4),
                          decoration: BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: [theme.colorScheme.primary, theme.colorScheme.secondary])),
                          child: Icon(Icons.biotech, size: 14, color: theme.colorScheme.onPrimary),
                        ),
                      ],
                      Flexible(
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 5),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
                          decoration: BoxDecoration(
                            color: isUser ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerLow,
                            borderRadius: BorderRadius.only(
                              topLeft: const Radius.circular(16),
                              topRight: const Radius.circular(16),
                              bottomLeft: Radius.circular(isUser ? 16 : 5),
                              bottomRight: Radius.circular(isUser ? 5 : 16),
                            ),
                            border: isUser ? null : Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6)),
                          ),
                          child: Text(
                            msg.text,
                            style: TextStyle(fontSize: 13.2, height: 1.5, color: isUser ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        if (_isWaitingForAiChatResponse)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: theme.colorScheme.primary)),
                const SizedBox(width: 8),
                Text('Synthesizing grounded answer…', style: TextStyle(fontSize: 12, color: theme.colorScheme.outline)),
              ],
            ),
          ),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6))),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _chatController,
                  onSubmitted: (_) => _sendChatMessage(),
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(hintText: 'Ask about protocols, controls, p-values…'),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _sendChatMessage,
                style: FilledButton.styleFrom(shape: const CircleBorder(), padding: const EdgeInsets.all(12), minimumSize: const Size(44, 44)),
                child: const Icon(Icons.arrow_upward, size: 18),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(String message) {
    final parts = message.split('\n');
    final title = parts.first;
    final body = parts.length > 1 ? parts.sublist(1).join('\n') : '';
    return EmptyState(icon: Icons.science_outlined, title: title, body: body.isEmpty ? 'Run AI synthesis to populate this dashboard.' : body);
  }
}
