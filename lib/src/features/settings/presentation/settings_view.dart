import 'package:flutter/material.dart';
import '../../../core/config_service.dart';
import '../../../core/widgets/labscribe_ui.dart';
import '../../intelligence/services/meeting_intelligence_service.dart';

/// Engine settings: on-device speech model choice and how-it-works notes.
/// No endpoints, keys, or URLs — install-and-use by design.
class SettingsView extends StatefulWidget {
  /// When true, renders just the content (for embedding as a tab).
  final bool embedded;
  const SettingsView({super.key, this.embedded = false});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  String _whisperModel = 'base';
  late final MeetingIntelligenceService _engine;
  bool _preparing = false;
  String _prepStatus = '';
  int? _prepPct;
  double? _prepDlFraction;
  String _prepDlLabel = '';

  static const _models = [
    ('tiny', 'Tiny · 75 MB', 'Fastest. Good for quick notes on any device.'),
    ('base', 'Base · 150 MB', 'Balanced accuracy and speed. Recommended.'),
    ('small', 'Small · 460 MB', 'Most accurate. Best on newer phones and desktops.'),
  ];

  @override
  void initState() {
    super.initState();
    _whisperModel = ConfigService().whisperModel;
    _engine = MeetingIntelligenceService(config: ConfigService().getAiConfig());
    _refreshDisk();
  }

  Future<void> _refreshDisk() async {
    final st = await _engine.modelFileStatus(_whisperModel);
    if (!mounted) return;
    setState(() {
      _diskInfo = st.present
          ? 'Model file on disk: ${(st.bytes / 1048576).toStringAsFixed(0)} MB.'
          : 'Model file not on disk yet.';
    });
  }

  String _diskInfo = '';

