import 'dart:convert';

import 'package:auris/core/audiometry/audiometry.dart';
import 'package:auris/core/audiometry/calibration.dart';
import 'package:auris/data/calibration_history.dart';
import 'package:auris/data/local_database.dart';
import 'package:auris/report/calibration_report.dart';
import 'package:auris/report/pdf_report.dart';
import 'package:flutter_test/flutter_test.dart';

final _at = DateTime(2026, 10, 22, 10, 30);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('per-ear calibration model', () {
    test('a profile saved before per-ear calibration applies to both ears', () {
      final legacy = CalibrationProfile.fromJson({
        'fullScaleOutputDbSpl': 100.0,
        'globalOffsetDb': 20.0,
        'method': 'biological',
        'transducerName': 'HD 280',
      });
      for (final ear in Ear.values) {
        expect(legacy.ear(ear).method, CalibrationMethod.biological);
        expect(legacy.ear(ear).offsetDb, 0.0);
        // Exactly what the profile played before per-ear calibration existed.
        expect(legacy.amplitudeFor(1000, 30, ear: ear),
            legacy.amplitudeFor(1000, 30));
      }
      expect(legacy.method, CalibrationMethod.biological);
    });

    test('a measured ear changes only that ear', () {
      const base = CalibrationProfile();
      final p = base.withMeasuredEar(Ear.left,
          method: CalibrationMethod.soundLevelMeter, correctionDb: 6, at: _at);

      expect(p.ear(Ear.left).offsetDb, 6);
      expect(p.ear(Ear.left).method, CalibrationMethod.soundLevelMeter);
      expect(p.ear(Ear.right).offsetDb, 0);
      expect(p.ear(Ear.right).method, CalibrationMethod.none,
          reason: 'the other ear is kept as it was');
      // +6 dB is a factor of ~2 in amplitude, on the left only.
      expect(
          p.amplitudeFor(1000, 20, ear: Ear.left) /
              p.amplitudeFor(1000, 20, ear: Ear.right),
          closeTo(1.995, 0.01));
    });

    test('corrections stack on what the ear already had', () {
      final once = const CalibrationProfile().withMeasuredEar(Ear.right,
          method: CalibrationMethod.biological, correctionDb: 10, at: _at);
      final twice = once.withMeasuredEar(Ear.right,
          method: CalibrationMethod.biological, correctionDb: -4, at: _at);
      expect(twice.ear(Ear.right).offsetDb, 6);
    });

    test('copying marks the other ear as copied, with the same correction', () {
      final p = const CalibrationProfile()
          .withMeasuredEar(Ear.right,
              method: CalibrationMethod.biological, correctionDb: 12, at: _at)
          .copyEarToOther(Ear.right, at: _at);

      expect(p.ear(Ear.left).offsetDb, 12);
      expect(p.ear(Ear.left).method, CalibrationMethod.biological);
      expect(p.ear(Ear.left).isCopied, isTrue);
      expect(p.ear(Ear.right).isCopied, isFalse);
    });

    test('keeping the other ear preserves its earlier calibration', () {
      final both = const CalibrationProfile()
          .withMeasuredEar(Ear.right,
              method: CalibrationMethod.soundLevelMeter,
              correctionDb: 3,
              at: _at)
          .withMeasuredEar(Ear.left,
              method: CalibrationMethod.soundLevelMeter,
              correctionDb: -2,
              at: _at);
      final rightAgain = both.withMeasuredEar(Ear.right,
          method: CalibrationMethod.soundLevelMeter, correctionDb: 1, at: _at);

      expect(rightAgain.ear(Ear.left).offsetDb, -2);
      expect(rightAgain.ear(Ear.left).method,
          CalibrationMethod.soundLevelMeter);
    });

    test('the profile reports its weakest ear', () {
      final mixed = const CalibrationProfile()
          .withMeasuredEar(Ear.right,
              method: CalibrationMethod.soundLevelMeter,
              correctionDb: 0,
              at: _at)
          .withMeasuredEar(Ear.left,
              method: CalibrationMethod.biological, correctionDb: 0, at: _at);
      expect(mixed.method, CalibrationMethod.biological);
      expect(mixed.isCalibrated, isFalse);
      expect(mixed.usesHumanListener, isTrue);

      final oneEar = const CalibrationProfile().withMeasuredEar(Ear.right,
          method: CalibrationMethod.soundLevelMeter, correctionDb: 0, at: _at);
      expect(oneEar.method, CalibrationMethod.none);
      expect(oneEar.hasAnyCalibration, isTrue,
          reason: 'one calibrated ear still counts as some calibration');
    });

    test('imbalance is the difference between the ears', () {
      final p = const CalibrationProfile()
          .withMeasuredEar(Ear.right,
              method: CalibrationMethod.biological, correctionDb: 4, at: _at)
          .withMeasuredEar(Ear.left,
              method: CalibrationMethod.biological, correctionDb: 16, at: _at);
      expect(p.earImbalanceDb, 12);
    });

    test('per-ear calibration survives a round trip', () {
      final original = const CalibrationProfile(transducerName: 'HD 280')
          .withMeasuredEar(Ear.right,
              method: CalibrationMethod.biological, correctionDb: 8, at: _at)
          .copyEarToOther(Ear.right, at: _at);
      final restored = CalibrationProfile.decode(original.encode());

      for (final ear in Ear.values) {
        expect(restored.ear(ear).method, original.ear(ear).method);
        expect(restored.ear(ear).offsetDb, original.ear(ear).offsetDb);
        expect(restored.ear(ear).isCopied, original.ear(ear).isCopied);
        expect(restored.ear(ear).calibratedAt, _at);
      }
      expect(restored.transducerName, 'HD 280');
    });

    test('the stored profile-level method is never stronger than an ear', () {
      // An older build reads only `method`; it must not see "meter" when one
      // ear is uncalibrated.
      final oneEar = const CalibrationProfile().withMeasuredEar(Ear.right,
          method: CalibrationMethod.soundLevelMeter, correctionDb: 0, at: _at);
      final json = jsonDecode(oneEar.encode()) as Map<String, dynamic>;
      expect(json['method'], 'none');
      expect(json['isCalibrated'], isFalse);
    });
  });

  group('calibration history', () {
    late LocalDatabase database;
    late CalibrationHistory history;

    setUp(() async {
      database = await LocalDatabase.openInMemory();
      history = CalibrationHistory(database);
    });

    tearDown(() => database.close());

    Future<CalibrationEvent> recordOne(DateTime at) {
      final profile = const CalibrationProfile(transducerName: 'HD 280')
          .withMeasuredEar(Ear.right,
              method: CalibrationMethod.biological, correctionDb: 9, at: at)
          .copyEarToOther(Ear.right, at: at);
      return history.record(
        performedBy: 'Dr. Example',
        method: CalibrationMethod.biological,
        earChoice: CalibrationEarChoice.right,
        right: EarRecord(
          action: EarAction.measured,
          correctionDb: 9,
          methodAfter: profile.ear(Ear.right).method,
          offsetAfterDb: profile.ear(Ear.right).offsetDb,
        ),
        left: EarRecord(
          action: EarAction.copied,
          methodAfter: profile.ear(Ear.left).method,
          offsetAfterDb: profile.ear(Ear.left).offsetDb,
        ),
        profile: profile,
        at: at,
      );
    }

    test('starts empty', () async {
      expect(await history.all(), isEmpty);
    });

    test('records calibrations and lists them newest first', () async {
      await recordOne(DateTime(2026, 9, 1));
      await recordOne(DateTime(2026, 10, 22));

      final all = await history.all();
      expect(all.length, 2);
      expect(all.first.performedAt, DateTime(2026, 10, 22));
      expect(all.first.earChoice, CalibrationEarChoice.right);
      expect(all.first.right.action, EarAction.measured);
      expect(all.first.right.correctionDb, 9);
      expect(all.first.left.action, EarAction.copied);
      expect(all.first.left.correctionDb, isNull);
      expect(all.first.profile.ear(Ear.left).isCopied, isTrue);
      expect(all.first.performedBy, 'Dr. Example');
    });

    test('a calibration record prints as a valid PDF', () async {
      final event = await recordOne(_at);
      final bytes = await CalibrationRecordReport(
        event: event,
        clinic: const ClinicDetails(name: 'Test Clinic'),
      ).build();

      expect(bytes.length, greaterThan(3000));
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });

    test('the record file name carries the date and time', () async {
      final event = await recordOne(_at);
      final report = CalibrationRecordReport(
        event: event,
        clinic: const ClinicDetails(name: 'Test Clinic'),
      );
      expect(report.fileName, 'Auris_calibration_2026-10-22_1030.pdf');
    });
  });
}
