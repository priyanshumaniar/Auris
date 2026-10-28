import 'dart:math';

import 'package:sqflite/sqflite.dart';

import 'local_database.dart';
import 'models/patient.dart';
import 'models/test_session.dart';
import 'repository.dart';

/// Which cached records the signed-in user may see on this device.
///
/// The SQLite database is shared by every account on the device. Without a
/// scope, anyone signing in would see everything cached there, including
/// records of a clinic they do not belong to.
class RecordScope {
  const RecordScope._(this.clinicId, {required this.visible});

  /// Local-only mode: the device is the clinic, and its own records carry no
  /// clinic id.
  static const RecordScope device = RecordScope._(null, visible: true);

  /// Nothing is visible and nothing may be written: nobody signed in, an
  /// account awaiting approval, or a cloud account whose clinic is unknown.
  static const RecordScope none = RecordScope._(null, visible: false);

  /// Cloud mode: only records of this clinic.
  const RecordScope.clinic(String this.clinicId) : visible = true;

  /// The clinic id stored on rows in this scope. Null for [device].
  final String? clinicId;

  /// False for [none].
  final bool visible;
}

/// [AudiometryRepository] backed by on-device SQLite.
///
/// Every read and write goes through [scope], so the records one account can
/// reach are exactly those of its own clinic.
class LocalRepository implements AudiometryRepository {
  LocalRepository(this._local, {RecordScope Function()? scope})
      : scope = scope ?? _deviceScope;

  static RecordScope _deviceScope() => RecordScope.device;

  final LocalDatabase _local;
  Database get _db => _local.db;

  /// Read at every call, so it follows whoever is signed in.
  RecordScope Function() scope;

  /// SQL condition and arguments limiting a table to the current scope.
  /// Spelled out for the device scope rather than `IS ?` with a null
  /// argument, which sqflite warns about and will stop accepting.
  (String, List<Object>) _where(RecordScope s) {
    final clinic = s.clinicId;
    return clinic == null
        ? ('clinic_id IS NULL', const [])
        : ('clinic_id = ?', [clinic]);
  }

  RecordScope _writableScope(String action) {
    final s = scope();
    if (!s.visible) {
      throw StateError('No account with access is signed in; cannot $action.');
    }
    return s;
  }

  // --------------------------------------------------------------- patients

  @override
  Future<List<Patient>> listPatients({String? query}) async {
    final s = scope();
    if (!s.visible) return const [];
    final (clause, args) = _where(s);
    final trimmed = query?.trim();
    final hasQuery = trimmed != null && trimmed.isNotEmpty;
    final rows = await _db.query(
      'patients',
      where: hasQuery
          ? '$clause AND (full_name LIKE ? OR clinic_ref LIKE ?)'
          : clause,
      whereArgs: hasQuery ? [...args, '%$trimmed%', '%$trimmed%'] : args,
      orderBy: 'updated_at DESC',
    );
    return rows.map(Patient.fromMap).toList();
  }

  @override
  Future<Patient?> getPatient(String id) async {
    final s = scope();
    if (!s.visible) return null;
    final (clause, args) = _where(s);
    final rows = await _db.query('patients',
        where: 'id = ? AND $clause', whereArgs: [id, ...args], limit: 1);
    return rows.isEmpty ? null : Patient.fromMap(rows.first);
  }

  /// Inserts a new patient or updates an existing one in place.
  ///
  /// Deliberately not `INSERT OR REPLACE`: SQLite carries out a replace as a
  /// delete followed by an insert, and the delete cascades to every one of
  /// the patient's tests. Editing a phone number must not erase a history.
  @override
  Future<Patient> upsertPatient(Patient patient) =>
      _upsertPatient(patient, syncedAt: null);

  /// Stores a patient that came from the server: it needs no upload.
  Future<Patient> storeSyncedPatient(Patient patient) =>
      _upsertPatient(patient, syncedAt: DateTime.now());

  Future<Patient> _upsertPatient(Patient patient,
      {required DateTime? syncedAt}) async {
    final s = _writableScope('save a patient');
    final (clause, args) = _where(s);
    final values = {
      ...patient.toMap(),
      'clinic_id': s.clinicId,
      'synced_at': syncedAt?.toIso8601String(),
    };
    await _db.transaction((txn) async {
      // Only a row in this scope (or not yet tagged) is updated, so a record
      // of another clinic is never re-tagged.
      final updated = await txn.update('patients', values,
          where: 'id = ? AND ($clause OR clinic_id IS NULL)',
          whereArgs: [patient.id, ...args]);
      if (updated == 0) await txn.insert('patients', values);
    });
    return patient;
  }

