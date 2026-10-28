import 'auth_service.dart';
import 'models/clinic_role.dart';
import 'models/patient.dart';
import 'models/test_session.dart';
import 'repository.dart';

/// Wraps a repository and refuses writes the signed-in user's role forbids.
///
/// This is the middle of the three enforcement layers described on
/// [ClinicRole]. The UI hides what a role cannot do, and Postgres row-level
/// security is the real boundary; this sits between them so that a screen with
/// a missing check fails loudly during development instead of quietly writing
/// data that the server will later reject.
///
/// Reads are refused to an account awaiting approval: it gets empty results,
/// as if there were no records. Every approved role may read.
class PermissionedRepository implements AudiometryRepository {
  PermissionedRepository({
    required AudiometryRepository inner,
    required AuthService auth,
  })  : _inner = inner,
        _auth = auth;

  final AudiometryRepository _inner;
  final AuthService _auth;

  ClinicRole get _role => _auth.role;

  void _require(bool allowed, String action) {
    if (!allowed) throw PermissionDeniedException(action);
  }

  // ------------------------------------------------------------------ reads

  bool get _canRead => _role.canViewRecords;

  @override
  Future<List<Patient>> listPatients({String? query}) async =>
      _canRead ? await _inner.listPatients(query: query) : const <Patient>[];

  @override
  Future<Patient?> getPatient(String id) async =>
      _canRead ? await _inner.getPatient(id) : null;

  @override
  Future<List<TestSession>> listSessions(String patientId) async =>
      _canRead ? await _inner.listSessions(patientId) : const <TestSession>[];

  @override
  Future<TestSession?> getSession(String id) async =>
      _canRead ? await _inner.getSession(id) : null;

  @override
  Future<List<TestSession>> pendingSync() async =>
      _canRead ? await _inner.pendingSync() : const <TestSession>[];

  // ----------------------------------------------------------------- writes

  @override
  Future<Patient> upsertPatient(Patient patient) async {
    _require(_role.canEditPatients, 'add or edit patient records');
    return _inner.upsertPatient(patient);
  }

  @override
  Future<void> deletePatient(String id) async {
    // Deleting a patient cascades to every test they have ever had.
    _require(_role.canDeletePatients, 'delete patient records');
    return _inner.deletePatient(id);
  }

  @override
  Future<TestSession> saveSession(TestSession session) async {
    _require(_role.canRunTests, 'record hearing tests');
    return _inner.saveSession(session);
  }

  @override
  Future<void> deleteSession(String id) async {
    _require(_role.canDeleteSessions, 'delete test records');
    return _inner.deleteSession(id);
  }
}
