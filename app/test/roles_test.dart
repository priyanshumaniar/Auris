import 'package:auris/core/audiometry/audiometry.dart';
import 'package:auris/core/audiometry/calibration.dart';
import 'package:auris/data/account_service.dart';
import 'package:auris/data/auth_service.dart';
import 'package:auris/data/local_database.dart';
import 'package:auris/data/local_repository.dart';
import 'package:auris/data/models/clinic.dart';
import 'package:auris/data/models/clinic_role.dart';
import 'package:auris/data/models/patient.dart';
import 'package:auris/data/models/test_session.dart';
import 'package:auris/data/permissioned_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for a signed-in user at a given role.
class _FakeAuth implements AuthService {
  _FakeAuth(this._role);

  ClinicRole _role;
  set roleValue(ClinicRole value) => _role = value;

  @override
  ClinicRole get role => _role;

  @override
  Clinician? get currentClinician => Clinician(
        id: 'u1',
        username: 'user',
        displayName: 'Test User',
        role: _role,
      );

  @override
  bool get isSignedIn => true;

  @override
  Future<Clinician> signIn({required String username, required String password}) =>
      throw UnimplementedError();

  @override
  Future<Clinician> signUp({
    required String username,
    required String displayName,
    required String password,
    ClinicRole? role,
    String? joinCode,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> signOut() async {}
}

void main() {
  // compute() needs a binding for the isolate handshake used by password
  // hashing in LocalAuthService.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('role capabilities', () {
    test('admin can do everything', () {
      const r = ClinicRole.admin;
      expect(r.canRegisterPatients, isTrue);
      expect(r.canEditPatients, isTrue);
      expect(r.canDeletePatients, isTrue);
      expect(r.canRunTests, isTrue);
      expect(r.canCalibrate, isTrue);
      expect(r.canManageUsers, isTrue);
    });

    test('clinician can test and edit but not delete or manage users', () {
      const r = ClinicRole.clinician;
      expect(r.canRegisterPatients, isTrue);
      expect(r.canEditPatients, isTrue);
      expect(r.canRunTests, isTrue);
      expect(r.canCalibrate, isTrue);
      expect(r.canDeletePatients, isFalse);
      expect(r.canDeleteSessions, isFalse);
      expect(r.canManageUsers, isFalse);
    });

    test('viewer can only read and export', () {
      const r = ClinicRole.viewer;
      expect(r.canViewRecords, isTrue);
      expect(r.canExportReports, isTrue);
      expect(r.canRegisterPatients, isFalse);
      expect(r.canEditPatients, isFalse);
      expect(r.canRunTests, isFalse);
      expect(r.canCalibrate, isFalse);
      expect(r.canDeletePatients, isFalse);
      expect(r.canManageUsers, isFalse);
    });

    test('a super admin manages clinics and acts as admin in a home clinic',
        () {
      const r = ClinicRole.superAdmin;
      expect(r.canManageClinics, isTrue);
      expect(r.canManageUsers, isTrue);
      expect(r.canViewRecords, isTrue);
      expect(r.canRunTests, isTrue);
      expect(r.canDeletePatients, isTrue);
      expect(ClinicRole.admin.canManageClinics, isFalse,
          reason: 'a clinic admin manages only their own clinic');
      expect(ClinicRole.assignable, isNot(contains(ClinicRole.superAdmin)),
          reason: 'super admin is granted only with SQL, never from the app');
      expect(ClinicRole.fromId('super_admin'), ClinicRole.superAdmin);
    });

    test('an account awaiting approval can do nothing', () {
      const r = ClinicRole.pending;
      expect(r.canViewRecords, isFalse);
      expect(r.canExportReports, isFalse);
      expect(r.canRegisterPatients, isFalse);
      expect(r.canEditPatients, isFalse);
      expect(r.canRunTests, isFalse);
      expect(r.canCalibrate, isFalse);
      expect(r.canDeletePatients, isFalse);
      expect(r.canManageUsers, isFalse);
      expect(ClinicRole.assignable, isNot(contains(ClinicRole.pending)));
    });

    test('an unknown role id fails closed to no access', () {
      // A role added by a newer version, or a corrupted row, must not be
      // interpreted as more access than it should have.
      expect(ClinicRole.fromId('superuser'), ClinicRole.pending);
      expect(ClinicRole.fromId(null), ClinicRole.pending);
      expect(ClinicRole.fromId(''), ClinicRole.pending);
      expect(ClinicRole.fromId('admin'), ClinicRole.admin);
      expect(ClinicRole.fromId('pending'), ClinicRole.pending);
    });

    test('role ids are stable', () {
      // These strings are persisted in SQLite and Postgres - renaming one
      // would silently demote every existing user.
      expect(ClinicRole.admin.id, 'admin');
      expect(ClinicRole.clinician.id, 'clinician');
      expect(ClinicRole.viewer.id, 'viewer');
      expect(ClinicRole.pending.id, 'pending');
      expect(ClinicRole.superAdmin.id, 'super_admin');
    });
  });

