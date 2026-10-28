import 'dart:convert';

import 'package:auris/core/audiometry/audiometry.dart';
import 'package:auris/core/audiometry/calibration.dart';
import 'package:auris/data/models/patient.dart';
import 'package:auris/data/models/test_protocol.dart';
import 'package:auris/data/models/test_session.dart';
import 'package:auris/report/pdf_report.dart';
import 'package:flutter_test/flutter_test.dart';

Patient buildPatient() => Patient(
      id: 'p1',
      fullName: 'Test Patient',
      ageYears: 54,
      sex: 'Male',
      clinicRef: 'MRN-4471',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

TestSession buildSession({
  bool calibrated = true,
  int catchTrials = 0,
  int falsePositives = 0,
  List<ThresholdPoint>? points,
}) =>
    TestSession(
      id: 's1',
      patientId: 'p1',
      testedAt: DateTime(2026, 3, 14, 11, 20),
      clinicianName: 'Dr. Example',
      isComplete: true,
      calibration: CalibrationProfile(
        method: calibrated ? CalibrationMethod.soundLevelMeter : CalibrationMethod.none,
        transducerName: calibrated ? 'TDH-39P' : 'Uncalibrated headphones',
      ),
      points: points ??
          [
            for (final hz in kAudiometricFrequenciesHz) ...[
              ThresholdPoint(
                ear: Ear.right,
                frequencyHz: hz,
                thresholdDbHl: hz >= 4000 ? 55 : 20,
                noResponse: false,
                catchTrials: catchTrials,
                falsePositives: falsePositives,
              ),
              ThresholdPoint(
                ear: Ear.left,
                frequencyHz: hz,
                thresholdDbHl: hz == 8000 ? null : 25,
                noResponse: hz == 8000,
              ),
            ],
          ],
    );

const clinic = ClinicDetails(
  name: 'Test ENT Clinic',
  address: '1 Example Road',
  phone: '+91 00000 00000',
);

void main() {
  // The report rasterises the audiogram through dart:ui, so it needs a
  // initialised binding even though it renders nothing on screen.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PDF generation', () {
    test('produces a valid, non-trivial PDF document', () async {
      final bytes = await AudiogramReport(
        patient: buildPatient(),
        session: buildSession(),
        clinic: clinic,
      ).build();

      expect(bytes.length, greaterThan(5000));
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-',
          reason: 'must be a real PDF header');
      expect(latin1.decode(bytes.sublist(bytes.length - 6)).trim(),
          endsWith('%%EOF'));
    });

    // Note on what is *not* asserted here: with an embedded subset font, page
    // text is encoded as glyph indices rather than readable characters, so the
    // body copy cannot be grepped out of the byte stream. Document metadata is
    // still written as PDF strings, so that is checked instead; the wording of
    // the report body is covered by the widget-level data it is built from.
    test('writes document metadata', () async {
      final bytes = await AudiogramReport(
        patient: buildPatient(),
        session: buildSession(),
        clinic: clinic,
      ).build(compress: false);
      final text = latin1.decode(bytes, allowInvalid: true);

      expect(text, contains('/Title'));
      expect(text, contains('/Author'));
      expect(text, contains('/Creator'));
      expect(text, contains('Auris'), reason: 'creator is written as ASCII');
    });

    test('an uncalibrated session still renders a full report', () async {
      final calibrated = await AudiogramReport(
        patient: buildPatient(),
        session: buildSession(),
        clinic: clinic,
      ).build();
      final uncalibrated = await AudiogramReport(
        patient: buildPatient(),
        session: buildSession(calibrated: false),
        clinic: clinic,
      ).build();

      // Both produce a complete document; the uncalibrated one carries the
      // longer screening-only disclaimer, so it is never the smaller of the two.
      expect(uncalibrated.length, greaterThan(5000));
      expect(calibrated.length, greaterThan(5000));
    });

    test('embeds a Unicode-capable font', () async {
      // Guards the defect this was written to fix: the pdf package's default
      // Helvetica silently drops "≥", en dashes and non-Latin names.
      final bytes = await AudiogramReport(
        patient: buildPatient(),
        session: buildSession(),
        clinic: clinic,
      ).build(compress: false);
      final text = latin1.decode(bytes, allowInvalid: true);

      expect(text, contains('Roboto'));
      expect(text.contains('Helvetica'), isFalse,
          reason: 'the Latin-1-only default font must not be used');
    });

    test('generates for an uncalibrated session too', () async {
      final bytes = await AudiogramReport(
        patient: buildPatient(),
        session: buildSession(calibrated: false),
        clinic: clinic,
      ).build();

      expect(bytes.length, greaterThan(5000));
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });

    test('generates with a baseline comparison overlay', () async {
      final bytes = await AudiogramReport(
        patient: buildPatient(),
        session: buildSession(),
        clinic: clinic,
        baseline: buildSession(),
      ).build();

      expect(bytes.length, greaterThan(5000));
    });

    test('generates when only one ear was tested', () async {
      final bytes = await AudiogramReport(
        patient: buildPatient(),
        session: buildSession(points: const [
          ThresholdPoint(
              ear: Ear.right,
              frequencyHz: 1000,
              thresholdDbHl: 15,
              noResponse: false),
        ]),
        clinic: clinic,
      ).build();

      expect(bytes.length, greaterThan(5000));
    });

    test('generates when every point is a no-response', () async {
      // A profoundly deaf patient must still produce a report, not a crash.
      final bytes = await AudiogramReport(
        patient: buildPatient(),
        session: buildSession(points: [
          for (final hz in kAudiometricFrequenciesHz)
            ThresholdPoint(
                ear: Ear.right,
                frequencyHz: hz,
                thresholdDbHl: null,
                noResponse: true),
        ]),
        clinic: clinic,
      ).build();

      expect(bytes.length, greaterThan(5000));
    });

    test('generates with no thresholds at all', () async {
      final bytes = await AudiogramReport(
        patient: buildPatient(),
        session: buildSession(points: const []),
        clinic: clinic,
      ).build();

      expect(bytes.length, greaterThan(5000));
    });

    test('generates with a full protocol record and every kind of result',
        () async {
      final session = buildSession(points: const [
        ThresholdPoint(
            ear: Ear.right,
            frequencyHz: 250,
            thresholdDbHl: -10,
            noResponse: false,
            qualifier: ThresholdQualifier.atFloor),
        ThresholdPoint(
            ear: Ear.right,
            frequencyHz: 1000,
            thresholdDbHl: null,
            noResponse: false,
            qualifier: ThresholdQualifier.notEstablished),
        ThresholdPoint(
            ear: Ear.right, frequencyHz: 1500, thresholdDbHl: 10, noResponse: false),
        ThresholdPoint(
            ear: Ear.left, frequencyHz: 1500, thresholdDbHl: 60, noResponse: false),
        ThresholdPoint(
            ear: Ear.left, frequencyHz: 4000, thresholdDbHl: null, noResponse: true),
      ]).copyWith(
        protocol: const TestProtocolRecord(
          earOrder: [Ear.right, Ear.left],
          reasonForTest: 'Referred by GP for difficulty hearing in noise, '
              'with a long explanation that has to wrap across the line',
          examinerCredentials: 'MS (ENT)',
          checklist: PreTestChecklist(
            loudNoiseLast24h: true,
            tinnitus: false,
            hearingAidsRemoved: true,
            phonesSilenced: true,
            quietRoom: true,
          ),
          familiarisation: FamiliarisationOutcome(
            heard: true,
            levelDbHl: 50,
            onsetOffsetMatched: false,
            reinstructed: true,
          ),
          retests: [
            RetestRecord(
              ear: Ear.right,
              frequencyHz: 1000,
              firstDbHl: 30,
              retestDbHl: null,
              withinTolerance: false,
            ),
          ],
          interoctaveAdded: [FrequencyRef(Ear.left, 1500)],
          skipped: [FrequencyRef(Ear.left, 6000)],
          breaksOffered: 1,
          pressesBetweenTones: {Ear.right: 9},
          testDuration: Duration(minutes: 23),
        ),
      );
      expect(session.maskingFlags, isNotEmpty);
      expect(session.reliabilityConcerns, isNotEmpty);

      final patient = Patient(
        id: 'p1',
        fullName: 'Test Patient',
        ageYears: 54,
        sex: 'Male',
        dateOfBirth: DateTime(1972, 5, 9),
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );
      final bytes = await AudiogramReport(
        patient: patient,
        session: session,
        clinic: clinic,
      ).build();

      expect(bytes.length, greaterThan(5000));
    });

    test('generates with a minimal clinic block', () async {
      final bytes = await AudiogramReport(
        patient: buildPatient(),
        session: buildSession(),
        clinic: const ClinicDetails(name: 'Solo Practice'),
      ).build();

      expect(bytes.length, greaterThan(5000));
    });
  });

  group('reliability reporting', () {
    test('a session with many false positives is flagged unreliable', () {
      final session = buildSession(catchTrials: 4, falsePositives: 3);
      expect(session.totalCatchTrials, greaterThan(0));
      expect(session.isReliable, isFalse);
    });

    test('a clean session is reliable', () {
      final session = buildSession(catchTrials: 4, falsePositives: 0);
      expect(session.falsePositiveRate, 0.0);
      expect(session.isReliable, isTrue);
    });

    test('no catch trials means no reliability figure', () {
      expect(buildSession().falsePositiveRate, isNull);
      expect(buildSession().isReliable, isTrue);
    });
  });
}
