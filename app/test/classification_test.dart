import 'package:auris/core/audiometry/audiometry.dart';
import 'package:auris/core/audiometry/calibration.dart';
import 'package:auris/core/audiometry/classification.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('degree of loss boundaries', () {
    // Boundary values matter clinically: 25 vs 26 dB is the line between
    // "normal" and a diagnosis.
    const cases = <(double, HearingLossDegree)>[
      (-10.0, HearingLossDegree.normal),
      (0.0, HearingLossDegree.normal),
      (25.0, HearingLossDegree.normal),
      (25.1, HearingLossDegree.mild),
      (40.0, HearingLossDegree.mild),
      (40.1, HearingLossDegree.moderate),
      (55.0, HearingLossDegree.moderate),
      (55.1, HearingLossDegree.moderatelySevere),
      (70.0, HearingLossDegree.moderatelySevere),
      (70.1, HearingLossDegree.severe),
      (90.0, HearingLossDegree.severe),
      (90.1, HearingLossDegree.profound),
      (120.0, HearingLossDegree.profound),
    ];

    for (final (pta, expected) in cases) {
      test('$pta dB HL is ${expected.label}', () {
        expect(HearingLossDegree.fromPta(pta), expected);
      });
    }
  });

  group('pure-tone average', () {
    test('averages only the speech frequencies', () {
      final pta = PureToneAverage.compute({
        250: 100, // deliberately extreme - must be excluded
        500: 30,
        1000: 40,
        2000: 50,
        4000: 100,
        8000: 100,
      })!;

      expect(pta.frequenciesUsed, kPtaFrequenciesHz);
      expect(pta.valueDbHl, 40.0); // (30 + 40 + 50) / 3
      expect(pta.degree, HearingLossDegree.mild);
      expect(pta.isLowerBound, isFalse);
    });

    test('treats a no-response as a lower bound at maximum output', () {
      final pta = PureToneAverage.compute({
        500: 60,
        1000: 70,
        2000: null, // no response at max
      })!;

      expect(pta.isLowerBound, isTrue);
      expect(pta.valueDbHl, (60 + 70 + kMaxLevelDbHl) / 3);
      expect(pta.displayValue, startsWith('≥'));
    });

    test('averages over whatever speech frequencies were tested', () {
      final pta = PureToneAverage.compute({500: 20, 1000: 30})!;
      expect(pta.frequenciesUsed, [500, 1000]);
      expect(pta.valueDbHl, 25.0);
    });

    test('returns null when no speech frequency was tested', () {
      expect(PureToneAverage.compute({4000: 30, 8000: 40}), isNull);
      expect(PureToneAverage.compute({}), isNull);
    });
  });

  group('calibration', () {
    const profile = CalibrationProfile();

    test('uses the tabulated RETSPL at standard frequencies', () {
      expect(CalibrationProfile.retsplFor(1000), 7.0);
      expect(CalibrationProfile.retsplFor(250), 25.5);
      expect(CalibrationProfile.retsplFor(8000), 13.0);
    });

    test('interpolates between tabulated frequencies', () {
      // Midway between 1000 Hz (7.0) and 1500 Hz (6.5).
      expect(CalibrationProfile.retsplFor(1250), closeTo(6.75, 1e-9));
    });

    test('clamps outside the tabulated range', () {
      expect(CalibrationProfile.retsplFor(50), 45.0);
      expect(CalibrationProfile.retsplFor(16000), 13.0);
    });

    test('equal dB HL maps to different SPL across frequency', () {
      // The whole point of the RETSPL correction: 40 dB HL is a louder sound at
      // 250 Hz than at 1 kHz, because the ear is less sensitive down there.
      final low = profile.targetDbSpl(250, 40);
      final mid = profile.targetDbSpl(1000, 40);
      expect(low, greaterThan(mid));
      expect(low - mid, closeTo(25.5 - 7.0, 1e-9));
    });

    test('amplitude increases monotonically with hearing level', () {
      var previous = -1.0;
      for (var db = -10; db <= 90; db += 5) {
        final a = profile.amplitudeFor(1000, db);
        expect(a, greaterThan(previous));
        expect(a, inInclusiveRange(0.0, 1.0));
        previous = a;
      }
    });

    test('a 20 dB rise in level is a factor of 10 in amplitude', () {
      final a40 = profile.amplitudeFor(1000, 40);
      final a60 = profile.amplitudeFor(1000, 60);
      expect(a60 / a40, closeTo(10.0, 1e-6));
    });

    test('flags levels it cannot produce without clipping', () {
      // Full scale is 100 dB SPL by default; 90 dB HL at 250 Hz needs
      // 90 + 25.5 = 115.5 dB SPL, which the chain cannot deliver.
      expect(profile.canRepresent(250, 90), isFalse);
      expect(profile.amplitudeFor(250, 90), 1.0);
      expect(profile.canRepresent(1000, 40), isTrue);
    });

    test('offsets shift the required output', () {
      final shifted = profile.copyWith(globalOffsetDb: 10);
      expect(shifted.targetDbSpl(1000, 40), profile.targetDbSpl(1000, 40) + 10);

      final perFreq = profile.copyWith(perFrequencyOffsetDb: {4000: -6});
      expect(perFreq.targetDbSpl(4000, 40), profile.targetDbSpl(4000, 40) - 6);
      expect(perFreq.targetDbSpl(1000, 40), profile.targetDbSpl(1000, 40));
    });

    test('survives a serialisation round trip', () {
      const original = CalibrationProfile(
        fullScaleOutputDbSpl: 94.5,
        globalOffsetDb: -3.5,
        perFrequencyOffsetDb: {500: 2.0, 4000: -1.5},
        method: CalibrationMethod.soundLevelMeter,
        transducerName: 'TDH-39P',
      );
      final restored = CalibrationProfile.decode(original.encode());

      expect(restored.fullScaleOutputDbSpl, 94.5);
      expect(restored.globalOffsetDb, -3.5);
      expect(restored.perFrequencyOffsetDb, {500: 2.0, 4000: -1.5});
      expect(restored.isCalibrated, isTrue);
      expect(restored.transducerName, 'TDH-39P');
    });

    test('defaults to uncalibrated', () {
      expect(const CalibrationProfile().isCalibrated, isFalse);
    });
  });
}
