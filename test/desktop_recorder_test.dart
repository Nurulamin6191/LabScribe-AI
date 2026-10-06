import 'package:flutter_test/flutter_test.dart';
import 'package:labscribe/src/features/audio/services/desktop_recorder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DesktopRecorder device enumeration', () {
    test('always offers a usable default capture device', () async {
      // On machines where Pulse exposes no microphone (headless sessions,
      // silent monitor defaults), the list must still fall back to ALSA
      // hardware — never come back empty.
      final devices = await DesktopRecorder.listInputDevices();
      expect(devices, isNotEmpty);
      expect(devices.first.id, 'default');
      expect(devices.first.label, isNotEmpty);
    });

    test('entries expose the ids FFmpeg can consume', () async {
      final devices = await DesktopRecorder.listInputDevices();
      for (final d in devices) {
        // Either a Pulse source name / 'default', or an ALSA hw id.
        expect(d.id, isNotEmpty);
        expect(
          d.id == 'default' ||
              RegExp(r'^(plughw|hw):').hasMatch(d.id) ||
              d.id.contains('.'),
          isTrue,
          reason: 'unexpected capture id format: ${d.id}',
        );
      }
    });

    test('backend availability probes return without throwing', () async {
      expect(await DesktopRecorder.isAvailable(), isA<bool>());
      expect(await DesktopRecorder.isFmediaAvailable(), isA<bool>());
    });
  });
}