  group('PermissionedRepository', () {
    late LocalDatabase database;
    late LocalRepository inner;
    late _FakeAuth auth;
    late PermissionedRepository repo;

    final now = DateTime(2026, 5, 1);
    final patient = Patient(
      id: 'p1',
      fullName: 'Test Patient',
      ageYears: 40,
      sex: 'Female',
      createdAt: now,
      updatedAt: now,
    );
    final session = TestSession(
      id: 's1',
      patientId: 'p1',
      testedAt: now,
      clinicianName: 'Dr. Example',
      isComplete: true,
      calibration: const CalibrationProfile(),
      points: const [
        ThresholdPoint(
            ear: Ear.right,
            frequencyHz: 1000,
            thresholdDbHl: 20,
            noResponse: false),
      ],
    );

    setUp(() async {
      database = await LocalDatabase.openInMemory();
      inner = LocalRepository(database);
      auth = _FakeAuth(ClinicRole.admin);
      repo = PermissionedRepository(inner: inner, auth: auth);
      await inner.upsertPatient(patient);
    });

    tearDown(() async => database.close());

    test('admin may write and delete', () async {
      auth.roleValue = ClinicRole.admin;
      await repo.upsertPatient(patient.copyWith(fullName: 'Renamed'));
      await repo.saveSession(session);
      await repo.deleteSession('s1');
      await repo.deletePatient('p1');
      expect(await repo.getPatient('p1'), isNull);
    });

    test('clinician may write but not delete', () async {
      auth.roleValue = ClinicRole.clinician;

      await repo.upsertPatient(patient.copyWith(fullName: 'Renamed'));
      await repo.saveSession(session);

      expect(() => repo.deletePatient('p1'),
          throwsA(isA<PermissionDeniedException>()));
      expect(() => repo.deleteSession('s1'),
          throwsA(isA<PermissionDeniedException>()));

      // The blocked deletes must not have happened.
      expect(await repo.getPatient('p1'), isNotNull);
      expect(await repo.getSession('s1'), isNotNull);
    });

    test('viewer may read but not write', () async {
      await inner.saveSession(session);
      auth.roleValue = ClinicRole.viewer;

      expect(await repo.listPatients(), hasLength(1));
      expect(await repo.getPatient('p1'), isNotNull);
      expect(await repo.listSessions('p1'), hasLength(1));
      expect(await repo.getSession('s1'), isNotNull);

      expect(() => repo.upsertPatient(patient),
          throwsA(isA<PermissionDeniedException>()));
      expect(() => repo.saveSession(session),
          throwsA(isA<PermissionDeniedException>()));
      expect(() => repo.deletePatient('p1'),
          throwsA(isA<PermissionDeniedException>()));
    });

    test('an account awaiting approval sees no records at all', () async {
      await inner.saveSession(session);
      auth.roleValue = ClinicRole.pending;

      expect(await repo.listPatients(), isEmpty);
      expect(await repo.listPatients(query: 'Test'), isEmpty);
      expect(await repo.getPatient('p1'), isNull);
      expect(await repo.listSessions('p1'), isEmpty);
      expect(await repo.getSession('s1'), isNull);
      expect(await repo.pendingSync(), isEmpty);
      expect(() => repo.upsertPatient(patient),
          throwsA(isA<PermissionDeniedException>()));
    });

    test('the exception explains what was refused', () async {
      auth.roleValue = ClinicRole.viewer;
      try {
        await repo.saveSession(session);
        fail('should have thrown');
      } on PermissionDeniedException catch (e) {
        expect(e.action, 'record hearing tests');
        expect(e.toString(), contains('administrator'));
      }
    });
  });

