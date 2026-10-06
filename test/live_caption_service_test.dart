import 'package:flutter_test/flutter_test.dart';
import 'package:labscribe/src/features/audio/services/live_caption_service.dart';

void main() {
  group('LiveCaptionService.stop()', () {
    test('without an active session returns null instead of throwing', () async {
      // Regression: a second Stop tap used to hit
      // StateError('Live captions are not running') because the view's
      // re-entry flag cleared only after the slow finalize await.
      final service = LiveCaptionService();
      expect(await service.stop(), isNull);
      expect(await service.stop(), isNull); // still a no-op, never throws
      expect(service.isActive, isFalse);
    });

    test('stop() then dispose() cleans up without error', () async {
      final service = LiveCaptionService();
      await service.stop();
      await service.dispose();
      await service.dispose(); // dispose is safe to repeat
      expect(service.isActive, isFalse);
    });
  });
}
