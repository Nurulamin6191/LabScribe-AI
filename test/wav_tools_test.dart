import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:labscribe/src/features/audio/services/wav_probe.dart';
import 'package:labscribe/src/features/audio/services/wav_writer.dart';
import 'package:labscribe/src/models/meeting_session.dart';

Uint8List _u32(int v) {
  final b = ByteData(4)..setUint32(0, v, Endian.little);
  return b.buffer.asUint8List();
}

Uint8List _fmtChunk() {
  final b = ByteData(24);
  final tag = 'fmt '.codeUnits;
  for (var i = 0; i < 4; i++) {
    b.setUint8(i, tag[i]);
  }
  b.setUint32(4, 16, Endian.little); // PCM fmt chunk size
  b.setUint16(8, 1, Endian.little); // PCM
  b.setUint16(10, 1, Endian.little); // mono
  b.setUint32(12, 16000, Endian.little);
  b.setUint32(16, 32000, Endian.little);
  b.setUint16(20, 2, Endian.little); // block align
  b.setUint16(22, 16, Endian.little);
  return b.buffer.asUint8List();
}

/// Hand-built WAV with an optional LIST/INFO chunk before `fmt` and
/// overridable (possibly wrong) size fields.
Uint8List buildWav({
  int dataLen = 1000,
  bool includeList = false,
  int? riffSizeOverride,
  int? dataSizeOverride,
}) {
  final listBytes =
      includeList ? 'LIST'.codeUnits + _u32(4) + 'INFO'.codeUnits : <int>[];
  final body = <int>[
    ...'WAVE'.codeUnits,
    ...listBytes,
    ..._fmtChunk(),
    ...'data'.codeUnits,
    ..._u32(dataSizeOverride ?? dataLen),
    ...List<int>.filled(dataLen, 7),
  ];
  return Uint8List.fromList([
    ...'RIFF'.codeUnits,
    ..._u32(riffSizeOverride ?? (4 + body.length)),
    ...body,
  ]);
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('labscribe_wav_test');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('WavWriter', () {
    test('streams PCM and finalizes a whisper-ready header', () async {
      final path = '${tmp.path}/out.wav';
      final writer = await WavWriter.open(path);
      await writer.write(Uint8List(16000)); // 0.5 s
      await writer.write(Uint8List(8000)); // 0.25 s
      expect(writer.durationSec, closeTo(0.75, 0.001));
      await writer.close();

      final info = await WavProbe.probe(File(path));
      expect(info, isNotNull);
      expect(info!.sampleRate, 16000);
      expect(info.channels, 1);
      expect(info.bitsPerSample, 16);
      expect(info.isWhisperReady, isTrue);
      expect(info.dataBytes, 24000);
      expect(info.fileBytes, 44 + 24000);
      expect(info.durationSec, closeTo(0.75, 0.001));
    });

    test('close is idempotent and late writes are dropped', () async {
      final path = '${tmp.path}/late.wav';
      final writer = await WavWriter.open(path);
      await writer.close();
      await writer.write(Uint8List(100));
      await writer.close();
      expect(await File(path).length(), 44);
    });

    test('an open-only file reports zero duration, not a crash', () async {
      final path = '${tmp.path}/empty.wav';
      final writer = await WavWriter.open(path);
      await writer.close();
      final info = await WavProbe.probe(File(path));
      expect(info, isNotNull);
      expect(info!.dataBytes, 0);
      expect(info.durationSec, 0);
    });
  });

  group('WavProbe', () {
    test('walks chunks so metadata before data still parses', () async {
      final path = '${tmp.path}/meta.wav';
      final wav = buildWav(includeList: true, dataLen: 4000);
      await File(path).writeAsBytes(wav);

      final info = await WavProbe.probe(File(path));
      expect(info, isNotNull);
      expect(info!.sampleRate, 16000);
      expect(info.channels, 1);
      expect(info.dataBytes, 4000);
      // Data begins past the LIST chunk — a fixed 44-byte assumption would
      // read 4000 + 24 bytes of header instead.
      expect(info.durationSec, closeTo(4000 / 32000, 0.001));
    });

    test('clamps a dangling size field to the bytes actually present',
        () async {
      final path = '${tmp.path}/dangling.wav';
      await File(path)
          .writeAsBytes(buildWav(dataLen: 2000, dataSizeOverride: 0xFFFFFFFF));

      final info = await WavProbe.probe(File(path));
      expect(info, isNotNull);
      expect(info!.dataBytes, 2000);
    });

    test('repairSizes rewrites sizes an interrupted recorder left behind',
        () async {
      final path = '${tmp.path}/broken.wav';
      final file = File(path);
      await file.writeAsBytes(buildWav(
        dataLen: 3000,
        riffSizeOverride: 0,
        dataSizeOverride: 0,
      ));

      expect(await WavProbe.repairSizes(file), isTrue);

      final bytes = await file.readAsBytes();
      final view = ByteData.sublistView(bytes);
      expect(view.getUint32(4, Endian.little), bytes.length - 8);
      // `data` chunk header sits at offset 36 in the list-free layout.
      expect(view.getUint32(40, Endian.little), 3000);
      expect(await WavProbe.repairSizes(file), isFalse); // already correct

      final info = await WavProbe.probe(file);
      expect(info!.isWhisperReady, isTrue);
      expect(info.durationSec, closeTo(3000 / 32000, 0.001));
    });

    test('rejects files that are not RIFF/WAVE', () async {
      final path = '${tmp.path}/fake.wav';
      await File(path).writeAsBytes(List<int>.filled(64, 1));
      expect(await WavProbe.probe(File(path)), isNull);
      expect(await WavProbe.repairSizes(File(path)), isFalse);
      expect(await WavProbe.peakAmplitude(File(path)), 0);
    });

    test('reports the true data offset when metadata precedes data', () async {
      final path = '${tmp.path}/meta_offset.wav';
      await File(path).writeAsBytes(buildWav(includeList: true, dataLen: 100));
      final info = await WavProbe.probe(File(path));
      expect(info!.dataOffset, 56);
    });

    test('peakAmplitude separates real signal from digital silence',
        () async {
      // Digital silence: a healthy-looking file with no input behind it.
      final silentPath = '${tmp.path}/silent.wav';
      final silent = await WavWriter.open(silentPath);
      await silent.write(Uint8List(32000));
      await silent.close();
      expect(await WavProbe.peakAmplitude(File(silentPath)), 0);

      // A square wave at ~24% full scale must be reported as such.
      final signalPath = '${tmp.path}/signal.wav';
      final signal = await WavWriter.open(signalPath);
      final samples = Int16List(1600);
      for (var i = 0; i < samples.length; i++) {
        samples[i] = i.isEven ? 8000 : -8000;
      }
      await signal.write(Uint8List.view(samples.buffer));
      await signal.close();
      expect(await WavProbe.peakAmplitude(File(signalPath)),
          closeTo(8000 / 32768, 0.01));
    });
  });

  group('SessionKind', () {
    test('round-trips persisted names', () {
      expect(SessionKind.fromName('journalClub'), SessionKind.journalClub);
      expect(SessionKind.fromName('seminar'), SessionKind.seminar);
      expect(SessionKind.fromName('lecture'), SessionKind.lecture);
      expect(SessionKind.fromName('meeting'), SessionKind.meeting);
    });

    test('unknown or missing values fall back to meeting', () {
      expect(SessionKind.fromName(null), SessionKind.meeting);
      expect(SessionKind.fromName('bogus'), SessionKind.meeting);
    });

    test('labels are human-readable', () {
      expect(SessionKind.journalClub.label, 'Journal Club');
      expect(SessionKind.meeting.label, 'Lab Meeting');
    });

    test('MeetingSession defaults to a plain meeting', () {
      final s = MeetingSession(title: 't', createdAt: DateTime.now());
      expect(s.kind, SessionKind.meeting);
      s.kind = SessionKind.seminar;
      expect(s.kind, SessionKind.seminar);
    });
  });

  group('TranscriptSegment', () {
    test('json round-trips and converts to seconds', () {
      const seg = TranscriptSegment(
        startMs: 1500,
        endMs: 4900,
        text: 'the control looked fine',
      );
      expect(seg.startSeconds, 2);
      expect(seg.endSeconds, 5);

      final restored = TranscriptSegment.fromJson(seg.toJson());
      expect(restored.startMs, 1500);
      expect(restored.endMs, 4900);
      expect(restored.text, 'the control looked fine');
    });

    test('tolerates missing fields', () {
      final seg = TranscriptSegment.fromJson(const {});
      expect(seg.startMs, 0);
      expect(seg.endMs, 0);
      expect(seg.text, '');
    });
  });
}
