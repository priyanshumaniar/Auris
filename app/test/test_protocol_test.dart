import 'dart:convert';

import 'package:auris/core/audiometry/audiometry.dart';
import 'package:auris/core/audiometry/calibration.dart';
import 'package:auris/data/models/test_protocol.dart';
import 'package:auris/data/models/test_session.dart';
import 'package:flutter_test/flutter_test.dart';

ThresholdPoint point(
  Ear ear,
  int hz,
  int? db, {
  bool noResponse = false,
  ThresholdQualifier qualifier = ThresholdQualifier.measured,
  int tones = 10,
}) => ThresholdPoint(
  ear: ear,
  frequencyHz: hz,
  thresholdDbHl: db,
  noResponse: noResponse,
  qualifier: qualifier,
  tonesPresented: tones,
);

TestSession session(
  List<ThresholdPoint> points, {
  TestProtocolRecord? protocol,
}) => TestSession(
  id: 's1',
  patientId: 'p1',
  testedAt: DateTime(2026, 10, 22, 10, 37),
  clinicianName: 'Dr. Example',
  points: points,
  calibration: const CalibrationProfile(),
  isComplete: true,
  protocol: protocol,
);

const fullProtocol = TestProtocolRecord(
  earOrder: [Ear.left, Ear.right],
  transducerType: TransducerType.insertEarphones,
  reasonForTest: 'Referred for hearing difficulty',
  examinerCredentials: 'MS (ENT)',
  checklist: PreTestChecklist(
    loudNoiseLast24h: false,
    tinnitus: true,
    hearingAidsRemoved: true,
    phonesSilenced: true,
    quietRoom: true,
  ),
  familiarisation: FamiliarisationOutcome(
    heard: true,
    levelDbHl: 40,
    onsetOffsetMatched: true,
    reinstructed: false,
  ),
  retests: [
    RetestRecord(
      ear: Ear.left,
      frequencyHz: 1000,
      firstDbHl: 20,
      retestDbHl: 15,
      withinTolerance: true,
    ),
  ],
  interoctaveAdded: [FrequencyRef(Ear.left, 750)],
  skipped: [FrequencyRef(Ear.right, 6000)],
  breaksOffered: 1,
  pressesBetweenTones: {Ear.left: 2, Ear.right: 1},
  testDuration: Duration(minutes: 14),
);

