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

  const WavInfo({
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.dataBytes,
    required this.fileBytes,
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
  static Future<WavInfo?> probe(File file) async {
    try {
      if (!await file.exists()) return null;
      final length = await file.length();
      if (length < 44) return null;
      final raf = await file.open(mode: FileMode.read);
      try {
        final header = await raf.read(44);
        if (header.length < 44) return null;
        String tag(int offset, int len) =>
            String.fromCharCodes(header.sublist(offset, offset + len));
        if (tag(0, 4) != 'RIFF' || tag(8, 4) != 'WAVE' || tag(12, 4) != 'fmt ') {
          return null;
        }
        final view = ByteData.sublistView(header);
        final channels = view.getUint16(22, Endian.little);
        final sampleRate = view.getUint32(24, Endian.little);
        final bitsPerSample = view.getUint16(34, Endian.little);
        // Data size usually lives at bytes 40-43 (standard 44-byte header).
        var dataBytes = view.getUint32(40, Endian.little);
        if (dataBytes <= 0 || dataBytes > length) {
          dataBytes = length - 44;
        }
        if (sampleRate <= 0 || sampleRate > 192000 || channels <= 0 || channels > 8) {
          return null;
        }
        return WavInfo(
          sampleRate: sampleRate,
          channels: channels,
          bitsPerSample: bitsPerSample == 0 ? 16 : bitsPerSample,
          dataBytes: dataBytes,
          fileBytes: length,
        );
      } finally {
        await raf.close();
      }
    } catch (_) {
      return null;
    }
  }
}
