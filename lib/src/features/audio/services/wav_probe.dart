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