void main() {
  group('protocol record', () {
    test('keeps output limits and the audio format', () {
      const record = TestProtocolRecord(
        outputLimits: [OutputLimit(Ear.left, 250, 75)],
        reducedPrecisionAudio: true,
      );
      final back = TestProtocolRecord.fromJson(record.toJson());
      expect(back.maxLevelFor(Ear.left, 250), 75);
      expect(back.maxLevelFor(Ear.right, 250), kMaxLevelDbHl);
      expect(back.reducedPrecisionAudio, isTrue);
      expect(TestProtocolRecord.fromJson(const {}).outputLimits, isEmpty);
    });

    test('survives a JSON round trip', () {
      final decoded = TestProtocolRecord.fromJson(
        jsonDecode(jsonEncode(fullProtocol.toJson())) as Map<String, Object?>,
      );

      expect(decoded.earOrder, [Ear.left, Ear.right]);
      expect(decoded.transducerType, TransducerType.insertEarphones);
      expect(decoded.reasonForTest, 'Referred for hearing difficulty');
      expect(decoded.examinerCredentials, 'MS (ENT)');
      expect(decoded.checklist.tinnitus, isTrue);
      expect(decoded.checklist.loudNoiseLast24h, isFalse);
      expect(decoded.checklist.requiredConfirmed, isTrue);
      expect(decoded.checklist.earsChecked, isFalse);
      expect(decoded.familiarisation!.levelDbHl, 40);
      expect(decoded.retests.single.retestDbHl, 15);
      expect(decoded.retests.single.differenceDb, 5);
      expect(
        decoded.interoctaveAdded.single,
        const FrequencyRef(Ear.left, 750),
      );
      expect(decoded.skipped.single, const FrequencyRef(Ear.right, 6000));
      expect(decoded.breaksOffered, 1);
      expect(decoded.totalPressesBetweenTones, 3);
      expect(decoded.testDuration, const Duration(minutes: 14));
    });

    test('a damaged record reads back with defaults instead of failing', () {
      final decoded = TestProtocolRecord.fromJson({
        'earOrder': ['up', 'left'],
        'transducerType': 'unknown',
        'retests': [
          {'ear': 'nowhere'},
          'junk',
        ],
        'pressesBetweenTones': {'left': 'many', 'right': 4},
      });
      expect(decoded.earOrder, [Ear.left]);
      expect(decoded.transducerType, TransducerType.headphones);
      expect(decoded.retests, isEmpty);
      expect(decoded.pressesBetweenTones, {Ear.right: 4});
      expect(decoded.checklist.questionsAnswered, isFalse);
    });
  });

  group('session storage', () {
    test('protocol and qualifiers survive toMap and fromMap', () {
      final original = session([
        point(Ear.right, 250, -10, qualifier: ThresholdQualifier.atFloor),
        point(
          Ear.right,
          500,
          null,
          qualifier: ThresholdQualifier.notEstablished,
        ),
        point(Ear.right, 1000, 20),
      ], protocol: fullProtocol);
      final map = original.toMap();
      final points = [
        for (final p in original.points)
          ThresholdPoint.fromMap(p.toMap(original.id)),
      ];
      final restored = TestSession.fromMap(map, points);

      expect(restored.protocol!.examinerCredentials, 'MS (ENT)');
      expect(restored.points[0].isAtFloor, isTrue);
      expect(restored.points[1].isNotEstablished, isTrue);
      expect(restored.points[2].qualifier, ThresholdQualifier.measured);
      expect(
        points[2].toMap('s1')['qualifier'],
        isNull,
        reason: 'ordinary rows look like rows from older versions',
      );
    });

    test('a session without a protocol reads back as null', () {
      final map = session([point(Ear.right, 1000, 20)]).toMap();
      expect(map['protocol_json'], isNull);
      expect(TestSession.fromMap(map, const []).protocol, isNull);
    });

    test('unreadable protocol JSON does not make the session unreadable', () {
      final map = session([point(Ear.right, 1000, 20)]).toMap()
        ..['protocol_json'] = '{not json';
      expect(TestSession.fromMap(map, const []).protocol, isNull);
    });
  });

  group('results', () {
    test('a threshold that was not established is not plotted or averaged', () {
      final s = session([
        point(Ear.right, 500, 20),
        point(
          Ear.right,
          1000,
          null,
          qualifier: ThresholdQualifier.notEstablished,
        ),
        point(Ear.right, 2000, 30),
      ]);
      expect(s.thresholdsFor(Ear.right).containsKey(1000), isFalse);
      expect(s.notEstablishedFor(Ear.right), {1000});
      expect(s.ptaFor(Ear.right)!.frequenciesUsed, [500, 2000]);
      expect(
        s.ptaFor(Ear.right)!.isLowerBound,
        isFalse,
        reason: 'not established must not read as a no-response',
      );
    });

    test('a PTA that includes a floor value is shown as at or below', () {
      final s = session([
        point(Ear.right, 500, -10, qualifier: ThresholdQualifier.atFloor),
        point(Ear.right, 1000, -10, qualifier: ThresholdQualifier.atFloor),
        point(Ear.right, 2000, -5),
      ]);
      expect(s.ptaDisplayFor(Ear.right), startsWith('≤'));
      expect(s.floorFrequenciesFor(Ear.right), {500, 1000});
    });
  });

  group('masking check', () {
    test('flags a 40 dB difference with headphones', () {
      final s = session([
        point(Ear.right, 1000, 10),
        point(Ear.left, 1000, 50),
        point(Ear.right, 2000, 10),
        point(Ear.left, 2000, 45),
      ]);
      final flags = s.maskingFlags;
      expect(flags, hasLength(1));
      expect(flags.single.frequencyHz, 1000);
      expect(flags.single.worseEar, Ear.left);
      expect(flags.single.differenceDb, 40);
    });

    test('uses 55 dB for insert earphones', () {
      final s = session(
        [point(Ear.right, 1000, 10), point(Ear.left, 1000, 50)],
        protocol: const TestProtocolRecord(
          transducerType: TransducerType.insertEarphones,
        ),
      );
      expect(s.maskingFlags, isEmpty);
    });

    test('a no-response in the worse ear is a lower bound', () {
      final s = session([
        point(Ear.right, 4000, 20),
        point(Ear.left, 4000, null, noResponse: true),
      ]);
      final flag = s.maskingFlags.single;
      expect(flag.worseEar, Ear.left);
      expect(flag.isLowerBound, isTrue);
      expect(flag.differenceDb, kMaxLevelDbHl - 20);
    });

    test('needs both ears at the same frequency', () {
      final s = session([
        point(Ear.right, 1000, 10),
        point(Ear.left, 2000, 80),
      ]);
      expect(s.maskingFlags, isEmpty);
    });
  });

  group('reliability', () {
    test('many presses between tones make a session unreliable', () {
      final s = session(
        [point(Ear.right, 1000, 20, tones: 10)],
        protocol: const TestProtocolRecord(pressesBetweenTones: {Ear.right: 4}),
      );
      expect(s.isReliable, isFalse);
      expect(s.reliabilityConcerns.single, contains('4 times'));
    });

    test('a failed retest is reported', () {
      final s = session(
        [point(Ear.right, 1000, 20)],
        protocol: const TestProtocolRecord(
          retests: [
            RetestRecord(
              ear: Ear.right,
              frequencyHz: 1000,
              firstDbHl: 40,
              retestDbHl: 20,
              withinTolerance: false,
            ),
          ],
        ),
      );
      expect(s.reliabilityConcerns.single, contains('differed by 20 dB'));
    });

    test('a clean session has no concerns', () {
      final s = session([
        point(Ear.right, 1000, 20),
      ], protocol: fullProtocol.copyWith(pressesBetweenTones: const {}));
      expect(s.reliabilityConcerns, isEmpty);
      expect(s.isReliable, isTrue);
    });
  });

  group('frequencies', () {
    test('interoctave rule applies between 500 and 2000 Hz only', () {
      expect(interoctaveFrequenciesNeeded({500: 10, 1000: 30, 2000: 35}), [
        750,
      ]);
      expect(interoctaveFrequenciesNeeded({500: 10, 1000: 15, 2000: 40}), [
        1500,
      ]);
      expect(
        interoctaveFrequenciesNeeded({500: 10, 1000: 25, 2000: 40}),
        isEmpty,
      );
      expect(
        interoctaveFrequenciesNeeded({500: null, 1000: 60}),
        isEmpty,
        reason: 'a no-response is not a number to compare',
      );
      expect(
        interoctaveFrequenciesNeeded({500: 10, 750: 20, 1000: 40}),
        isEmpty,
        reason: 'already tested',
      );
    });

    test('labels', () {
      expect(formatHzShort(750), '750');
      expect(formatHzShort(1500), '1.5k');
      expect(formatHzShort(8000), '8k');
      expect(formatHzLong(1500), '1.5 kHz');
      expect(formatHzLong(250), '250 Hz');
    });

    test('the test order follows ASHA', () {
      expect(kTestOrderHz, [1000, 2000, 3000, 4000, 6000, 8000, 500, 250]);
      expect(kStandardFrequenciesHz.toSet(), kTestOrderHz.toSet());
    });
  });
}
