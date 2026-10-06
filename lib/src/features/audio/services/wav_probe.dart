import 'dart:io';
import 'dart:typed_data';

/// Minimal WAV header inspector (pure Dart, no plugins).
///
/// Used to distinguish "the file the recorder wrote is malformed" from
/// "the speech engine failed on a good file" — the two failure modes look
/// identical from the outside (empty/null transcription result).
class WavInfo {
  final int sampleRate;
  final int channels;
  final int bitsPerSample;
  final int dataBytes;
  final int fileBytes;

  /// Byte offset of the `data` chunk payload inside the file.
  final int dataOffset;

  const WavInfo({
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.dataBytes,
    required this.fileBytes,
    this.dataOffset = 44,
  });

  double get durationSec => sampleRate > 0 && channels > 0
      ? dataBytes / (sampleRate * channels * (bitsPerSample / 8))
      : 0;

  String get formatLabel => '${sampleRate}Hz/${channels}ch/${bitsPerSample}bit';

  /// True for exactly what on-device Whisper consumes without conversion.
  bool get isWhisperReady => sampleRate == 16000 && channels == 1 && bitsPerSample == 16;
}

class WavProbe {
  /// Writes [seconds] of digital silence as 16 kHz mono 16-bit WAV and
  /// returns the file path. Used to warm up / validate the on-device
  /// speech engine: transcribing silence must complete (with empty text),
  /// which proves the model is downloaded and working.
  static Future<String> writeSilenceWav(Directory dir, {int seconds = 1}) async {
    const sampleRate = 16000;
    final dataLen = sampleRate * seconds * 2;
    final totalLen = 44 + dataLen;
    final bytes = ByteData(totalLen);

    void writeTag(int offset, String tag) {
      for (int i = 0; i < tag.length; i++) {
        bytes.setUint8(offset + i, tag.codeUnitAt(i));
      }
    }

    writeTag(0, 'RIFF');
    bytes.setUint32(4, 36 + dataLen, Endian.little);
    writeTag(8, 'WAVE');
    writeTag(12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little); // PCM
    bytes.setUint16(22, 1, Endian.little); // mono
    bytes.setUint32(24, sampleRate, Endian.little);
    bytes.setUint32(28, sampleRate * 2, Endian.little); // byte rate
    bytes.setUint16(32, 2, Endian.little); // block align
    bytes.setUint16(34, 16, Endian.little); // bits per sample
    writeTag(36, 'data');
    bytes.setUint32(40, dataLen, Endian.little);
    // PCM bytes after offset 44 stay zero = silence.

    final path =
        '${dir.path}/warmup_silence_${DateTime.now().millisecondsSinceEpoch}.wav';
    await File(path).writeAsBytes(bytes.buffer.asUint8List());
    return path;
  }

  /// Returns null when [file] is not a parseable RIFF/WAVE file.
  ///
  /// Walks the RIFF chunk list instead of assuming the classic 44-byte
  /// header, so files with metadata chunks (LIST/INFO, bext, fact) report
  /// the real format and data offset.
  static Future<WavInfo?> probe(File file) async {
    try {
      if (!await file.exists()) return null;
      final length = await file.length();
      if (length < 44) return null;
      final raf = await file.open(mode: FileMode.read);
      try {
        final head = await raf.read(length < 65536 ? length : 65536);
        if (head.length < 44) return null;
        String tag(int offset, int len) =>
            String.fromCharCodes(head.sublist(offset, offset + len));
        if (tag(0, 4) != 'RIFF' || tag(8, 4) != 'WAVE') return null;

        final view = ByteData.sublistView(head);
        int? sampleRate;
        int? channels;
        int? bitsPerSample;
        var dataOffset = -1;
        var dataSize = -1;

        var pos = 12;
        while (pos + 8 <= head.length) {
          final id = tag(pos, 4);
          final size = view.getUint32(pos + 4, Endian.little);
          if (id == 'fmt ' && pos + 8 + 16 <= head.length) {
            final fmt = ByteData.sublistView(head, pos + 8, pos + 8 + 16);
            channels = fmt.getUint16(2, Endian.little);
            sampleRate = fmt.getUint32(4, Endian.little);
            bitsPerSample = fmt.getUint16(14, Endian.little);
          } else if (id == 'data') {
            dataOffset = pos + 8;
            dataSize = size;
            break;
          }
          // Chunks are word-aligned; a garbage size just ends the walk.
          pos += 8 + size + (size & 1);
        }

        if (sampleRate == null || channels == null || dataOffset < 0) {
          return null;
        }
        // An interrupted recorder leaves 0 or 0xFFFFFFFF in the size field —
        // clamp to what the file actually contains.
        var dataBytes = dataSize;
        final remaining = length - dataOffset;
        if (dataBytes <= 0 || dataBytes > remaining) {
          dataBytes = remaining;
        }
        if (sampleRate <= 0 || sampleRate > 192000 || channels <= 0 || channels > 8) {
          return null;
        }
        return WavInfo(
          sampleRate: sampleRate,
          channels: channels,
          bitsPerSample: bitsPerSample == null || bitsPerSample == 0
              ? 16
              : bitsPerSample,
          dataBytes: dataBytes,
          fileBytes: length,
          dataOffset: dataOffset,
        );
      } finally {
        await raf.close();
      }
    } catch (_) {
      return null;
    }
  }

