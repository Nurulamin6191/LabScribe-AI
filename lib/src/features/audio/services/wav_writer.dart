import 'dart:io';
import 'dart:typed_data';

/// Streaming WAV writer for 16 kHz mono 16-bit PCM.
///
/// Live captions receive PCM chunks as they are captured; this writes them
/// to disk as a valid WAV in parallel so the finished recording is ready
/// the moment the user stops — header sizes are patched on [close], never
/// left dangling (on-device Whisper rejects files with bad size fields).
class WavWriter {
  WavWriter._(this._raf, this._path);

  final RandomAccessFile _raf;
  final String _path;
  int _dataBytes = 0;
  bool _closed = false;

  static const int sampleRate = 16000;
  static const int channels = 1;
  static const int bitsPerSample = 16;
  static const int headerSize = 44;

  static const int byteRate =
      sampleRate * channels * (bitsPerSample ~/ 8); // 32000

  /// Opens [path] and writes the placeholder header; PCM bytes are appended
  /// with [write] and sizes finalized by [close].
  static Future<WavWriter> open(String path) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final raf = await file.open(mode: FileMode.write);
    await raf.writeFrom(_header(dataSize: 0));
    return WavWriter._(raf, path);
  }

  static Uint8List _header({required int dataSize}) {
    final h = Uint8List(headerSize);
    final view = ByteData.sublistView(h);
    void ascii(int offset, String tag) {
      for (var i = 0; i < tag.length; i++) {
        h[offset + i] = tag.codeUnitAt(i);
      }
    }

    ascii(0, 'RIFF');
    view.setUint32(4, 36 + dataSize, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    view.setUint32(16, 16, Endian.little); // PCM fmt chunk size
    view.setUint16(20, 1, Endian.little); // audio format = PCM
    view.setUint16(22, channels, Endian.little);
    view.setUint32(24, sampleRate, Endian.little);
    view.setUint32(28, byteRate, Endian.little);
    view.setUint16(32, channels * (bitsPerSample ~/ 8), Endian.little);
    view.setUint16(34, bitsPerSample, Endian.little);
    ascii(36, 'data');
    view.setUint32(40, dataSize, Endian.little);
    return h;
  }

  /// Appends captured PCM16 bytes. Silent no-op after [close].
  Future<void> write(Uint8List pcm) async {
    if (_closed) return;
    await _raf.writeFrom(pcm);
    _dataBytes += pcm.length;
  }

  int get dataBytes => _dataBytes;

  /// Recording length in seconds (16 kHz mono 16-bit = 32000 bytes/s).
  double get durationSec => dataBytes / (byteRate);

  /// Patches the RIFF/data sizes and closes the file. Idempotent.
  Future<String> close() async {
    if (_closed) return _path;
    _closed = true;
    try {
      await _raf.setPosition(4);
      final view = ByteData(4);
      view.setUint32(0, 36 + _dataBytes, Endian.little);
      await _raf.writeFrom(view.buffer.asUint8List());
      await _raf.setPosition(40);
      view.setUint32(0, _dataBytes, Endian.little);
      await _raf.writeFrom(view.buffer.asUint8List());
    } finally {
      await _raf.close();
    }
    return _path;
  }
}
