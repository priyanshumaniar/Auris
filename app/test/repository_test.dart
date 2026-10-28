import 'package:auris/core/audiometry/audiometry.dart';
import 'package:auris/core/audiometry/calibration.dart';
import 'package:auris/data/local_database.dart';
import 'package:auris/data/local_repository.dart';
import 'dart:io';

import 'package:auris/data/models/patient.dart';
import 'package:auris/data/models/test_protocol.dart';
import 'package:auris/data/models/test_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// These run against a real SQLite database held in memory - the schema,
/// foreign keys, cascades and indices are the ones the app ships.
void main() {
  late LocalDatabase database;
  late LocalRepository repo;

  setUp(() async {
    database = await LocalDatabase.openInMemory();
    repo = LocalRepository(database);
  });

  tearDown(() async => database.close());

  Patient buildPatient({String id = 'p1', String name = 'Test Patient'}) {
    final now = DateTime(2026, 3, 14, 10, 30);
    return Patient(
      id: id,
      fullName: name,
      ageYears: 42,
      sex: 'Female',
      clinicRef: 'MRN-$id',
      createdAt: now,
      updatedAt: now,
    );
  }

  TestSession buildSession({
    String id = 's1',
    String patientId = 'p1',
    DateTime? testedAt,
    bool complete = true,
    List<ThresholdPoint>? points,
  }) =>
      TestSession(
        id: id,
        patientId: patientId,
        testedAt: testedAt ?? DateTime(2026, 3, 14, 11),
        clinicianName: 'Dr. Example',
        isComplete: complete,
        calibration: const CalibrationProfile(
          method: CalibrationMethod.soundLevelMeter,
          globalOffsetDb: -2.5,
          transducerName: 'TDH-39P',
        ),
        points: points ??
            const [
              ThresholdPoint(
                  ear: Ear.right,
                  frequencyHz: 1000,
                  thresholdDbHl: 15,
                  noResponse: false,
                  tonesPresented: 9),
              ThresholdPoint(
                  ear: Ear.left,
                  frequencyHz: 1000,
                  thresholdDbHl: 20,
                  noResponse: false,
                  tonesPresented: 11),
              ThresholdPoint(
                  ear: Ear.left,
                  frequencyHz: 8000,
                  thresholdDbHl: null,
                  noResponse: true,
                  tonesPresented: 14),
            ],
      );

  group('patients', () {
    test('round-trips every field', () async {
      final original = buildPatient();
      await repo.upsertPatient(original);

      final loaded = (await repo.getPatient('p1'))!;
      expect(loaded.fullName, original.fullName);
      expect(loaded.ageYears, 42);
      expect(loaded.sex, 'Female');
      expect(loaded.clinicRef, 'MRN-p1');
      expect(loaded.createdAt, original.createdAt);
    });

    test('upsert updates rather than duplicating', () async {
      await repo.upsertPatient(buildPatient());
      await repo.upsertPatient(buildPatient().copyWith(fullName: 'Renamed'));

      final all = await repo.listPatients();
      expect(all, hasLength(1));
      expect(all.single.fullName, 'Renamed');
    });

    test('searches by name and by clinic reference', () async {
      await repo.upsertPatient(buildPatient(id: 'p1', name: 'Asha Iyer'));
      await repo.upsertPatient(buildPatient(id: 'p2', name: 'Bharat Rao'));

      expect(await repo.listPatients(query: 'asha'), hasLength(1));
      expect((await repo.listPatients(query: 'Rao')).single.id, 'p2');
      expect((await repo.listPatients(query: 'MRN-p2')).single.id, 'p2');
      expect(await repo.listPatients(query: 'nobody'), isEmpty);
      expect(await repo.listPatients(query: '   '), hasLength(2));
    });

    test('returns null for an unknown id', () async {
      expect(await repo.getPatient('missing'), isNull);
    });
  });

  group('sessions', () {
    setUp(() async => repo.upsertPatient(buildPatient()));

    test('round-trips thresholds including no-response points', () async {
      await repo.saveSession(buildSession());

      final loaded = (await repo.getSession('s1'))!;
      expect(loaded.points, hasLength(3));
      expect(loaded.clinicianName, 'Dr. Example');

      final right = loaded.thresholdsFor(Ear.right);
      expect(right[1000], 15);

      final left = loaded.thresholdsFor(Ear.left);
      expect(left[1000], 20);
      expect(left.containsKey(8000), isTrue);
      expect(left[8000], isNull, reason: 'no-response must survive as null');
    });

    test('preserves the calibration snapshot', () async {
      await repo.saveSession(buildSession());
      final loaded = (await repo.getSession('s1'))!;

      expect(loaded.calibration.isCalibrated, isTrue);
      expect(loaded.calibration.globalOffsetDb, -2.5);
      expect(loaded.calibration.transducerName, 'TDH-39P');
    });

    test('re-saving replaces points instead of appending', () async {
      await repo.saveSession(buildSession());
      await repo.saveSession(buildSession(points: const [
        ThresholdPoint(
            ear: Ear.right,
            frequencyHz: 1000,
            thresholdDbHl: 5,
            noResponse: false),
      ]));

      final loaded = (await repo.getSession('s1'))!;
      expect(loaded.points, hasLength(1));
      expect(loaded.thresholdsFor(Ear.right)[1000], 5);
    });

    test('lists a patient history newest first', () async {
      await repo.saveSession(
          buildSession(id: 'old', testedAt: DateTime(2025, 1, 1)));
      await repo.saveSession(
          buildSession(id: 'new', testedAt: DateTime(2026, 1, 1)));
      await repo.saveSession(
          buildSession(id: 'mid', testedAt: DateTime(2025, 6, 1)));

      final history = await repo.listSessions('p1');
      expect(history.map((s) => s.id), ['new', 'mid', 'old']);
    });

    test('deleting a patient cascades to sessions and thresholds', () async {
      await repo.saveSession(buildSession());
      await repo.deletePatient('p1');

      expect(await repo.getSession('s1'), isNull);
      final orphans =
          await database.db.query('thresholds', where: 'session_id = ?', whereArgs: ['s1']);
      expect(orphans, isEmpty, reason: 'threshold rows must not outlive the patient');
    });

    test('deleting a session leaves the patient intact', () async {
      await repo.saveSession(buildSession());
      await repo.deleteSession('s1');

      expect(await repo.getSession('s1'), isNull);
      expect(await repo.getPatient('p1'), isNotNull);
    });

    test('rejects a session for a patient that does not exist', () async {
      // Foreign keys are enabled, so this is a database-level guarantee.
      expect(
        () => repo.saveSession(buildSession(id: 's9', patientId: 'ghost')),
        throwsA(anything),
      );
    });
  });

  group('pending sync', () {
    setUp(() async => repo.upsertPatient(buildPatient()));

    test('lists only completed, unsynced sessions', () async {
      await repo.saveSession(buildSession(id: 'done'));
      await repo.saveSession(buildSession(id: 'draft', complete: false));
      await repo.saveSession(
          buildSession(id: 'synced').copyWith(syncedAt: DateTime(2026, 3, 14)));

      final pending = await repo.pendingSync();
      expect(pending.map((s) => s.id), ['done']);
    });

    test('is empty when everything is synced', () async {
      await repo.saveSession(
          buildSession(id: 'a').copyWith(syncedAt: DateTime.now()));
      expect(await repo.pendingSync(), isEmpty);
    });
  });

  group('derived clinical values', () {
    test('computes PTA and degree from stored thresholds', () async {
      await repo.upsertPatient(buildPatient());
      await repo.saveSession(buildSession(points: const [
        ThresholdPoint(
            ear: Ear.right, frequencyHz: 500, thresholdDbHl: 45, noResponse: false),
        ThresholdPoint(
            ear: Ear.right, frequencyHz: 1000, thresholdDbHl: 50, noResponse: false),
        ThresholdPoint(
            ear: Ear.right, frequencyHz: 2000, thresholdDbHl: 55, noResponse: false),
      ]));

      final session = (await repo.getSession('s1'))!;
      final pta = session.ptaFor(Ear.right)!;

      expect(pta.valueDbHl, 50.0);
      expect(pta.degree.label, 'Moderate');
      expect(session.testedEars, {Ear.right});
      expect(session.testedFrequencies, [500, 1000, 2000]);
    });
  });

  group('test protocol record', () {
    test('protocol and threshold qualifiers are stored and read back',
        () async {
      await repo.upsertPatient(buildPatient());
      await repo.saveSession(buildSession(points: const [
        ThresholdPoint(
          ear: Ear.right,
          frequencyHz: 250,
          thresholdDbHl: -10,
          noResponse: false,
          qualifier: ThresholdQualifier.atFloor,
        ),
        ThresholdPoint(
          ear: Ear.right,
          frequencyHz: 500,
          thresholdDbHl: null,
          noResponse: false,
          qualifier: ThresholdQualifier.notEstablished,
        ),
      ]).copyWith(
        protocol: const TestProtocolRecord(
          earOrder: [Ear.right],
          reasonForTest: 'Screening',
          skipped: [FrequencyRef(Ear.right, 6000)],
        ),
      ));

      final loaded = (await repo.getSession('s1'))!;
      expect(loaded.protocol!.reasonForTest, 'Screening');
      expect(loaded.protocol!.skipped.single.frequencyHz, 6000);
      expect(loaded.floorFrequenciesFor(Ear.right), {250});
      expect(loaded.notEstablishedFor(Ear.right), {500});
    });
  });

  group('schema migration', () {
    test('a version 3 database gains the version 4, 5 and 6 columns', () async {
      final dir = await Directory.systemTemp.createTemp('auris_migration');
      final path = p.join(dir.path, 'v3.db');

      // The tables versions 4 to 6 change, as version 3 created them.
      sqfliteFfiInit();
      final old = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 3,
          onCreate: (d, _) async {
            await d.execute('''
              CREATE TABLE patients (
                id TEXT PRIMARY KEY, full_name TEXT NOT NULL,
                age_years INTEGER NOT NULL, sex TEXT NOT NULL,
                clinic_ref TEXT, date_of_birth TEXT, phone TEXT, notes TEXT,
                created_at TEXT NOT NULL, updated_at TEXT NOT NULL)
            ''');
            await d.execute('''
              CREATE TABLE sessions (
                id TEXT PRIMARY KEY, patient_id TEXT NOT NULL,
                tested_at TEXT NOT NULL, clinician_name TEXT NOT NULL,
                calibration_json TEXT, notes TEXT,
                is_complete INTEGER NOT NULL DEFAULT 0, synced_at TEXT)
            ''');
            await d.execute('''
              CREATE TABLE thresholds (
                session_id TEXT NOT NULL, ear TEXT NOT NULL,
                frequency_hz INTEGER NOT NULL, threshold_db_hl INTEGER,
                no_response INTEGER NOT NULL DEFAULT 0,
                tones_presented INTEGER NOT NULL DEFAULT 0,
                catch_trials INTEGER NOT NULL DEFAULT 0,
                false_positives INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (session_id, ear, frequency_hz))
            ''');
            await d.execute('''
              CREATE TABLE clinicians (
                id TEXT PRIMARY KEY, username TEXT NOT NULL UNIQUE,
                display_name TEXT NOT NULL, password_hash TEXT NOT NULL,
                password_salt TEXT NOT NULL,
                role TEXT NOT NULL DEFAULT 'clinician', clinic_id TEXT,
                created_at TEXT NOT NULL)
            ''');
          },
        ),
      );
      await old.close();

      final migrated = await LocalDatabase.open(path: path);
      try {
        Future<List<String>> columns(String table) async => [
              for (final row
                  in await migrated.db.rawQuery('PRAGMA table_info($table)'))
                row['name'] as String,
            ];
        expect(await columns('sessions'), contains('protocol_json'));
        expect(await columns('thresholds'), contains('qualifier'));
        expect(await columns('patients'), contains('clinic_id'));
        expect(await columns('sessions'), contains('clinic_id'));
        expect(
          await columns('clinicians'),
          containsAll(['phone', 'qualification', 'registration_no']),
        );
        expect(await columns('patients'), contains('synced_at'));
        expect(await columns('pending_deletes'),
            containsAll(['kind', 'id', 'clinic_id']));
        expect(await migrated.db.getVersion(), 7);
      } finally {
        await migrated.close();
        await dir.delete(recursive: true);
      }
    });
  });

  group('editing', () {
    test('editing a patient keeps their test history', () async {
      // SQLite carries out INSERT OR REPLACE as a delete and an insert, and
      // the delete would cascade to every one of the patient's tests.
      await repo.upsertPatient(buildPatient());
      await repo.saveSession(buildSession());
      await repo.upsertPatient(buildPatient().copyWith(fullName: 'Renamed'));

      expect((await repo.getPatient('p1'))!.fullName, 'Renamed');
      expect(await repo.listSessions('p1'), hasLength(1));
      expect((await repo.getSession('s1'))!.points, isNotEmpty);
    });

    test('saving a session again keeps one session', () async {
      await repo.upsertPatient(buildPatient());
      await repo.saveSession(buildSession());
      await repo.saveSession(buildSession().copyWith(notes: 'Reviewed'));

      final sessions = await repo.listSessions('p1');
      expect(sessions, hasLength(1));
      expect(sessions.single.notes, 'Reviewed');
    });
  });

  group('records scoped to a clinic', () {
    late RecordScope current;

    setUp(() {
      current = const RecordScope.clinic('clinic-a');
      repo.scope = () => current;
    });

    test('another clinic on the same device sees none of them', () async {
      await repo.upsertPatient(buildPatient());
      await repo.saveSession(buildSession());

      current = const RecordScope.clinic('clinic-b');
      expect(await repo.listPatients(), isEmpty);
      expect(await repo.getPatient('p1'), isNull);
      expect(await repo.listSessions('p1'), isEmpty);
      expect(await repo.getSession('s1'), isNull);
      expect(await repo.pendingSync(), isEmpty,
          reason: 'clinic B must never upload clinic A\'s tests');

      current = const RecordScope.clinic('clinic-a');
      expect(await repo.listPatients(), hasLength(1));
    });

    test('local accounts do not see records cached for a cloud clinic',
        () async {
      await repo.upsertPatient(buildPatient());
      current = RecordScope.device;
      expect(await repo.listPatients(), isEmpty);
    });

    test('nobody with access signed in: nothing visible, nothing written',
        () async {
      await repo.upsertPatient(buildPatient());
      current = RecordScope.none;
      expect(await repo.listPatients(), isEmpty);
      expect(await repo.getPatient('p1'), isNull);
      expect(() => repo.upsertPatient(buildPatient(id: 'p2')),
          throwsA(isA<StateError>()));
    });

    test('another clinic cannot delete them', () async {
      await repo.upsertPatient(buildPatient());
      current = const RecordScope.clinic('clinic-b');
      await repo.deletePatient('p1');
      current = const RecordScope.clinic('clinic-a');
      expect(await repo.getPatient('p1'), isNotNull);
    });

    test('claiming tags only records that have no clinic yet', () async {
      current = RecordScope.device;
      await repo.upsertPatient(buildPatient(id: 'old'));
      current = const RecordScope.clinic('clinic-b');
      await repo.upsertPatient(buildPatient(id: 'other'));

      await repo.claimForClinic('clinic-a', patientIds: ['old', 'other']);

      current = const RecordScope.clinic('clinic-a');
      expect((await repo.listPatients()).map((x) => x.id).toList(), ['old']);
      current = const RecordScope.clinic('clinic-b');
      expect((await repo.listPatients()).map((x) => x.id).toList(), ['other'],
          reason: 'a record of another clinic is never moved');
    });

    test('finds unsynced tests recorded before records were tagged', () async {
      current = RecordScope.device;
      await repo.upsertPatient(buildPatient());
      await repo.saveSession(buildSession());
      await repo.saveSession(buildSession(id: 'done')
          .copyWith(syncedAt: DateTime(2026, 3, 15)));

      final (patients, sessions) = await repo.untaggedUnsynced();
      expect(sessions, ['s1']);
      expect(patients, ['p1']);
    });

    test('untagged patients without a test are found too', () async {
      current = RecordScope.device;
      await repo.upsertPatient(buildPatient(id: 'lonely'));
      final (patients, sessions) = await repo.untaggedUnsynced();
      expect(patients, ['lonely']);
      expect(sessions, isEmpty);
    });
  });

  group('sync bookkeeping', () {
    test('a patient edited here waits for upload; a downloaded one does not',
        () async {
      await repo.upsertPatient(buildPatient(id: 'mine'));
      await repo.storeSyncedPatient(buildPatient(id: 'theirs'));
      expect((await repo.pendingPatients()).map((p) => p.id), ['mine']);
      expect(await repo.patientNeedsUpload('mine'), isTrue);
      expect(await repo.patientNeedsUpload('theirs'), isFalse);

      await repo.markPatientSynced('mine', DateTime(2026, 10, 22));
      expect(await repo.pendingPatients(), isEmpty);

      await repo.upsertPatient(buildPatient(id: 'mine'));
      expect(await repo.patientNeedsUpload('mine'), isTrue,
          reason: 'an edit after upload needs uploading again');
    });

    test('marking a test uploaded keeps its points', () async {
      await repo.upsertPatient(buildPatient());
      await repo.saveSession(buildSession());
      expect(await repo.pendingSync(), hasLength(1));

      await repo.markSessionSynced('s1', DateTime(2026, 10, 22));
      expect(await repo.pendingSync(), isEmpty);
      final stored = await repo.getSession('s1');
      expect(stored!.points, hasLength(buildSession().points.length));
    });

    test('deletes made offline are remembered until cleared', () async {
      await repo.addPendingDelete('patients', 'p9');
      await repo.addPendingDelete('patients', 'p9');
      expect(await repo.pendingDeletes(), [('patients', 'p9')]);
      await repo.clearPendingDelete('patients', 'p9');
      expect(await repo.pendingDeletes(), isEmpty);
    });

    test('looks up many records at once', () async {
      await repo.upsertPatient(buildPatient(id: 'a'));
      await repo.upsertPatient(buildPatient(id: 'b'));
      expect(await repo.existingIds('patients', ['a', 'b', 'c']), {'a', 'b'});
      final stamps = await repo.patientStamps(['a', 'zz']);
      expect(stamps.keys, ['a']);
    });
  });
}
