import 'package:auris/data/models/patient.dart';
import 'package:auris/data/models/test_session.dart';
import 'package:auris/data/syncing_repository.dart';
import 'package:flutter_test/flutter_test.dart';

Patient patientAt(DateTime updatedAt, {String name = 'Test Patient'}) => Patient(
      id: 'p1',
      fullName: name,
      ageYears: 40,
      sex: 'Female',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: updatedAt,
    );

void main() {
  group('patient conflict resolution (last-write-wins)', () {
    test('a patient not held locally is always imported', () {
      expect(
        SyncMergePolicy.shouldReplacePatient(
          local: null,
          remote: patientAt(DateTime(2026, 1, 1)),
        ),
        isTrue,
      );
    });

    test('a newer remote edit replaces the local copy', () {
      expect(
        SyncMergePolicy.shouldReplacePatient(
          local: patientAt(DateTime(2026, 5, 1)),
          remote: patientAt(DateTime(2026, 6, 1)),
        ),
        isTrue,
      );
    });

    test('an older remote copy does not clobber a newer local edit', () {
      // The failure this prevents: a phone edited on the tablet this morning
      // being reverted by a stale copy from another device.
      expect(
        SyncMergePolicy.shouldReplacePatient(
          local: patientAt(DateTime(2026, 6, 1)),
          remote: patientAt(DateTime(2026, 5, 1)),
        ),
        isFalse,
      );
    });

    test('identical timestamps keep the local copy', () {
      // A tie means no new information, so writing would be pointless churn.
      final sameMoment = DateTime(2026, 6, 1, 12, 30);
      expect(
        SyncMergePolicy.shouldReplacePatient(
          local: patientAt(sameMoment, name: 'Local'),
          remote: patientAt(sameMoment, name: 'Remote'),
        ),
        isFalse,
      );
    });

    test('sub-second differences are respected', () {
      expect(
        SyncMergePolicy.shouldReplacePatient(
          local: patientAt(DateTime(2026, 6, 1, 12, 0, 0, 100)),
          remote: patientAt(DateTime(2026, 6, 1, 12, 0, 0, 101)),
        ),
        isTrue,
      );
    });
  });

  group('session import rules', () {
    test('a session not held locally is imported', () {
      expect(SyncMergePolicy.shouldImportSession(existsLocally: false), isTrue);
    });

    test('an existing local session is never overwritten', () {
      // A recorded audiogram is evidence. Replacing this device's measurements
      // with another device's copy of them would be indefensible, so a pull
      // must never do it - even if the remote row looks newer.
      expect(SyncMergePolicy.shouldImportSession(existsLocally: true), isFalse);
    });
  });

  group('SyncReport', () {
    test('reports nothing to do', () {
      const report = SyncReport();
      expect(report.isEmpty, isTrue);
      expect(report.summary, 'Everything is up to date');
    });

    test('summarises a two-way pass', () {
      const report =
          SyncReport(pushed: 2, pulledPatients: 3, pulledSessions: 1);
      expect(report.isEmpty, isFalse);
      expect(report.summary, contains('sent 2 records'));
      expect(report.summary, contains('received 3 patients'));
      expect(report.summary, contains('received 1 test'));
    });

    test('singular and plural read correctly', () {
      const one = SyncReport(pushed: 1, pulledPatients: 1);
      expect(one.summary, contains('sent 1 record,'));
      expect(one.summary, contains('received 1 patient'));
    });

    test('surfaces items still pending', () {
      const report = SyncReport(pushed: 1, failed: 2);
      expect(report.summary, contains('2 still waiting to upload'));
    });

    test('says when the server refused an upload, and why', () {
      const report = SyncReport(refused: 1, refusedReason: 'row-level security');
      expect(report.summary, contains('refused 1'));
      expect(report.summary, contains('row-level security'));
    });

    test('a sync already running is not reported as up to date', () {
      expect(const SyncReport.busy().summary, 'A sync is already running');
    });

    test('an error replaces the summary', () {
      const report = SyncReport(error: 'no network');
      expect(report.summary, 'Sync failed: no network');
    });
  });

  group('rows from the server', () {
    test('yes/no columns read from SQLite numbers and Postgres booleans', () {
      expect(readFlag(1), isTrue);
      expect(readFlag(0), isFalse);
      expect(readFlag(true), isTrue);
      expect(readFlag(false), isFalse);
      expect(readFlag(null), isFalse);
    });

    test('a test downloaded from Postgres reads', () {
      final point = ThresholdPoint.fromMap({
        'ear': 'right',
        'frequency_hz': 1000,
        'threshold_db_hl': null,
        'no_response': true,
        'tones_presented': 9,
        'catch_trials': 1,
        'false_positives': 0,
        'qualifier': null,
      });
      expect(point.noResponse, isTrue);
      final session = TestSession.fromMap({
        'id': 's1',
        'patient_id': 'p1',
        'tested_at': '2026-10-22T10:00:00.000',
        'clinician_name': 'Dr. A',
        'calibration_json': null,
        'notes': null,
        'is_complete': true,
        'synced_at': '2026-10-22T10:05:00.123456+00:00',
        'protocol_json': null,
      }, [point]);
      expect(session.isComplete, isTrue);
      expect(session.syncedAt, isNotNull);
    });
  });
}