  /// Rewrites the RIFF and `data` chunk sizes after a recorder died before
  /// it could finalize the header (interrupted ffmpeg capture, app killed
  /// mid-recording). On-device Whisper refuses such files outright, so the
  /// bytes are corrected before transcription. Returns true when anything
  /// was fixed.
  static Future<bool> repairSizes(File file) async {
    try {
      final length = await file.length();
      if (length < 44) return false;

      final reader = await file.open(mode: FileMode.read);
      Uint8List head;
      try {
        head = await reader.read(length < 65536 ? length : 65536);
      } finally {
        await reader.close();
      }
      if (head.length < 12) return false;
      String tag(int offset, int len) =>
          String.fromCharCodes(head.sublist(offset, offset + len));
      if (tag(0, 4) != 'RIFF' || tag(8, 4) != 'WAVE') return false;
      final view = ByteData.sublistView(head);

      final patches = <int, int>{}; // offset -> value (uint32 LE)
      final riffSize = view.getUint32(4, Endian.little);
      if (riffSize != length - 8) patches[4] = length - 8;

      var pos = 12;
      while (pos + 8 <= head.length) {
        final id = tag(pos, 4);
        final size = view.getUint32(pos + 4, Endian.little);
        if (id == 'data') {
          final actual = length - (pos + 8);
          if (size != actual) patches[pos + 4] = actual;
          break;
        }
        if (size <= 0) break;
        pos += 8 + size + (size & 1);
      }

      if (patches.isEmpty) return false;
      final writer = await file.open(mode: FileMode.append);
      try {
        for (final entry in patches.entries) {
          await writer.setPosition(entry.key);
          final b = ByteData(4)..setUint32(0, entry.value, Endian.little);
          await writer.writeFrom(b.buffer.asUint8List());
        }
      } finally {
        await writer.close();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Peak linear amplitude (0..1) of the 16-bit PCM payload.
  ///
  /// Distinguishes a real recording from a microphone that captured nothing
  /// but digital silence (wrong device, muted input) — a file can look
  /// perfectly healthy by size while containing no audio at all.
  static Future<double> peakAmplitude(File file) async {
    try {
      final info = await probe(file);
      if (info == null || info.dataBytes <= 0 || info.bitsPerSample != 16) {
        return 0;
      }
      final raf = await file.open(mode: FileMode.read);
      try {
        await raf.setPosition(info.dataOffset);
        var peak = 0;
        final chunk = ByteData(16 * 1024);
        var remaining = info.dataBytes;
        while (remaining > 0) {
          final want = chunk.lengthInBytes < remaining
              ? chunk.lengthInBytes
              : remaining;
          final got = await raf.readInto(chunk.buffer.asUint8List(), 0, want);
          if (got <= 0) break;
          remaining -= got;
          // Every 8th sample is plenty for a peak estimate.
          for (var o = 0; o + 1 < got; o += 16) {
            final v = chunk.getInt16(o, Endian.little).abs();
            if (v > peak) peak = v;
          }
        }
        return peak / 32768.0;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return 0;
    }
  }
}
