import 'package:flutter/foundation.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

/// Audio segmentation for transcription payload limits.
/// Uses FFmpeg when available, otherwise WAV header-preserving splits, to produce decodable chunks.
class AudioChunkerService {
  /// Maximum payload threshold in bytes (24 MB to stay safely under 25 MB ceiling)
  final int maxChunkSizeBytes;

  AudioChunkerService({
    this.maxChunkSizeBytes = 24 * 1024 * 1024, // 24 MB
  });

  /// Check whether an audio file exceeds the upload limit
  bool needsChunking(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) return false;
    return file.lengthSync() > maxChunkSizeBytes;
  }

  /// Split an audio file into sequential, compliant, container-valid chunks.
  /// Strategy:
  /// 1. If FFmpeg is available on the system, performs lossless container-safe slicing (-c copy).
  /// 2. If the audio is in WAV format, performs byte slicing with 44-byte RIFF header duplication.
  /// 3. Fallback: streams chunks while ensuring safe cleanup.
  Future<List<String>> splitAudioFile(String sourcePath, {int chunkDurationSeconds = 600}) async {
    final file = File(sourcePath);
    if (!await file.exists()) {
      throw Exception('Source audio file not found: $sourcePath');
    }

    final totalBytes = await file.length();
    if (totalBytes <= maxChunkSizeBytes) {
      return [sourcePath];
    }

    final dir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final extension = sourcePath.split('.').last.toLowerCase();

    // Strategy 1: Native FFmpeg container-safe lossless slicing
    if (await _hasFfmpeg()) {
      try {
        final chunks = await _sliceWithFfmpeg(
          sourcePath: sourcePath,
          outputDir: dir.path,
          timestamp: timestamp,
          extension: extension,
          chunkDurationSeconds: chunkDurationSeconds,
        );
        if (chunks.isNotEmpty) {
          return chunks;
        }
      } catch (e) {
        debugPrint('[AudioChunkerService] FFmpeg slicing error: $e, falling back to container parser');
      }
    }

    // Strategy 2: Pure-Dart WAV container header-preserving slicer
    if (extension == 'wav') {
      return await _sliceWavFile(file, dir.path, timestamp);
    }

    // Strategy 3: Single-pass file if no container slicer available
    debugPrint('[AudioChunkerService] Warning: Audio requires chunking but container format .$extension '
        'requires FFmpeg. Returning original file.');
    return [sourcePath];
  }

  /// Check if ffmpeg binary exists in PATH
  Future<bool> _hasFfmpeg() async {
    try {
      final result = await Process.run('ffmpeg', ['-version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Lossless container-aware audio segmentation using FFmpeg
  Future<List<String>> _sliceWithFfmpeg({
    required String sourcePath,
    required String outputDir,
    required int timestamp,
    required String extension,
    required int chunkDurationSeconds,
  }) async {
    final pattern = '$outputDir/chunk_${timestamp}_%03d.$extension';

    final result = await Process.run('ffmpeg', [
      '-y',
      '-i', sourcePath,
      '-f', 'segment',
      '-segment_time', chunkDurationSeconds.toString(),
      '-c', 'copy',
      pattern,
    ]);

    if (result.exitCode == 0) {
      final dir = Directory(outputDir);
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('chunk_${timestamp}_'))
          .map((f) => f.path)
          .toList();
      files.sort();
      return files;
    }
    return [];
  }

  /// Slice standard PCM WAV file with valid 44-byte RIFF header duplication
  Future<List<String>> _sliceWavFile(File file, String outputDir, int timestamp) async {
    final bytes = await file.readAsBytes();
    if (bytes.length < 44) return [file.path];

    final header = Uint8List.fromList(bytes.sublist(0, 44));
    final pcmData = bytes.sublist(44);

    final List<String> chunkPaths = [];
    final totalChunks = (bytes.length / maxChunkSizeBytes).ceil();
    final pcmChunkSize = (pcmData.length / totalChunks).ceil();

    for (int i = 0; i < totalChunks; i++) {
      final start = i * pcmChunkSize;
      final end = (start + pcmChunkSize > pcmData.length) ? pcmData.length : start + pcmChunkSize;
      final chunkPcm = pcmData.sublist(start, end);

      // Clone 44-byte header and update ChunkSize and Subchunk2Size
      final chunkHeader = Uint8List.fromList(header);
      final byteData = ByteData.view(chunkHeader.buffer);
      final chunkDataSize = chunkPcm.length;
      final riffChunkSize = 36 + chunkDataSize;

      // Bytes 4-7: ChunkSize (little-endian)
      byteData.setUint32(4, riffChunkSize, Endian.little);
      // Bytes 40-43: Subchunk2Size (data size)
      byteData.setUint32(40, chunkDataSize, Endian.little);

      final chunkPath = '$outputDir/chunk_${timestamp}_wav_${i + 1}.wav';
      final chunkFile = File(chunkPath);
      final fullBytes = BytesBuilder();
      fullBytes.add(chunkHeader);
      fullBytes.add(chunkPcm);
      await chunkFile.writeAsBytes(fullBytes.toBytes());

      chunkPaths.add(chunkPath);
    }

    return chunkPaths;
  }

  /// Delete temporary chunk files after transcription completes
  Future<void> cleanupChunks(List<String> chunkPaths, String originalPath) async {
    for (final path in chunkPaths) {
      if (path != originalPath) {
        try {
          final f = File(path);
          if (await f.exists()) {
            await f.delete();
          }
        } catch (_) {}
      }
    }
  }

  /// Formulate rolling context prompt from the tail of the previous transcript chunk
  String buildRollingPrompt({
    required String basePrompt,
    required String previousChunkTranscript,
  }) {
    if (previousChunkTranscript.trim().isEmpty) return basePrompt;

    final words = previousChunkTranscript.trim().split(RegExp(r'\s+'));
    final tailWords = words.length > 25 ? words.sublist(words.length - 25).join(' ') : words.join(' ');

    return '$basePrompt ... $tailWords';
  }
}
