import 'package:auris/core/audiometry/calibration.dart';
import 'package:auris/core/audiometry/progress_estimator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('progress', () {
    test('starts at zero and reaches one', () {
      final e = TestProgressEstimator(totalThresholds: 4);
      expect(e.progress, 0.0);
      expect(e.completedCount, 0);
      expect(e.remainingCount, 4);

      for (var i = 0; i < 4; i++) {
        e.recordThreshold(const Duration(seconds: 20));
      }
      expect(e.progress, 1.0);
      expect(e.isComplete, isTrue);
      expect(e.estimatedRemaining, Duration.zero);
    });

    test('progress never exceeds one even if over-recorded', () {
      final e = TestProgressEstimator(totalThresholds: 2);
      for (var i = 0; i < 5; i++) {
        e.recordThreshold(const Duration(seconds: 10));
      }
      expect(e.progress, 1.0);
      expect(e.estimatedRemaining, Duration.zero);
    });

    test('ignores negative durations', () {
      final e = TestProgressEstimator(totalThresholds: 3);
      e.recordThreshold(const Duration(seconds: -5));
      expect(e.completedCount, 0);
    });
  });

  group('time estimate', () {
    test('uses the prior before anything has finished', () {
      final e = TestProgressEstimator(
        totalThresholds: 12,
        priorPerThreshold: const Duration(seconds: 30),
      );
      expect(e.estimatedRemaining, const Duration(seconds: 360));
    });

    test('learns from the patient actual pace', () {
      final e = TestProgressEstimator(
        totalThresholds: 12,
        priorPerThreshold: const Duration(seconds: 30),
      );

      // This patient is quick - 10 s per threshold, not 30.
      for (var i = 0; i < 3; i++) {
        e.recordThreshold(const Duration(seconds: 10));
      }

      expect(e.pacePerThreshold, const Duration(seconds: 10));
      expect(e.estimatedRemaining, const Duration(seconds: 90)); // 9 left
    });

    test('weights recent thresholds, so a slow start stops dominating', () {
      final e = TestProgressEstimator(totalThresholds: 10);

      // Slow while the patient works out the task...
      e.recordThreshold(const Duration(seconds: 60));
      e.recordThreshold(const Duration(seconds: 60));
      // ...then settles.
      e.recordThreshold(const Duration(seconds: 10));
      e.recordThreshold(const Duration(seconds: 10));
      e.recordThreshold(const Duration(seconds: 10));

      expect(e.pacePerThreshold, const Duration(seconds: 10),
          reason: 'the last three are what predict the rest');
    });
  });

  group('human phrasing', () {
    TestProgressEstimator withPace(Duration pace, {int total = 12, int done = 1}) {
      final e = TestProgressEstimator(totalThresholds: total);
      for (var i = 0; i < done; i++) {
        e.recordThreshold(pace);
      }
      return e;
    }

    test('says almost done near the end', () {
      // 1 threshold left at 20 s.
      final e = withPace(const Duration(seconds: 20), total: 2, done: 1);
      expect(e.remainingLabel, 'Almost done');
    });

    test('reads about a minute in the middle range', () {
      final e = withPace(const Duration(seconds: 30), total: 3, done: 1);
      expect(e.remainingLabel, 'About a minute left');
    });

    test('gives exact minutes up to five', () {
      // 4 left at 45 s = 180 s = 3 minutes.
      final e = withPace(const Duration(seconds: 45), total: 5, done: 1);
      expect(e.remainingLabel, 'About 3 minutes left');
    });

    test('rounds to five minutes beyond that', () {
      // 11 left at 60 s = 11 minutes, reported as 10.
      final e = withPace(const Duration(seconds: 60), total: 12, done: 1);
      expect(e.remainingLabel, 'About 10 minutes left');
    });

    test('never shows a countdown of raw seconds', () {
      // The label must stay coarse; a ticking clock makes waiting feel longer.
      for (final seconds in [31, 45, 61, 89, 91, 200, 700]) {
        final e = withPace(Duration(seconds: seconds), total: 2, done: 1);
        expect(e.remainingLabel, isNot(contains('second')));
      }
    });

    test('says finishing up once complete', () {
      final e = withPace(const Duration(seconds: 20), total: 1, done: 1);
      expect(e.remainingLabel, 'Finishing up');
    });
  });

  group('calibration methods', () {
    test('only a meter measurement counts as calibrated', () {
      const meter =
          CalibrationProfile(method: CalibrationMethod.soundLevelMeter);
      const bio = CalibrationProfile(method: CalibrationMethod.biological);
      const none = CalibrationProfile();

      expect(meter.isCalibrated, isTrue);
      expect(bio.isCalibrated, isFalse,
          reason: 'a biological check must never claim meter accuracy');
      expect(none.isCalibrated, isFalse);

      expect(meter.hasAnyCalibration, isTrue);
      expect(bio.hasAnyCalibration, isTrue);
      expect(none.hasAnyCalibration, isFalse);
    });

    test('an unknown method id falls back to uncalibrated', () {
      expect(CalibrationMethod.fromId('magic'), CalibrationMethod.none);
      expect(CalibrationMethod.fromId(null), CalibrationMethod.none);
      expect(CalibrationMethod.fromId('biological'),
          CalibrationMethod.biological);
    });

    test('survives a round trip', () {
      const original = CalibrationProfile(
        method: CalibrationMethod.biological,
        globalOffsetDb: 27,
        transducerName: 'HD 280',
      );
      final restored = CalibrationProfile.decode(original.encode());

      expect(restored.method, CalibrationMethod.biological);
      expect(restored.globalOffsetDb, 27);
      expect(restored.isCalibrated, isFalse);
    });

    test('reads a profile written before methods existed', () {
      // Older builds stored only the boolean, and could only ever have meant a
      // meter measurement.
      final legacyCalibrated = CalibrationProfile.fromJson({
        'fullScaleOutputDbSpl': 94.0,
        'globalOffsetDb': 0.0,
        'isCalibrated': true,
        'transducerName': 'TDH-39P',
      });
      expect(legacyCalibrated.method, CalibrationMethod.soundLevelMeter);
      expect(legacyCalibrated.isCalibrated, isTrue);

      final legacyUncalibrated = CalibrationProfile.fromJson({
        'isCalibrated': false,
      });
      expect(legacyUncalibrated.method, CalibrationMethod.none);
    });

    test('a biological correction shifts output by the measured amount', () {
      // A normal-hearing listener measuring 30 dB HL means the chain is 30 dB
      // too quiet, so adding 30 dB of offset should make the same request 30 dB
      // louder - a factor of ~31.6 in amplitude.
      const before = CalibrationProfile();
      final after = before.copyWith(
        globalOffsetDb: before.globalOffsetDb + 30,
        method: CalibrationMethod.biological,
      );

      expect(after.targetDbSpl(1000, 40), before.targetDbSpl(1000, 40) + 30);
      expect(after.amplitudeFor(1000, 20) / before.amplitudeFor(1000, 20),
          closeTo(31.62, 0.05));
    });
  });
}
