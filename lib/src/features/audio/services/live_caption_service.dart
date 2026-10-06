import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

import '../../intelligence/services/transcript_cleaner.dart';
import 'desktop_recorder.dart';
import 'wav_writer.dart';

/// Result of a finished live-caption recording.
class LiveCaptionResult {
  final String path;
  final String text;
  final double durationSec;

  const LiveCaptionResult({
    required this.path,
    required this.text,
    required this.durationSec,
  });
}

/// HyperOS-style live subtitles: one 16 kHz mono capture tee'd into
/// (a) a WAV on disk and (b) the on-device Whisper streaming session.
///
/// Because both consumers read the same byte stream, the finished file is
/// complete the moment recording stops — no second pass needed to keep the
/// audio — while [LiveCaptionService.onPartial] delivers progressively
/// refined transcript text for the on-screen subtitle strip.
///
/// Capture backends:
///  - Linux: FFmpeg to stdout (the `record` package needs an external
///    `fmedia` binary no distro ships).
///  - Android/iOS/Windows/macOS: `record` startStream with PCM16.
class LiveCaptionService {
  DesktopRecorder? _desktop;
  AudioRecorder? _recorder;
  WavWriter? _writer;
  WhisperLiveSession? _session;
  StreamSubscription<Uint8List>? _pcmSub;
  StreamSubscription<String>? _partialSub;
  StreamController<Uint8List>? _feed;
  Completer<void> _pcmDone = Completer<void>();
  Future<void> _writeQueue = Future<void>.value();
  String? _wavPath;
  bool _active = false;

  /// Rolling (cleaned) subtitle text from the running session.
  String latestPartial = '';

  bool get isActive => _active;

  /// Starts capture + live inference. Throws when the model is missing or
  /// the microphone is unusable — the caller should fall back to plain
  /// file recording so the meeting is never lost.
  Future<void> start({
    required String wavPath,
    required WhisperModel model,
    String lang = 'auto',
    String? initialPrompt,
    /// Linux FFmpeg source id (ignored elsewhere).
    String? deviceId,
    /// `record` package device (ignored on Linux).
    InputDevice? inputDevice,
    bool denoise = true,
    void Function(String partial)? onPartial,
    void Function(String status)? onStatus,
  }) async {
    if (_active) {
      throw StateError('Live captions are already running.');
    }
    if (_session != null) {
      // Only one native stream session can exist at a time.
      await _teardown();
    }

    _wavPath = wavPath;
    latestPartial = '';
    _pcmDone = Completer<void>();
    _feed = StreamController<Uint8List>();

    // Session first: starting it borrows the warmed model (fast), so no
    // captured audio is dropped while the engine spins up.
    _session = await WhisperController().transcribeLive(
      model: model,
      pcm16Stream: _feed!.stream,
      lang: lang,
      initialPrompt: initialPrompt,
      suppressNonSpeechTokens: true,
      keepModelLoaded: true,
    );

    try {
      _writer = await WavWriter.open(wavPath);

      final Stream<Uint8List> pcm;
      if (Platform.isLinux) {
        _desktop = DesktopRecorder();
        pcm = await _desktop!.startPcmStream(
          deviceId: deviceId,
          denoise: denoise,
        );
      } else {
        final recorder = AudioRecorder();
        _recorder = recorder;
        pcm = await recorder.startStream(RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: WavWriter.sampleRate,
          numChannels: WavWriter.channels,
          device: inputDevice,
          noiseSuppress: denoise,
          echoCancel: false,
          autoGain: false,
        ));
      }

      _pcmSub = pcm.listen(
        (chunk) {
          // Serialize writes so header patching in close() can never race
          // an in-flight append.
          _writeQueue = _writeQueue
              .then((_) => _writer?.write(chunk))
              .catchError((_) {});
          final feed = _feed;
          if (feed != null && !feed.isClosed) feed.add(chunk);
        },
        onDone: _onPcmDone,
        onError: (Object e) {
          debugPrint('LiveCaptionService: capture error: $e');
          _onPcmDone();
        },
      );

      _partialSub = _session!.partials.listen(
        (text) {
          final cleaned = TranscriptCleaner.clean(text);
          latestPartial = cleaned;
          onPartial?.call(cleaned);
        },
        onError: (Object e) {
          // A mid-session native error finalizes with the last text; the
          // recording itself is unaffected, so just note it.
          debugPrint('LiveCaptionService: session error: $e');
          onStatus?.call('Live captions paused: $e');
        },
      );

      _active = true;
    } catch (e) {
      await _teardown();
      rethrow;
    }
  }

  void _onPcmDone() {
    final feed = _feed;
    if (feed != null && !feed.isClosed) feed.close(); // triggers session.stop
    if (!_pcmDone.isCompleted) _pcmDone.complete();
  }

  Future<void> pause() async {
    if (!_active) return;
    if (_desktop != null) {
      await _desktop!.pause();
    } else {
      await _recorder?.pause();
    }
  }

  Future<void> resume() async {
    if (!_active) return;
    if (_desktop != null) {
      await _desktop!.resume();
    } else {
      await _recorder?.resume();
    }
  }

  /// Stops capture, drains the tail into the engine, finalizes both the
  /// session text and the WAV header, and returns the result.
  Future<LiveCaptionResult> stop() async {
    if (!_active) throw StateError('Live captions are not running.');
    _active = false;
    try {
      // 1. Stop the source; its stream closing drains the tail audio.
      if (_desktop != null) {
        await _desktop!.stop();
      } else {
        await _recorder?.stop();
      }

      // 2. Wait (bounded) for every captured byte to reach the engine.
      await _pcmDone.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () {},
      );

      // 3. Finalize inference — idempotent with the feed's own onDone stop.
      final raw = await _session
          ?.stop()
          .timeout(const Duration(seconds: 30), onTimeout: () => '');

      // 4. Flush queued writes, then patch the RIFF/data sizes.
      await _writeQueue;
      final writer = _writer;
      await writer?.close();

      final text = TranscriptCleaner.clean(raw ?? '');
      return LiveCaptionResult(
        path: _wavPath!,
        text: text,
        durationSec: writer?.durationSec ?? 0,
      );
    } finally {
      await _teardown();
    }
  }

  /// Releases the capture handles; the session is stopped first so the
  /// parked model stays available for the post-meeting transcription.
  Future<void> _teardown() async {
    try {
      await _partialSub?.cancel();
    } catch (_) {}
    try {
      await _pcmSub?.cancel();
    } catch (_) {}
    final session = _session;
    _session = null;
    if (session != null) {
      try {
        await session.stop();
      } catch (_) {}
    }
    final feed = _feed;
    _feed = null;
    if (feed != null && !feed.isClosed) {
      await feed.close();
    }
    if (_desktop != null) {
      await _desktop!.dispose();
      _desktop = null;
    }
    if (_recorder != null) {
      await _recorder!.dispose();
      _recorder = null;
    }
    _writer = null;
  }

  /// Best-effort cleanup when the UI goes away mid-recording.
  Future<void> dispose() async {
    if (_active) {
      try {
        await stop();
      } catch (_) {}
    } else {
      await _teardown();
    }
  }
}
