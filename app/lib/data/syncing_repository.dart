import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_service.dart';
import 'local_repository.dart';
import 'models/patient.dart';
import 'models/test_session.dart';
import 'repository.dart';

/// The rules for merging a downloaded record into the local database.
///
/// Extracted from the network code so the decisions can be tested directly -
/// getting these wrong loses clinical data, and "it needs a live server to
/// test" is not a good reason to leave them unverified.
class SyncMergePolicy {
  const SyncMergePolicy._();

  /// Whether a downloaded patient should replace the local copy.
  ///
  /// Last-write-wins on `updated_at`. Appropriate here because a patient row is
  /// demographic data edited by one clinician at a time, so the loser of a
  /// conflict is a stale phone number rather than a measurement. Ties keep the
  /// local copy - a clock skew should not cause pointless churn.
  static bool shouldReplacePatient({
    required Patient? local,
    required Patient remote,
  }) {
    if (local == null) return true;
    return remote.updatedAt.isAfter(local.updatedAt);
  }

  /// Whether a downloaded test session should be written locally.
  ///
  /// Only when it is not already here. A completed audiogram is evidence:
  /// silently replacing one device's recorded measurements with another
  /// device's copy would be indefensible, so existing sessions are never
  /// overwritten by a pull.
  static bool shouldImportSession({required bool existsLocally}) =>
      !existsLocally;
}

/// Outcome of a sync pass, for display in the UI.
class SyncReport {
  const SyncReport({
    this.pushed = 0,
    this.pulledPatients = 0,
    this.pulledSessions = 0,
    this.failed = 0,
    this.refused = 0,
    this.refusedReason,
    this.error,
    this.busy = false,
  });

  /// Another sync was already running; this call did nothing.
  const SyncReport.busy() : this(busy: true);

  final int pushed;
  final int pulledPatients;
  final int pulledSessions;

  /// Uploads that failed for a reason that may pass (offline, timeout).
  final int failed;

  /// Uploads the server refused, usually for lack of permission. Retrying
  /// will not help until the account's role or clinic changes.
  final int refused;
  final String? refusedReason;

  final String? error;
  final bool busy;

  bool get isEmpty =>
      pushed == 0 && pulledPatients == 0 && pulledSessions == 0;

  String get summary {
    if (busy) return 'A sync is already running';
    if (error != null) return 'Sync failed: $error';
    final parts = <String>[
      if (pushed > 0) 'sent $pushed record${pushed == 1 ? '' : 's'}',
      if (pulledPatients > 0)
        'received $pulledPatients patient${pulledPatients == 1 ? '' : 's'}',
      if (pulledSessions > 0)
        'received $pulledSessions test${pulledSessions == 1 ? '' : 's'}',
      if (failed > 0) '$failed still waiting to upload',
      if (refused > 0)
        'the server refused $refused (permission denied'
            '${refusedReason == null ? '' : ': $refusedReason'})',
    ];
    return parts.isEmpty ? 'Everything is up to date' : parts.join(', ');
  }
}

/// What became of one upload.
enum _Push { ok, failed, refused }

/// Who a sync pass runs for. Captured once at the start, so rows fetched with
/// one account's access are never tagged with another account's clinic if
/// someone signs out mid-sync.
class _SyncOwner {
  const _SyncOwner(this.userId, this.clinicId);
  final String userId;
  final String clinicId;
}

/// Mirrors the local database to the clinic's Supabase project, in both
/// directions.
///
/// ## Offline-first, on purpose
///
/// Every read is served from the local database and every write lands there
/// first. The network is best-effort: a failed upload leaves the record
/// marked unsynced (`synced_at` is null) and is retried later, and a delete
/// made offline is remembered and sent later. A test in progress must never
/// fail because the clinic's connection dropped.
///
/// ## Conflict resolution
///
/// Patients are last-write-wins on `updated_at`: a patient row is demographic
/// data edited by one clinician at a time, and the loser of a conflict is a
/// stale name or phone number rather than a measurement.
///
/// Test sessions are treated as immutable once complete: an existing local
/// session is never overwritten by the cloud copy. A recorded audiogram is
/// evidence, and silently replacing one device's measurements with another's
/// would be indefensible.
class SyncingRepository implements AudiometryRepository {
  SyncingRepository({
    required LocalRepository local,
    required SupabaseClient client,
    required AuthService auth,
  })  : _local = local,
        _client = client,
        _auth = auth;

