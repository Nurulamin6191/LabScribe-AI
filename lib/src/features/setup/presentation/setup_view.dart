import 'package:flutter/material.dart';
import '../../../core/config_service.dart';
import '../../../core/widgets/labscribe_ui.dart';
import '../../intelligence/services/meeting_intelligence_service.dart';
import '../../public_apis/services/public_api_service.dart';
import '../../recorder/presentation/recorder_view.dart';

/// First-launch setup gate (BlackHole-style onboarding).
///
/// Before the app can transcribe anything it needs a speech model on the
/// device. This screen lists the available models with sizes, marks the
/// recommended one, downloads with visible progress, and only then lets
/// the user into the app. Skipping is allowed but transcription will fail
/// until a model is downloaded (Engine screen offers it again).
class SetupView extends StatefulWidget {
  final MeetingIntelligenceService intelligenceService;
  final PublicApiService publicApiService;

  const SetupView({
    super.key,
    required this.intelligenceService,
    required this.publicApiService,
  });

  @override
  State<SetupView> createState() => _SetupViewState();
}

class _SetupViewState extends State<SetupView> {
  String _model = 'base';
  bool _busy = false;
  String _status = '';
  int? _pct;
  double? _dlFraction;
  String _dlLabel = '';

  static const _models = [
    ('tiny', 'Tiny · 75 MB', 'Fastest. Good for quick notes on any device.'),
    ('base', 'Base · 150 MB', 'Balanced accuracy and speed. Recommended.'),
    ('small', 'Small · 460 MB', 'Most accurate. Best on newer phones and desktops.'),
  ];

  @override
  void initState() {
    super.initState();
    _model = ConfigService().whisperModel;
  }

  bool get _ready => ConfigService().isModelWarmed(_model);

  Future<void> _download() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _pct = null;
      _dlFraction = null;
      _dlLabel = '';
      _status = 'Starting download...';
    });
    try {
      await ConfigService().setWhisperModel(_model);
      widget.intelligenceService.updateConfig(ConfigService().getAiConfig());
      await widget.intelligenceService.ensureModelReady(
        modelName: _model,
        force: true,
        onStatus: (s) {
          if (mounted) setState(() => _status = s);
        },
        onDownloadProgress: (fraction, received, total) {
          if (mounted) {
            setState(() {
              _dlFraction = fraction;
              _dlLabel =
                  '${(received / 1048576).toStringAsFixed(0)}/${(total / 1048576).toStringAsFixed(0)} MB';
              _status = 'Downloading model...';
            });
          }
        },
        onProgress: (p) {
          if (mounted) {
            setState(() {
              _pct = p;
              _dlFraction = null;
              _status = 'Verifying engine — $p%...';
            });
          }
        },
      );
      if (mounted) {
        setState(() {
          _busy = false;
          _status = 'Ready on this device.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = 'Download failed — connect to the internet and retry.';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed: $e')),
        );
      }
    }
  }

  Future<void> _enter({required bool skipped}) async {
    await ConfigService().setSetupDone();
    if (!mounted) return;
    if (skipped) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Skipped — download a model under Engine before transcribing.'),
        ),
      );
    }
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => RecorderView(
          intelligenceService: widget.intelligenceService,
          publicApiService: widget.publicApiService,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              const Center(child: BrandMark(size: 72)),
              const SizedBox(height: 20),
              const Text(
                'Get set up',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 26),
              ),
              const SizedBox(height: 8),
              Text(
                'LabScribe transcribes on your device — no accounts, no keys. '
                'Pick a speech model to download once, then you are offline-ready.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13.5, height: 1.5, color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              ..._models.map((m) {
                final selected = _model == m.$1;
                final warmed = ConfigService().isModelWarmed(m.$1);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: _busy
                        ? null
                        : () async {
                            setState(() => _model = m.$1);
                            await ConfigService().setWhisperModel(m.$1);
                            widget.intelligenceService.updateConfig(ConfigService().getAiConfig());
                          },
                    child: Container(
                      padding: const EdgeInsets.all(15),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        color: theme.cardTheme.color,
                        border: Border.all(
                          color: selected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outlineVariant.withValues(alpha: 0.55),
                          width: selected ? 2 : 1,
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            selected ? Icons.radio_button_checked : Icons.radio_button_off,
                            size: 20,
                            color: selected ? theme.colorScheme.primary : theme.colorScheme.outline,
                          ),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(m.$2, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                                    ),
                                    if (m.$1 == ConfigService.recommendedWhisperModel)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: theme.colorScheme.primary,
                                          borderRadius: BorderRadius.circular(99),
                                        ),
                                        child: Text(
                                          'RECOMMENDED',
                                          style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: theme.colorScheme.onPrimary),
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 3),
                                Text(m.$3, style: const TextStyle(fontSize: 12.5, height: 1.4)),
                                const SizedBox(height: 5),
                                Text(
                                  warmed ? 'Downloaded on this device.' : 'Not downloaded yet.',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    color: warmed ? Colors.green : theme.colorScheme.outline,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
              if (_busy || _status.isNotEmpty) ...[
                const SizedBox(height: 4),
                LabCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _dlFraction != null
                            ? '$_status ${_dlLabel.isNotEmpty ? _dlLabel : ''}'.trim()
                            : (_status.isEmpty ? 'Preparing...' : _status),
                        style: const TextStyle(fontSize: 12.5, height: 1.4),
                      ),
                      if (_busy && _dlFraction != null) ...[
                        const SizedBox(height: 8),
                        LinearProgressIndicator(value: _dlFraction!.clamp(0.0, 1.0)),
                      ],
                      if (_busy && _dlFraction == null && _pct != null) ...[
                        const SizedBox(height: 8),
                        LinearProgressIndicator(value: (_pct! / 100).clamp(0.0, 1.0)),
                      ],
                      if (_busy && _dlFraction == null && _pct == null) ...[
                        const SizedBox(height: 8),
                        const LinearProgressIndicator(),
                      ],
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : _download,
                icon: const Icon(Icons.download_outlined, size: 17),
                label: const Text('Download model'),
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 15)),
              ),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                onPressed: (_busy || !_ready) ? null : () => _enter(skipped: false),
                icon: const Icon(Icons.arrow_forward, size: 17),
                label: const Text('Continue'),
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 15)),
              ),
              TextButton(
                onPressed: _busy ? null : () => _enter(skipped: true),
                child: const Text('Skip for now'),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}
