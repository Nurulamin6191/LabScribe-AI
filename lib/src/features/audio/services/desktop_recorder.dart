import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:record/record.dart';

import 'wav_probe.dart';

/// Microphone capture on Linux, backed by the FFmpeg CLI.
///
/// Why this exists: the `record` package's Linux backend shells out to an
/// external `fmedia` binary that neither this app nor any mainstream distro
/// repository ships — so recording (and therefore transcription) fails out of
/// the box on Linux. FFmpeg is already a hard dependency of this app (the
/// .deb declares it, and audio import runs it), it captures straight from
/// PulseAudio/PipeWire — ALSA as fallback — and it writes exactly the 16 kHz
/// mono 16-bit WAV that on-device Whisper consumes, eliminating the
/// "WAV file must be 16 kHz" native failure entirely.
class DesktopRecorder {
  Process? _process;
  String _stderrLog = '';
  String? _currentPath;
  bool _paused = false;

  /// Whether FFmpeg (this backend) is usable on this machine.
  static Future<bool> isAvailable() => _binaryRuns('ffmpeg', ['-version']);

  /// Whether the `record` package's Linux backend has its `fmedia` binary.
  /// Kept so the app can explain which backend it chose and why.
  static Future<bool> isFmediaAvailable() =>
      _binaryRuns('fmedia', ['--version']);

  static Future<bool> _binaryRuns(String bin, List<String> args) async {
    try {
      await Process.run(bin, args);
      return true; // ran at all — a non-zero exit still proves presence
    } catch (_) {
      return false;
    }
  }

  bool get isRunning => _process != null;
  bool get isPaused => _paused;

  /// Last stderr output from the capture process (for error reporting).
  String get lastError => _stderrLog.trim();

  // --- Device enumeration -------------------------------------------------

  static bool? _pulseAvailable;

  /// PulseAudio/PipeWire sources (mics and system-audio monitors), plus a
  /// direct ALSA fallback when Pulse exposes no microphone at all — common
  /// in headless or oddly-routed sessions where its "default" source is a
  /// silent monitor.
  static Future<List<InputDevice>> listInputDevices() async {
    final devices = <InputDevice>[
      const InputDevice(id: 'default', label: 'System default microphone'),
    ];
    var pulseInputs = 0;
    try {
      final result = await Process.run('ffmpeg', ['-sources', 'pulse']);
      if (result.exitCode == 0) {
        _pulseAvailable = true;
        final line = RegExp(r'^\s+\*?\s*(\S+)\s*(?:\[([^\]]+)\])?');
        for (final raw in (result.stdout as String).split('\n')) {
          if (raw.trim().isEmpty) continue;
          final m = line.firstMatch(raw);
          if (m == null) continue; // header lines start at column 0
          final id = m.group(1)!;
          final label = m.group(2);
          final monitor = id.endsWith('.monitor');
          if (!monitor) pulseInputs++;
          devices.add(InputDevice(
            id: id,
            label: monitor
                ? 'System audio: ${label ?? id}'
                : (label ?? id),
          ));
        }
      } else {
        _pulseAvailable = false;
      }
    } catch (_) {
      _pulseAvailable = false;
    }
    if (pulseInputs == 0) {
      devices.addAll(await _alsaCaptureDevices());
    }
    if (_pulseAvailable == false) {
      devices[0] = const InputDevice(
          id: 'default', label: 'Default microphone (ALSA)');
    }
    return devices;
  }

  /// Capture cards from `arecord -l` as FFmpeg `-f alsa` sources
  /// (`plughw:C,D` lets ALSA convert rate/format itself).
  static Future<List<InputDevice>> _alsaCaptureDevices() async {
    try {
      final r = await Process.run('arecord', ['-l']);
      final out = '${r.stdout}\n${r.stderr}';
      // "card 0: sofhdadsp [sof-hda-dsp], device 0: HDA Analog (*) []"
      final re = RegExp(r'card\s+(\d+):[^,]+,\s*device\s+(\d+):\s*([^\(\*\[]+)');
      final seen = <String>{};
      final list = <InputDevice>[];
      for (final m in re.allMatches(out)) {
        final id = 'plughw:${m.group(1)},${m.group(2)}';
        if (!seen.add(id)) continue;
        list.add(InputDevice(id: id, label: '${m.group(3)!.trim()} (ALSA)'));
      }
      return list;
    } catch (_) {
      return const []; // alsa-utils may be absent — pulse alone must work
    }
  }

  // --- Capture lifecycle --------------------------------------------------

