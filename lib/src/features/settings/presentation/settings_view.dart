import 'package:flutter/material.dart';
import '../../../core/config_service.dart';
import '../../../core/widgets/labscribe_ui.dart';

/// Engine settings: on-device speech model choice and how-it-works notes.
/// No endpoints, keys, or URLs — install-and-use by design.
class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  String _whisperModel = 'base';

  static const _models = [
    ('tiny', 'Tiny · 75 MB', 'Fastest. Good for quick notes on any device.'),
    ('base', 'Base · 150 MB', 'Balanced accuracy and speed. Recommended.'),
    ('small', 'Small · 460 MB', 'Most accurate. Best on newer phones and desktops.'),
  ];

  @override
  void initState() {
    super.initState();
    _whisperModel = ConfigService().whisperModel;
  }

  Future<void> _saveModel(String model) async {
    setState(() => _whisperModel = model);
    await ConfigService().setWhisperModel(model);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Speech model saved. It downloads once on next transcription.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
      body: ListView(
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
                        ],
                      ),
                    )),
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
      ),
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