  group('LocalAuthService roles', () {
    late LocalDatabase database;
    late LocalAuthService auth;

    setUp(() async {
      database = await LocalDatabase.openInMemory();
      auth = LocalAuthService(database);
    });

    tearDown(() async => database.close());

    test('the first account becomes the administrator', () async {
      final first = await auth.signUp(
        username: 'owner',
        displayName: 'Dr. Owner',
        password: 'correct horse battery',
      );
      expect(first.role, ClinicRole.admin,
          reason: 'someone has to be able to administer the device');
      expect(auth.role, ClinicRole.admin);
    });

    test('an account created by an admin without a role waits for approval',
        () async {
      await auth.signUp(
          username: 'owner', displayName: 'Owner', password: 'password123');
      final second = await auth.signUp(
          username: 'nurse', displayName: 'Nurse', password: 'password123');

      expect(second.role, ClinicRole.pending);
      // Creating an account for someone else must not sign the admin out.
      expect(auth.currentClinician?.username, 'owner');
    });

    test('someone registering themselves waits for approval', () async {
      await auth.signUp(
          username: 'owner', displayName: 'Owner', password: 'password123');
      await auth.signOut();

      final stranger = await auth.signUp(
          username: 'stranger', displayName: 'Stranger', password: 'password123');
      expect(stranger.role, ClinicRole.pending);
      expect(auth.currentClinician?.username, 'stranger',
          reason: 'signed in, to see the waiting-for-approval screen');
      expect(auth.role.canViewRecords, isFalse);
    });

    test('an admin may create an account with a chosen role', () async {
      await auth.signUp(
          username: 'owner', displayName: 'Owner', password: 'password123');
      final viewer = await auth.signUp(
        username: 'reception',
        displayName: 'Reception',
        password: 'password123',
        role: ClinicRole.viewer,
      );
      expect(viewer.role, ClinicRole.viewer);
    });

    test('a non-admin cannot create an account with a chosen role', () async {
      await auth.signUp(
          username: 'owner', displayName: 'Owner', password: 'password123');
      await auth.signUp(
          username: 'nurse',
          displayName: 'Nurse',
          password: 'password123',
          role: ClinicRole.clinician);
      await auth.signIn(username: 'nurse', password: 'password123');
      expect(auth.role, ClinicRole.clinician);

      expect(
        () => auth.signUp(
          username: 'sneaky',
          displayName: 'Sneaky',
          password: 'password123',
          role: ClinicRole.admin,
        ),
        throwsA(isA<AuthException>()),
      );
    });

    test('roles survive a sign-out and sign-in', () async {
      await auth.signUp(
          username: 'owner', displayName: 'Owner', password: 'password123');
      await auth.signUp(
        username: 'reception',
        displayName: 'Reception',
        password: 'password123',
        role: ClinicRole.viewer,
      );
      await auth.signOut();
      expect(auth.role, ClinicRole.pending, reason: 'signed out fails closed');

      final restored =
          await auth.signIn(username: 'reception', password: 'password123');
      expect(restored.role, ClinicRole.viewer);
    });

    test('an admin can promote and demote', () async {
      await auth.signUp(
          username: 'owner', displayName: 'Owner', password: 'password123');
      final nurse = await auth.signUp(
          username: 'nurse', displayName: 'Nurse', password: 'password123');

      await auth.setRole(nurse.id, ClinicRole.admin);
      final updated =
          (await auth.listClinicians()).firstWhere((c) => c.id == nurse.id);
      expect(updated.role, ClinicRole.admin);
    });

    test('the last administrator cannot demote themselves', () async {
      final owner = await auth.signUp(
          username: 'owner', displayName: 'Owner', password: 'password123');
      await auth.signUp(
          username: 'nurse', displayName: 'Nurse', password: 'password123');

      // Would otherwise leave the device with no admin and no way to appoint one.
      expect(() => auth.setRole(owner.id, ClinicRole.viewer),
          throwsA(isA<AuthException>()));
    });

    test('a non-admin cannot change roles', () async {
      await auth.signUp(
          username: 'owner', displayName: 'Owner', password: 'password123');
      final nurse = await auth.signUp(
          username: 'nurse', displayName: 'Nurse', password: 'password123');
      await auth.signIn(username: 'nurse', password: 'password123');

      expect(() => auth.setRole(nurse.id, ClinicRole.admin),
          throwsA(isA<AuthException>()));
    });

    test('passwords are never stored in plain text', () async {
      await auth.signUp(
          username: 'owner', displayName: 'Owner', password: 'hunter2hunter2');
      final rows = await database.db.query('clinicians');
      final stored = rows.single;

      expect(stored['password_hash'], isNot(contains('hunter2')));
      expect(stored.values.join(' '), isNot(contains('hunter2hunter2')));
      expect(stored['password_salt'], isNotNull);
    });

    test('wrong credentials are rejected without revealing which', () async {
      await auth.signUp(
          username: 'owner', displayName: 'Owner', password: 'password123');

      // Identical message for a wrong password and an unknown user, so the
      // login form cannot be used to enumerate who works at the clinic.
      await expectLater(
        auth.signIn(username: 'owner', password: 'wrongpassword'),
        throwsA(predicate((e) =>
            e is AuthException && e.message == 'Incorrect username or password.')),
      );
      await expectLater(
        auth.signIn(username: 'ghost', password: 'wrongpassword'),
        throwsA(predicate((e) =>
            e is AuthException && e.message == 'Incorrect username or password.')),
      );
    });
  });