  /// Starts capturing to [path] at 16 kHz mono 16-bit WAV.
  ///
  /// [denoise] applies a gentle high-pass + spectral noise reduction, the
  /// FFmpeg equivalent of the recorder package's noise suppression.
  Future<void> start({
    required String path,
    String? deviceId,
    bool denoise = true,
  }) async {
    if (_process != null) {
      throw StateError('Already recording.');
    }
    await _spawn(_inputArgs(deviceId, denoise)..addAll([
          '-ar', '16000',
          '-ac', '1',
          '-c:a', 'pcm_s16le',
          '-f', 'wav',
          path,
        ]));
    // File mode: audio goes to the WAV, stdout stays idle — drain it so the
    // pipe can never fill if FFmpeg ever prints there.
    _process!.stdout.drain<void>().catchError((_) {});
    _currentPath = path;
  }

  /// Starts capturing and returns 16 kHz mono PCM16 bytes on stdout as a
  /// stream — no file. Pair with `WavWriter` to keep the recording while a
  /// live-caption session consumes the same bytes.
  Future<Stream<Uint8List>> startPcmStream({
    String? deviceId,
    bool denoise = true,
  }) async {
    if (_process != null) {
      throw StateError('Already recording.');
    }
    await _spawn(_inputArgs(deviceId, denoise)..addAll([
          '-ar', '16000',
          '-ac', '1',
          '-c:a', 'pcm_s16le',
          '-f', 's16le',
          'pipe:1',
        ]));
    _currentPath = null;
    // stdout carries audio, so only stderr is drained into the log.
    return _process!.stdout
        .map((chunk) => chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
  }

  List<String> _inputArgs(String? deviceId, bool denoise) {
    final source =
        (deviceId == null || deviceId.isEmpty) ? 'default' : deviceId;
    // Explicit ALSA hardware ids (`plughw:0,0`, `hw:1,0`) bypass Pulse;
    // everything else is a Pulse source name when Pulse is reachable.
    final isAlsaId = RegExp(r'^(plughw|hw):').hasMatch(source);
    final usePulse = !isAlsaId && (_pulseAvailable ?? true);
    return <String>[
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      if (usePulse) ...['-f', 'pulse', '-i', source]
      else ...['-f', 'alsa', '-i', isAlsaId ? source : 'default'],
      if (denoise) ...['-af', 'highpass=f=75,afftdn=nf=-25'],
    ];
  }

  Future<void> _spawn(List<String> args) async {
    _stderrLog = '';
    final process = await Process.start('ffmpeg', args);
    _process = process;
    _paused = false;

    process.stderr.transform(utf8.decoder).listen((chunk) {
      _stderrLog += chunk;
      if (_stderrLog.length > 4096) {
        _stderrLog = _stderrLog.substring(_stderrLog.length - 4096);
      }
    });

    // Capture runs for minutes; dying within half a second means the source
    // was unusable (busy device, no pulse server) — fail here with the real
    // reason instead of silently writing an empty file.
    final outcome = await Future.any<int?>([
      process.exitCode,
      Future.delayed(const Duration(milliseconds: 500), () => null),
    ]);
    if (outcome != null) {
      _process = null;
      _currentPath = null;
      final reason = lastError.isEmpty
          ? 'FFmpeg exited immediately (code $outcome).'
          : lastError;
      throw StateError('Could not start capture: $reason');
    }
  }

  /// Freezes the capture process (SIGSTOP). FFmpeg keeps its file handle;
  /// audio stops flowing until [resume].
  Future<void> pause() async {
    final p = _process;
    if (p == null || _paused) return;
    Process.killPid(p.pid, ProcessSignal.sigstop);
    _paused = true;
  }

  Future<void> resume() async {
    final p = _process;
    if (p == null || !_paused) return;
    Process.killPid(p.pid, ProcessSignal.sigcont);
    _paused = false;
  }

  /// Stops the capture, finalizes the WAV, repairs the header if FFmpeg
  /// could not, and returns the recorded path.
  Future<String?> stop() async {
    final p = _process;
    final path = _currentPath;
    if (p == null) return path;

    // A stopped process never sees SIGINT — wake it first so FFmpeg can
    // write the trailer and close the WAV cleanly.
    if (_paused) {
      Process.killPid(p.pid, ProcessSignal.sigcont);
      _paused = false;
      await Future.delayed(const Duration(milliseconds: 150));
    }
    Process.killPid(p.pid, ProcessSignal.sigint);
    var code = await p.exitCode
        .timeout(const Duration(seconds: 5), onTimeout: () => -1);
    if (code == -1) {
      Process.killPid(p.pid, ProcessSignal.sigkill);
      code = await p.exitCode;
    }
    _process = null;
    _currentPath = null;

    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) {
      throw StateError(
          lastError.isEmpty ? 'Recording produced no file.' : lastError);
    }
    // FFmpeg reports 255 when interrupted — that is the normal SIGINT path.
    await WavProbe.repairSizes(file);
    if (await file.length() < 1024) {
      throw StateError(
          lastError.isEmpty
              ? 'Recording produced no audio. Check the selected microphone.'
              : lastError,
      );
    }
    return path;
  }

  Future<void> dispose() async {
    try {
      await stop();
    } catch (_) {}
  }
}