  Future<void> _saveModel(String model) async {
    setState(() => _whisperModel = model);
    await ConfigService().setWhisperModel(model);
    _engine.updateConfig(ConfigService().getAiConfig());
    await _refreshDisk();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Speech model saved. Download it below to get ready.')),
      );
    }
  }

  /// Downloads + validates the selected model right now, with progress —
  /// the AnythingLLM-style "prepare during setup" flow.
  Future<void> _downloadNow() async {
    if (_preparing) return;
    setState(() {
      _preparing = true;
      _prepPct = null;
      _prepDlFraction = null;
      _prepDlLabel = '';
      _prepStatus = 'Starting download...';
    });
    try {
      await _engine.ensureModelReady(
        modelName: _whisperModel,
        force: true,
        onStatus: (s) {
          if (mounted) setState(() => _prepStatus = s);
        },
        onDownloadProgress: (fraction, received, total) {
          if (mounted) {
            setState(() {
              _prepDlFraction = fraction;
              _prepDlLabel =
                  '${(received / 1048576).toStringAsFixed(0)}/${(total / 1048576).toStringAsFixed(0)} MB';
              _prepStatus = 'Downloading model...';
            });
          }
        },
        onProgress: (p) {
          if (mounted) {
            setState(() {
              _prepPct = p;
              _prepDlFraction = null;
              _prepStatus = 'Verifying engine — $p%...';
            });
          }
        },
      );
      if (mounted) {
        setState(() {
          _preparing = false;
          _prepStatus = 'Ready on this device.';
        });
        await _refreshDisk();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Speech model ready. Transcription now works offline.')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _preparing = false;
          _prepStatus = 'Download failed — connect to the internet and retry.';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = ListView(
      padding: const EdgeInsets.all(20),
        children: [
          const PageHeader(
            title: 'On-device engine',
            subtitle: 'Speech recognition runs on your device. No accounts, keys, or servers.',
          ),
          const SizedBox(height: 14),
          LabCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionLabel('Speech model'),
                const SizedBox(height: 4),
                const Text(
                  'Downloads once on first transcription, then works fully offline. Larger models understand accents and terminology better.',
                  style: TextStyle(fontSize: 12.5, height: 1.45),
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: _models
                      .map((m) => ButtonSegment(value: m.$1, label: Text(m.$2.split(' · ').first, style: const TextStyle(fontSize: 12))))
                      .toList(),
                  selected: {_whisperModel},
                  onSelectionChanged: (s) => _saveModel(s.first),
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
                ),
                const SizedBox(height: 10),
                ..._models.map((m) => Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            _whisperModel == m.$1 ? Icons.radio_button_checked : Icons.radio_button_off,
                            size: 16,
                            color: _whisperModel == m.$1 ? theme.colorScheme.primary : theme.colorScheme.outline,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${m.$2} — ${m.$3}',
                              style: const TextStyle(fontSize: 12.5, height: 1.4),
                            ),
                          ),
                          if (m.$1 == ConfigService.recommendedWhisperModel)
                            Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary,
                                borderRadius: BorderRadius.circular(99),
                              ),
                              child: const Text('RECOMMENDED', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: Colors.white)),
                            ),
                        ],
                      ),
                    )),
                const SizedBox(height: 12),
                const Divider(height: 8),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      ConfigService().isModelWarmed(_whisperModel) && !_preparing
                          ? Icons.check_circle
                          : Icons.cloud_download_outlined,
                      size: 17,
                      color: ConfigService().isModelWarmed(_whisperModel) && !_preparing
                          ? Colors.green
                          : theme.colorScheme.outline,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _preparing
                            ? _prepStatus
                            : (ConfigService().isModelWarmed(_whisperModel)
                                ? 'Downloaded and ready on this device.'
                                : 'Not downloaded yet — needs internet once.'),
                        style: const TextStyle(fontSize: 12.5, height: 1.4),
                      ),
                    ),
                  ],
                ),
                if (_diskInfo.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(_diskInfo, style: TextStyle(fontSize: 11.5, color: theme.colorScheme.outline)),
                ],
                if (_preparing && _prepDlFraction != null) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: _prepDlFraction!.clamp(0.0, 1.0)),
                  const SizedBox(height: 4),
                  Text(_prepDlLabel, style: TextStyle(fontSize: 11.5, color: theme.colorScheme.outline)),
                ],
                if (_preparing && _prepDlFraction == null && _prepPct != null) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: (_prepPct! / 100).clamp(0.0, 1.0)),
                ],
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    onPressed: _preparing ? null : _downloadNow,
                    icon: const Icon(Icons.download_outlined, size: 16),
                    label: Text(ConfigService().isModelWarmed(_whisperModel) ? 'Re-download / verify' : 'Download now'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          LabCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionLabel('How analysis works'),
                const SizedBox(height: 8),
                _row(theme, Icons.mic_outlined, 'Record', 'Meetings are saved as 16 kHz WAV — the exact format on-device Whisper reads.'),
                const Divider(height: 16),
                _row(theme, Icons.graphic_eq_outlined, 'Transcribe', 'Whisper runs locally with a biomedical vocabulary bias (genes, drugs, assays). Nothing is uploaded.'),
                const Divider(height: 16),
                _row(theme, Icons.auto_awesome_outlined, 'Understand', 'Summaries, tasks, and Q&A use a keyless hosted open model over an encrypted connection.'),
                const SizedBox(height: 4),
                Text(
                  'Tip: non-WAV imports on Windows/Linux need FFmpeg installed (for example: sudo apt install ffmpeg). Android converts automatically.',
                  style: TextStyle(fontSize: 11.5, color: theme.colorScheme.outline, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          LabCard(
            child: Row(
              children: [
                const BrandMark(size: 34),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('LabScribe AI', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                      Text('Record meetings, get transcripts and insights.', style: TextStyle(fontSize: 12, color: theme.colorScheme.outline)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            BrandMark(size: 30),
            SizedBox(width: 10),
            Text('Engine'),
          ],
        ),
      ),
      body: body,
    );
  }

  Widget _row(ThemeData theme, IconData icon, String title, String body) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: theme.colorScheme.primary.withValues(alpha: 0.12),
          ),
          child: Icon(icon, size: 17, color: theme.colorScheme.primary),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
              Text(body, style: const TextStyle(fontSize: 12.5, height: 1.4)),
            ],
          ),
        ),
      ],
    );
  }
}
