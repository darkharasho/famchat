import 'package:famchat/voice/waveform.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('levelFromDb', () {
    test('maps -60..0 dBFS linearly to 0..1', () {
      expect(levelFromDb(0), 1);
      expect(levelFromDb(-30), closeTo(0.5, 1e-9));
      expect(levelFromDb(-60), 0);
    });

    test('clamps and handles silence markers', () {
      expect(levelFromDb(-160), 0);
      expect(levelFromDb(6), 1);
      expect(levelFromDb(double.negativeInfinity), 0);
      expect(levelFromDb(double.nan), 0);
    });
  });

  group('downsampleWaveform', () {
    test('empty input gives an empty waveform', () {
      expect(downsampleWaveform(const []), isEmpty);
    });

    test('always gives the bucket count for non-empty input', () {
      expect(downsampleWaveform(const [0.5]), hasLength(waveformBuckets));
      expect(downsampleWaveform(List.filled(10, 0.2)), hasLength(64));
      expect(downsampleWaveform(List.filled(6000, 0.2)), hasLength(64));
    });

    test('each bucket is the peak of its samples, scaled to 0..255', () {
      final levels = [for (var i = 0; i < 128; i++) i.isEven ? 0.0 : 1.0];
      expect(downsampleWaveform(levels), everyElement(255));
      final w = downsampleWaveform([0.0, 0.0, 0.5, 0.0, 1.0, 0.25, 0.0, 0.0], buckets: 4);
      expect(w, [0, 128, 255, 0]);
    });

    test('fewer samples than buckets repeat the nearest sample', () {
      expect(downsampleWaveform([0.0, 1.0], buckets: 4), [0, 0, 255, 255]);
    });

    test('out-of-range levels are clamped', () {
      expect(downsampleWaveform([-1.0, 2.0, double.nan], buckets: 3), [0, 255, 0]);
    });
  });
}
