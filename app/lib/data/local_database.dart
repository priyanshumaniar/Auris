import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Opens and migrates the on-device SQLite database.
///
/// Every record is written here first, whether or not cloud sync is configured.
/// A hearing test must not fail because the clinic's wi-fi dropped mid-session,
/// so the local database is the source of truth and the cloud is a replica.
class LocalDatabase {
  LocalDatabase._(this.db);

  final Database db;

  static const _fileName = 'auris.db';

  /// Schema history:
  ///   1 - initial schema
  ///   2 - clinicians.role, clinicians.clinic_id (user roles)
  ///   3 - calibration_events (calibration history for this device)
  ///   4 - sessions.protocol_json, thresholds.qualifier (how the test was
  ///       run; floor and not-established results)
  ///   5 - patients.clinic_id, sessions.clinic_id (which clinic a cached
  ///       record belongs to, so one device never shows another clinic's
  ///       records; see [RecordScope])
  ///   6 - clinicians.phone, .qualification, .registration_no (profile)
  ///   7 - patients.synced_at (a patient edited offline is retried) and
  ///       pending_deletes (a delete made offline is retried)
  static const _schemaVersion = 7;

  static LocalDatabase? _instance;

  /// True on platforms where sqflite cannot run (Flutter web).
  static bool get isSupported => !kIsWeb;