  @override
  Future<void> deletePatient(String id) async {
    final s = _writableScope('delete a patient');
    final (clause, args) = _where(s);
    // ON DELETE CASCADE removes the patient's sessions and thresholds too.
    await _db.delete('patients',
        where: 'id = ? AND $clause', whereArgs: [id, ...args]);
  }

  // --------------------------------------------------------------- sessions

  @override
  Future<List<TestSession>> listSessions(String patientId) async {
    final s = scope();
    if (!s.visible) return const [];
    final (clause, args) = _where(s);
    final rows = await _db.query(
      'sessions',
      where: 'patient_id = ? AND $clause',
      whereArgs: [patientId, ...args],
      orderBy: 'tested_at DESC',
    );
    return _hydrate(rows);
  }

  @override
  Future<TestSession?> getSession(String id) async {
    final s = scope();
    if (!s.visible) return null;
    final (clause, args) = _where(s);
    final rows = await _db.query('sessions',
        where: 'id = ? AND $clause', whereArgs: [id, ...args], limit: 1);
    if (rows.isEmpty) return null;
    return (await _hydrate(rows)).first;
  }

  @override
  Future<TestSession> saveSession(TestSession session) async {
    final s = _writableScope('save a test');
    final (clause, args) = _where(s);
    final values = {...session.toMap(), 'clinic_id': s.clinicId};
    await _db.transaction((txn) async {
      final updated = await txn.update('sessions', values,
          where: 'id = ? AND ($clause OR clinic_id IS NULL)',
          whereArgs: [session.id, ...args]);
      if (updated == 0) await txn.insert('sessions', values);
      // Replace the whole point set: a retest of the same session is a
      // correction, not an addition.
      await txn.delete('thresholds',
          where: 'session_id = ?', whereArgs: [session.id]);
      final batch = txn.batch();
      for (final point in session.points) {
        batch.insert('thresholds', point.toMap(session.id),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
    return session;
  }

  @override
  Future<void> deleteSession(String id) async {
    final s = _writableScope('delete a test');
    final (clause, args) = _where(s);
    await _db.delete('sessions',
        where: 'id = ? AND $clause', whereArgs: [id, ...args]);
  }

  @override
  Future<List<TestSession>> pendingSync() async {
    final s = scope();
    if (!s.visible) return const [];
    final (clause, args) = _where(s);
    final rows = await _db.query(
      'sessions',
      where: 'synced_at IS NULL AND is_complete = 1 AND $clause',
      whereArgs: args,
      orderBy: 'tested_at ASC',
    );
    return _hydrate(rows);
  }

  // ------------------------------------------------------------- sync state

  /// Marks a test as uploaded, without rewriting it or its points.
  Future<void> markSessionSynced(String id, DateTime at) => _db.update(
      'sessions', {'synced_at': at.toIso8601String()},
      where: 'id = ?', whereArgs: [id]);

  /// Marks a patient as uploaded.
  Future<void> markPatientSynced(String id, DateTime at) => _db.update(
      'patients', {'synced_at': at.toIso8601String()},
      where: 'id = ?', whereArgs: [id]);

  /// Patients in the current scope added or edited since their last upload.
  Future<List<Patient>> pendingPatients() async {
    final s = scope();
    if (!s.visible) return const [];
    final (clause, args) = _where(s);
    final rows = await _db.query('patients',
        where: 'synced_at IS NULL AND $clause',
        whereArgs: args,
        orderBy: 'updated_at ASC');
    return rows.map(Patient.fromMap).toList();
  }

  /// Whether [patientId] still has changes the server has not seen.
  Future<bool> patientNeedsUpload(String patientId) async {
    final rows = await _db.query('patients',
        columns: ['synced_at'], where: 'id = ?', whereArgs: [patientId]);
    return rows.isNotEmpty && rows.first['synced_at'] == null;
  }

  /// `updated_at` of each of [ids] stored on this device, in one query per
  /// 500 ids. Ids not stored here are missing from the result.
  Future<Map<String, String>> patientStamps(Iterable<String> ids) async {
    final result = <String, String>{};
    await _inChunks(ids.toList(), (chunk, marks) async {
      for (final r in await _db.query('patients',
          columns: ['id', 'updated_at'],
          where: 'id IN ($marks)',
          whereArgs: chunk)) {
        result[r['id'] as String] = r['updated_at'] as String;
      }
    });
    return result;
  }

  /// Which of [ids] exist in [table] on this device.
  Future<Set<String>> existingIds(String table, Iterable<String> ids) async {
    assert(table == 'patients' || table == 'sessions');
    final result = <String>{};
    await _inChunks(ids.toList(), (chunk, marks) async {
      for (final r in await _db.query(table,
          columns: ['id'], where: 'id IN ($marks)', whereArgs: chunk)) {
        result.add(r['id'] as String);
      }
    });
    return result;
  }

  /// Remembers a delete the server has not confirmed yet.
  Future<void> addPendingDelete(String kind, String id) {
    final s = scope();
    return _db.insert(
      'pending_deletes',
      {
        'kind': kind,
        'id': id,
        'clinic_id': s.clinicId,
        'created_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Deletes still to be sent for the current scope, as (kind, id).
  Future<List<(String, String)>> pendingDeletes() async {
    final s = scope();
    if (!s.visible) return const [];
    final (clause, args) = _where(s);
    final rows = await _db.query('pending_deletes',
        where: clause, whereArgs: args, orderBy: 'created_at ASC');
    return [for (final r in rows) (r['kind'] as String, r['id'] as String)];
  }

  Future<void> clearPendingDelete(String kind, String id) => _db.delete(
      'pending_deletes',
      where: 'kind = ? AND id = ?', whereArgs: [kind, id]);

  static Future<void> _inChunks(List<String> ids,
      Future<void> Function(List<String> chunk, String marks) run) async {
    // Chunked to stay under SQLite's limit on bound parameters.
    for (var i = 0; i < ids.length; i += 500) {
      final chunk = ids.sublist(i, min(i + 500, ids.length));
      await run(chunk, List.filled(chunk.length, '?').join(','));
    }
  }

  // ------------------------------------------------------------ cloud claim

  /// Tags records that carry no clinic yet as belonging to [clinicId].
  ///
  /// Used by sync for records the server has just confirmed belong to that
  /// clinic (row-level security only returns the user's own clinic's rows),
  /// and for unsynced tests recorded on this device before records were
  /// tagged. Never touches a record that already belongs to a clinic.
  Future<void> claimForClinic(
    String clinicId, {
    Iterable<String> patientIds = const [],
    Iterable<String> sessionIds = const [],
  }) async {
    Future<void> claim(String table, List<String> ids) =>
        _inChunks(ids, (chunk, marks) => _db.update(
            table, {'clinic_id': clinicId},
            where: 'clinic_id IS NULL AND id IN ($marks)', whereArgs: chunk));

    await claim('patients', patientIds.toList());
    await claim('sessions', sessionIds.toList());
  }

  /// Patients and tests on this device that belong to no clinic and never
  /// reached the server: recorded in local-only mode, or before records were
  /// tagged. Only this device can still upload them.
  ///
  /// A patient with a test that did reach the server is left alone: it was
  /// downloaded before records carried a clinic, and the server, not this
  /// device, says which clinic it belongs to (the pull tags it if it is the
  /// signed-in clinic's).
  Future<(List<String>, List<String>)> untaggedUnsynced() async {
    final sessions = await _db.query('sessions',
        columns: ['id', 'patient_id'],
        where: 'clinic_id IS NULL AND synced_at IS NULL');
    final patients = await _db.query('patients',
        columns: ['id'],
        where: 'clinic_id IS NULL AND NOT EXISTS (SELECT 1 FROM sessions s '
            'WHERE s.patient_id = patients.id AND s.synced_at IS NOT NULL)');
    return (
      {
        for (final r in patients) r['id'] as String,
        for (final r in sessions) r['patient_id'] as String,
      }.toList(),
      [for (final r in sessions) r['id'] as String],
    );
  }

  /// Loads the threshold rows for [sessionRows] and assembles full sessions.
  ///
  /// Fetches every point in one query rather than one query per session, so
  /// listing a patient's history stays two round trips regardless of how many
  /// tests they have.
  Future<List<TestSession>> _hydrate(List<Map<String, Object?>> sessionRows) async {
    if (sessionRows.isEmpty) return [];

    final ids = sessionRows.map((r) => r['id'] as String).toList();
    final placeholders = List.filled(ids.length, '?').join(',');
    final pointRows = await _db.query(
      'thresholds',
      where: 'session_id IN ($placeholders)',
      whereArgs: ids,
      orderBy: 'frequency_hz ASC',
    );

    final bySession = <String, List<ThresholdPoint>>{};
    for (final row in pointRows) {
      bySession
          .putIfAbsent(row['session_id'] as String, () => [])
          .add(ThresholdPoint.fromMap(row));
    }

    return sessionRows
        .map((row) => TestSession.fromMap(row, bySession[row['id']] ?? const []))
        .toList();
  }
}
