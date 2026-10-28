import 'models/patient.dart';
import 'models/test_session.dart';

/// Storage contract for patients and their test history.
///
/// The app talks only to this interface. [LocalRepository] implements it
/// against on-device SQLite; [SyncingRepository] wraps a local repository and
/// mirrors writes to the clinic's Supabase project when one is configured.
abstract class AudiometryRepository {
  /// Patients, newest first. [query] filters on name or clinic reference.
  Future<List<Patient>> listPatients({String? query});

  Future<Patient?> getPatient(String id);

  /// Inserts or updates by primary key.
  Future<Patient> upsertPatient(Patient patient);

  /// Deletes a patient and, by cascade, every test belonging to them.
  Future<void> deletePatient(String id);

  /// Tests for one patient, most recent first.
  Future<List<TestSession>> listSessions(String patientId);

  Future<TestSession?> getSession(String id);

  Future<TestSession> saveSession(TestSession session);

  Future<void> deleteSession(String id);

  /// Sessions not yet mirrored to the cloud. Empty when sync is disabled.
  Future<List<TestSession>> pendingSync();
}