  static Future<LocalDatabase> open({String? path}) async {
    if (_instance != null) return _instance!;

    if (!isSupported) {
      throw UnsupportedError(
        'Local storage is not available on Flutter web. Run Auris on Android, '
        'iOS, Windows, macOS or Linux.',
      );
    }

    // sqflite ships a native implementation for Android and iOS only; desktop
    // goes through the FFI backend.
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dbPath = path ??
        p.join((await getApplicationDocumentsDirectory()).path, _fileName);

    final database = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: _schemaVersion,
        onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
        onCreate: (d, _) => _createSchema(d),
        onUpgrade: _migrate,
      ),
    );

    return _instance = LocalDatabase._(database);
  }

  /// Opens a throwaway in-memory database. Used by the repository tests.
  @visibleForTesting
  static Future<LocalDatabase> openInMemory() async {
    sqfliteFfiInit();
    final database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: _schemaVersion,
        onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
        onCreate: (d, _) => _createSchema(d),
        onUpgrade: _migrate,
      ),
    );
    return LocalDatabase._(database);
  }

  Future<void> close() async {
    await db.close();
    if (identical(_instance, this)) _instance = null;
  }

  static Future<void> _createSchema(Database d) async {
    final batch = d.batch();

    batch.execute('''
      CREATE TABLE patients (
        id            TEXT PRIMARY KEY,
        full_name     TEXT    NOT NULL,
        age_years     INTEGER NOT NULL,
        sex           TEXT    NOT NULL,
        clinic_ref    TEXT,
        date_of_birth TEXT,
        phone         TEXT,
        notes         TEXT,
        created_at    TEXT    NOT NULL,
        updated_at    TEXT    NOT NULL,
        clinic_id     TEXT,
        synced_at     TEXT
      )
    ''');

    batch.execute('''
      CREATE TABLE sessions (
        id               TEXT PRIMARY KEY,
        patient_id       TEXT    NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
        tested_at        TEXT    NOT NULL,
        clinician_name   TEXT    NOT NULL,
        calibration_json TEXT,
        notes            TEXT,
        is_complete      INTEGER NOT NULL DEFAULT 0,
        synced_at        TEXT,
        protocol_json    TEXT,
        clinic_id        TEXT
      )
    ''');

    // One threshold per (session, ear, frequency) - the composite primary key
    // makes a duplicate reading impossible rather than merely unlikely.
    batch.execute('''
      CREATE TABLE thresholds (
        session_id      TEXT    NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        ear             TEXT    NOT NULL,
        frequency_hz    INTEGER NOT NULL,
        threshold_db_hl INTEGER,
        no_response     INTEGER NOT NULL DEFAULT 0,
        tones_presented INTEGER NOT NULL DEFAULT 0,
        catch_trials    INTEGER NOT NULL DEFAULT 0,
        false_positives INTEGER NOT NULL DEFAULT 0,
        qualifier       TEXT,
        PRIMARY KEY (session_id, ear, frequency_hz)
      )
    ''');

    batch.execute('''
      CREATE TABLE clinicians (
        id            TEXT PRIMARY KEY,
        username      TEXT NOT NULL UNIQUE,
        display_name  TEXT NOT NULL,
        password_hash TEXT NOT NULL,
        password_salt TEXT NOT NULL,
        role          TEXT NOT NULL DEFAULT 'clinician',
        clinic_id     TEXT,
        created_at    TEXT NOT NULL,
        phone           TEXT,
        qualification   TEXT,
        registration_no TEXT
      )
    ''');

    _createCalibrationEvents(batch);
    _createPendingDeletes(batch);

    batch.execute(
        'CREATE INDEX idx_sessions_patient ON sessions(patient_id, tested_at DESC)');
    batch.execute('CREATE INDEX idx_sessions_unsynced ON sessions(synced_at)');
    batch.execute('CREATE INDEX idx_patients_name ON patients(full_name)');
    batch.execute('CREATE INDEX idx_patients_clinic ON patients(clinic_id)');
    batch.execute('CREATE INDEX idx_sessions_clinic ON sessions(clinic_id)');

    await batch.commit(noResult: true);
  }

  /// Applies schema migrations in order, so a device upgrading from any older
  /// version reaches the current schema without losing records.
  static Future<void> _migrate(Database d, int from, int to) async {
    if (from < 2) {
      // Existing installs have exactly one clinician who has been operating
      // with full access, so promoting them to admin preserves what they could
      // already do. New accounts get their role assigned at sign-up.
      await d.execute(
          "ALTER TABLE clinicians ADD COLUMN role TEXT NOT NULL DEFAULT 'clinician'");
      await d.execute('ALTER TABLE clinicians ADD COLUMN clinic_id TEXT');
      await d.execute("UPDATE clinicians SET role = 'admin'");
    }
    if (from < 3) {
      final batch = d.batch();
      _createCalibrationEvents(batch);
      await batch.commit(noResult: true);
    }
    if (from < 4) {
      // Both columns are nullable: existing sessions have no protocol record,
      // and existing thresholds are ordinary measured values.
      await d.execute('ALTER TABLE sessions ADD COLUMN protocol_json TEXT');
      await d.execute('ALTER TABLE thresholds ADD COLUMN qualifier TEXT');
    }
    if (from < 5) {
      // Existing rows stay NULL: on a device in local-only mode they are that
      // device's own records. In cloud mode they are claimed by the clinic
      // the next time a sync confirms them on the server.
      await d.execute('ALTER TABLE patients ADD COLUMN clinic_id TEXT');
      await d.execute('ALTER TABLE sessions ADD COLUMN clinic_id TEXT');
      await d.execute(
          'CREATE INDEX idx_patients_clinic ON patients(clinic_id)');
      await d.execute(
          'CREATE INDEX idx_sessions_clinic ON sessions(clinic_id)');
    }
    if (from < 6) {
      await d.execute('ALTER TABLE clinicians ADD COLUMN phone TEXT');
      await d.execute('ALTER TABLE clinicians ADD COLUMN qualification TEXT');
      await d.execute('ALTER TABLE clinicians ADD COLUMN registration_no TEXT');
    }
    if (from < 7) {
      await d.execute('ALTER TABLE patients ADD COLUMN synced_at TEXT');
      // A patient already tagged with a clinic came from, or went to, the
      // server. Untagged ones are this device's own and upload once a cloud
      // clinic claims them.
      await d.execute(
          'UPDATE patients SET synced_at = updated_at WHERE clinic_id IS NOT NULL');
      final batch = d.batch();
      _createPendingDeletes(batch);
      await batch.commit(noResult: true);
    }
  }

  /// Deletes made while offline, replayed against the server on the next
  /// sync so the record does not come back.
  static void _createPendingDeletes(Batch batch) {
    batch.execute('''
      CREATE TABLE pending_deletes (
        kind       TEXT NOT NULL,
        id         TEXT NOT NULL,
        clinic_id  TEXT,
        created_at TEXT NOT NULL,
        PRIMARY KEY (kind, id)
      )
    ''');
  }

  /// One row per calibration (or reset) done on this device.
  ///
  /// Calibration belongs to the device and headphone pair, so like the
  /// current calibration it stays on the device and is never synced.
  /// [details_json] holds what was done to each ear; [profile_json] is the
  /// complete calibration that resulted, so the record can be reprinted
  /// exactly later.
  static void _createCalibrationEvents(Batch batch) {
    batch.execute('''
      CREATE TABLE calibration_events (
        id           TEXT PRIMARY KEY,
        performed_at TEXT NOT NULL,
        performed_by TEXT NOT NULL,
        details_json TEXT NOT NULL,
        profile_json TEXT NOT NULL
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_calibration_events_time ON calibration_events(performed_at DESC)');
  }
}