  group('local profile', () {
    late LocalDatabase database;
    late LocalAuthService auth;

    setUp(() async {
      database = await LocalDatabase.openInMemory();
      auth = LocalAuthService(database);
      await auth.signUp(
          username: 'owner', displayName: 'Dr. Owner', password: 'password123');
    });

    tearDown(() async => database.close());

    test('profile changes apply at once and print on reports', () async {
      final account = LocalAccountService(
          auth, const ClinicDetails(name: 'Local Clinic'));
      expect(account.usesApprovals, isFalse);
      expect(await account.credentials(), isNull);

      final outcome = await account.updateProfile(
        displayName: ' Dr. Owner Two ',
        phone: '98765',
        qualification: 'MS (ENT)',
        registrationNo: '',
      );
      expect(outcome, ChangeOutcome.applied);
      expect(auth.currentClinician!.displayName, 'Dr. Owner Two');
      expect(await account.credentials(), 'MS (ENT)');

      final me = (await account.load())!;
      expect(me.profile.phone, '98765');
      expect(me.profile.registrationNo, isNull);
      expect(me.clinic!.name, 'Local Clinic');
      expect(me.clinicAdmins.map((a) => a.displayName), ['Dr. Owner Two']);
      expect(me.loginName, 'owner');
    });

    test('a name cannot be blank', () async {
      await expectLater(
        auth.updateProfile(displayName: '  '),
        throwsA(isA<AuthException>()),
      );
    });

    test('changing the password needs the current one', () async {
      await expectLater(
        auth.changePassword(
            currentPassword: 'wrong-one', newPassword: 'new-password'),
        throwsA(isA<AuthException>()),
      );
      await auth.changePassword(
          currentPassword: 'password123', newPassword: 'new-password');
      await auth.signOut();
      await expectLater(
        auth.signIn(username: 'owner', password: 'password123'),
        throwsA(isA<AuthException>()),
      );
      final back = await auth.signIn(username: 'owner', password: 'new-password');
      expect(back.username, 'owner');
    });

    test('cloud-only requests are refused on this device', () async {
      final account = LocalAccountService(
          auth, const ClinicDetails(name: 'Local Clinic'));
      await expectLater(
        account.requestClinic('AUR-1'),
        throwsA(isA<AuthException>()),
      );
      await expectLater(
        account.requestEmailChange('x@example.com'),
        throwsA(isA<AuthException>()),
      );
    });
  });

  group('schema migration', () {
    test('an upgraded database gets a role column', () async {
      // openInMemory creates at the current version; this asserts the shape
      // the migration is expected to produce.
      final database = await LocalDatabase.openInMemory();
      final columns = await database.db.rawQuery(
          "SELECT name FROM pragma_table_info('clinicians')");
      final names = columns.map((c) => c['name']).toSet();

      expect(names, contains('role'));
      expect(names, contains('clinic_id'));
      await database.close();
    });
  });
}