  final LocalRepository _local;
  final SupabaseClient _client;
  final AuthService _auth;

  /// Rows asked for per request. Supabase returns at most 1,000 by default.
  static const _pageSize = 1000;

  /// Ids per `in (...)` filter, so the request URL stays short.
  static const _idsPerRequest = 100;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _syncing = false;
  DateTime? _lastSyncAt;

  /// The signed-in user and their clinic, or null when there is nothing to
  /// sync for (signed out, awaiting approval, or no clinic).
  _SyncOwner? get _owner {
    final user = _client.auth.currentUser?.id;
    final clinic = _auth.currentClinician?.clinicId;
    if (user == null || clinic == null || !_auth.role.canViewRecords) {
      return null;
    }
    return _SyncOwner(user, clinic);
  }

  bool _stillOwner(_SyncOwner o) {
    final now = _owner;
    return now != null && now.userId == o.userId && now.clinicId == o.clinicId;
  }

  /// Starts syncing automatically whenever the device regains connectivity.
  ///
  /// A clinic that spends the morning offline should not depend on someone
  /// remembering to press "Sync now": the queue drains itself as soon as
  /// there is a network again.
  void startAutoSync() {
    _connectivitySub ??= Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (!online || _owner == null) return;
      unawaited(syncNow());
    });
  }

  void dispose() {
    _connectivitySub?.cancel();
    _connectivitySub = null;
  }

  // ---------------------------------------------------------------- patients

  @override
  Future<List<Patient>> listPatients({String? query}) =>
      _local.listPatients(query: query);

  @override
  Future<Patient?> getPatient(String id) => _local.getPatient(id);

  @override
  Future<Patient> upsertPatient(Patient patient) async {
    final saved = await _local.upsertPatient(patient);
    final owner = _owner;
    if (owner != null &&
        await _tryPush(() => _pushPatient(saved, owner)) == _Push.ok) {
      await _local.markPatientSynced(saved.id, DateTime.now());
    }
    return saved;
  }

  @override
  Future<void> deletePatient(String id) async {
    await _local.deletePatient(id);
    await _deleteRemote('patients', id);
  }

  // ---------------------------------------------------------------- sessions

  @override
  Future<List<TestSession>> listSessions(String patientId) =>
      _local.listSessions(patientId);

  @override
  Future<TestSession?> getSession(String id) => _local.getSession(id);

  @override
  Future<TestSession> saveSession(TestSession session) async {
    final saved = await _local.saveSession(session);

    // Only completed tests are uploaded. A partial session is a local draft.
    final owner = _owner;
    if (!saved.isComplete || owner == null) return saved;

    if (await _tryPush(() => _pushSession(saved, owner)) != _Push.ok) {
      return saved;
    }
    final now = DateTime.now();
    await _local.markSessionSynced(saved.id, now);
    return saved.copyWith(syncedAt: now);
  }

  @override
  Future<void> deleteSession(String id) async {
    await _local.deleteSession(id);
    await _deleteRemote('sessions', id);
  }

  @override
  Future<List<TestSession>> pendingSync() => _local.pendingSync();

  /// Deletes on the server, or remembers to when it cannot be reached. A
  /// refusal (not an admin) is not remembered: retrying would not help.
  Future<void> _deleteRemote(String table, String id) async {
    final owner = _owner;
    final result = owner == null
        ? _Push.failed
        : await _tryPush(() => _client.from(table).delete().eq('id', id));
    if (result == _Push.failed) await _local.addPendingDelete(table, id);
  }

  // -------------------------------------------------------------------- sync

  /// Syncs unless the last sync was less than [maxAge] ago. For screens that
  /// refresh on every visit; "Sync now" calls [syncNow] directly.
  Future<SyncReport?> syncIfStale(
      {Duration maxAge = const Duration(minutes: 2)}) async {
    final last = _lastSyncAt;
    if (last != null && DateTime.now().difference(last) < maxAge) return null;
    return syncNow();
  }

  /// Sends anything queued, then downloads everything this user can see.
  ///
  /// Safe to call at any time; a call while a sync is running returns
  /// [SyncReport.busy] at once.
  Future<SyncReport> syncNow() async {
    final owner = _owner;
    if (owner == null) {
      return const SyncReport(error: 'not signed in to a clinic');
    }
    if (_syncing) return const SyncReport.busy();
    _syncing = true;

    try {
      final counts = _Counts();
      // Order matters:
      //  1. Deletes made offline go first, so the pull cannot bring the
      //     records back.
      //  2. The pull comes before any upload. It tags what the server
      //     confirms belongs to this clinic, and applies last-write-wins to
      //     patients, so a stale local edit is replaced rather than uploaded
      //     over a newer one.
      //  3. Only then are untagged records claimed: what is left untagged is
      //     this device's own.
      //  4. Then patients, then tests (a test needs its patient first).
      await _replayDeletes(owner, counts);
      final (patients, sessions) = await _pullFromCloud(owner);
      await _claimUntagged(owner);
      await _pushPendingPatients(owner, counts);
      await _pushPendingSessions(owner, counts);
      _lastSyncAt = DateTime.now();
      return SyncReport(
        pushed: counts.pushed,
        failed: counts.failed,
        refused: counts.refused,
        refusedReason: counts.refusedReason,
        pulledPatients: patients,
        pulledSessions: sessions,
      );
    } on _OwnerChanged {
      return const SyncReport(error: 'the signed-in account changed');
    } catch (e) {
      return SyncReport(error: '$e');
    } finally {
      _syncing = false;
    }
  }

  void _checkOwner(_SyncOwner owner) {
    if (!_stillOwner(owner)) throw const _OwnerChanged();
  }

  /// Records on this device that belong to no clinic and never reached the
  /// server (recorded in local-only mode, or before records carried a clinic)
  /// would otherwise stay hidden and never sync. Someone who may record tests
  /// in this clinic claims them, so they upload with this sync.
  Future<void> _claimUntagged(_SyncOwner owner) async {
    if (!_auth.role.canRunTests) return;
    final (patientIds, sessionIds) = await _local.untaggedUnsynced();
    if (patientIds.isEmpty && sessionIds.isEmpty) return;
    _checkOwner(owner);
    await _local.claimForClinic(owner.clinicId,
        patientIds: patientIds, sessionIds: sessionIds);
  }

  Future<void> _replayDeletes(_SyncOwner owner, _Counts counts) async {
    for (final (table, id) in await _local.pendingDeletes()) {
      _checkOwner(owner);
      final result =
          await _tryPush(() => _client.from(table).delete().eq('id', id));
      if (result == _Push.failed) {
        counts.failed++;
        continue;
      }
      // Done, or refused for good: either way, stop retrying.
      await _local.clearPendingDelete(table, id);
      if (result == _Push.ok) counts.pushed++;
    }
  }

  Future<void> _pushPendingPatients(_SyncOwner owner, _Counts counts) async {
    if (!_auth.role.canEditPatients) return;
    for (final patient in await _local.pendingPatients()) {
      _checkOwner(owner);
      counts.add(await _tryPush(() => _pushPatient(patient, owner),
          onRefused: counts.refusedBecause));
      if (counts.last == _Push.ok) {
        await _local.markPatientSynced(patient.id, DateTime.now());
      }
    }
  }

  Future<void> _pushPendingSessions(_SyncOwner owner, _Counts counts) async {
    if (!_auth.role.canRunTests) return;
    for (final session in await _local.pendingSync()) {
      _checkOwner(owner);
      counts.add(await _tryPush(() => _pushSession(session, owner),
          onRefused: counts.refusedBecause));
      if (counts.last == _Push.ok) {
        await _local.markSessionSynced(session.id, DateTime.now());
      }
    }
  }

  /// Every row of [table] this user can read, a page at a time.
  Future<List<Map<String, dynamic>>> _fetchAll(String table) async {
    final rows = <Map<String, dynamic>>[];
    for (var from = 0;; from += _pageSize) {
      final page = await _client
          .from(table)
          .select()
          .order('id')
          .range(from, from + _pageSize - 1) as List<dynamic>;
      rows.addAll(page.cast<Map<String, dynamic>>());
      if (page.length < _pageSize) return rows;
    }
  }

  /// Downloads records this user can see and merges them into the local
  /// database. Returns (patientsWritten, sessionsWritten).
  ///
  /// Row-level security decides what comes back: the query asks for
  /// everything and the server returns only this clinic's rows.
  Future<(int, int)> _pullFromCloud(_SyncOwner owner) async {
    var patientsWritten = 0, sessionsWritten = 0;

    // A record deleted here whose delete has not reached the server yet must
    // not come back.
    final deleted = {
      for (final (table, id) in await _local.pendingDeletes()) '$table/$id',
    };

    // --- patients: last-write-wins on updated_at ---------------------------
    final remotePatients = [
      for (final r in await _fetchAll('patients'))
        if (!deleted.contains('patients/${r['id']}')) r,
    ];
    _checkOwner(owner);
    final patientIds = [for (final r in remotePatients) r['id'] as String];
    await _local.claimForClinic(owner.clinicId, patientIds: patientIds);
    final stamps = await _local.patientStamps(patientIds);

    for (final row in remotePatients) {
      final remote = Patient.fromMap(_stripCloudColumns(row));
      final stamp = stamps[remote.id];
      final local = stamp == null
          ? null
          : remote.copyWith(updatedAt: DateTime.tryParse(stamp));
      if (!SyncMergePolicy.shouldReplacePatient(local: local, remote: remote)) {
        continue;
      }
      _checkOwner(owner);
      try {
        await _local.storeSyncedPatient(remote);
        patientsWritten++;
      } catch (e) {
        // For example the same id stored here under another clinic. One bad
        // row must not stop the rest from syncing.
        if (kDebugMode) debugPrint('Auris sync: could not store a patient - $e');
      }
    }

    // --- sessions: never overwrite an existing local measurement -----------
    final remoteSessions = [
      for (final r in await _fetchAll('sessions'))
        if (!deleted.contains('sessions/${r['id']}') &&
            !deleted.contains('patients/${r['patient_id']}'))
          r,
    ];
    _checkOwner(owner);
    final sessionIds = [for (final r in remoteSessions) r['id'] as String];
    await _local.claimForClinic(owner.clinicId, sessionIds: sessionIds);
    final present = await _local.existingIds('sessions', sessionIds);
    final incoming = [
      for (final row in remoteSessions)
        if (SyncMergePolicy.shouldImportSession(
            existsLocally: present.contains(row['id'])))
          row,
    ];
    if (incoming.isEmpty) return (patientsWritten, sessionsWritten);

    // Thresholds for the new sessions only, a batch of ids at a time, each
    // batch paged too: a hundred tests have well over 1,000 points, and a
    // test stored with only some of its points would stay that way.
    final pointsBySession = <String, List<ThresholdPoint>>{};
    for (var i = 0; i < incoming.length; i += _idsPerRequest) {
      final ids = [
        for (final row in incoming.skip(i).take(_idsPerRequest))
          row['id'] as String,
      ];
      for (var from = 0;; from += _pageSize) {
        final page = await _client
            .from('thresholds')
            .select()
            .inFilter('session_id', ids)
            .order('session_id')
            .order('ear')
            .order('frequency_hz')
            .range(from, from + _pageSize - 1) as List<dynamic>;
        for (final row in page.cast<Map<String, dynamic>>()) {
          pointsBySession
              .putIfAbsent(row['session_id'] as String, () => [])
              .add(ThresholdPoint.fromMap(_stripCloudColumns(row)));
        }
        if (page.length < _pageSize) break;
      }
    }

    final knownPatients = await _local.existingIds(
        'patients', {for (final r in incoming) r['patient_id'] as String});
    for (final raw in incoming) {
      final row = _stripCloudColumns(raw);
      final id = row['id'] as String;
      final points = pointsBySession[id] ?? const <ThresholdPoint>[];
      // A test is uploaded in two steps (the test, then its points). One
      // caught between them is picked up complete on the next sync rather
      // than stored without its points, since a stored test is never
      // replaced. After a few minutes a test with no points really has none
      // (every frequency skipped) and is stored as it is.
      if (readFlag(row['is_complete']) &&
          points.isEmpty &&
          _uploadedRecently(row['synced_at'])) {
        continue;
      }
      // A test whose patient has not arrived would break the local foreign
      // key; it is picked up on the next sync.
      if (!knownPatients.contains(row['patient_id'])) continue;
      _checkOwner(owner);
      try {
        await _local.saveSession(TestSession.fromMap(row, points));
        sessionsWritten++;
      } catch (e) {
        if (kDebugMode) debugPrint('Auris sync: could not store a test - $e');
      }
    }

    return (patientsWritten, sessionsWritten);
  }

  /// Whether the server stamped [syncedAt] in the last few minutes.
  static bool _uploadedRecently(Object? syncedAt) {
    final at = syncedAt is String ? DateTime.tryParse(syncedAt) : null;
    if (at == null) return false;
    return DateTime.now().toUtc().difference(at.toUtc()) <
        const Duration(minutes: 10);
  }

  // ------------------------------------------------------------------ pushes

  Future<void> _pushPatient(Patient patient, _SyncOwner owner) async {
    await _client.from('patients').upsert({
      ...patient.toMap(),
      'owner_id': owner.userId,
      'clinic_id': owner.clinicId,
    });
  }

  Future<void> _pushSession(TestSession session, _SyncOwner owner) async {
    // A patient registered offline must reach the server before their test,
    // or the test is refused by the foreign key.
    if (await _local.patientNeedsUpload(session.patientId)) {
      final patient = await _local.getPatient(session.patientId);
      if (patient != null) {
        await _pushPatient(patient, owner);
        await _local.markPatientSynced(patient.id, DateTime.now());
      }
    }

    // synced_at is left out: the server stamps it on first upload, rather
    // than trusting a possibly wrong device clock.
    final row = {
      ...session.toMap(),
      'owner_id': owner.userId,
      'clinic_id': owner.clinicId,
    }..remove('synced_at');
    await _client.from('sessions').upsert(row);

    if (session.points.isEmpty) return;
    await _client.from('thresholds').upsert(
      [
        for (final point in session.points)
          {
            ...point.toMap(session.id),
            'owner_id': owner.userId,
            'clinic_id': owner.clinicId,
          },
      ],
      onConflict: 'session_id,ear,frequency_hz',
    );
  }

  /// Removes columns that exist only in Postgres, so the row can be handed to
  /// the local models unchanged.
  Map<String, Object?> _stripCloudColumns(Map<String, dynamic> row) {
    final copy = Map<String, Object?>.from(row);
    copy.remove('owner_id');
    copy.remove('clinic_id');
    return copy;
  }

  /// Runs a network write, swallowing failures so local work always succeeds.
  Future<_Push> _tryPush(Future<void> Function() push,
      {void Function(String reason)? onRefused}) async {
    try {
      await push();
      return _Push.ok;
    } on PostgrestException catch (e) {
      // A row-level security rejection is a permission problem, not a network
      // one, and retrying will not help.
      onRefused?.call(e.message);
      if (kDebugMode) debugPrint('Auris sync: server refused - ${e.message}');
      return _Push.refused;
    } catch (e) {
      // Offline, DNS failure, timeout. Expected, not exceptional.
      if (kDebugMode) debugPrint('Auris sync: upload failed - $e');
      return _Push.failed;
    }
  }
}

class _Counts {
  int pushed = 0, failed = 0, refused = 0;
  String? refusedReason;
  _Push? last;

  void add(_Push result) {
    last = result;
    switch (result) {
      case _Push.ok:
        pushed++;
      case _Push.failed:
        failed++;
      case _Push.refused:
        refused++;
    }
  }

  void refusedBecause(String reason) => refusedReason ??= reason;
}

class _OwnerChanged implements Exception {
  const _OwnerChanged();
}
