/// What a signed-in user is allowed to do.
///
/// Roles are enforced in three places, and all three are needed:
///
///  * **UI** - actions the role cannot perform are hidden or disabled, so the
///    interface never offers a button that will fail.
///  * **Repository** - [PermissionDeniedException] is thrown before a write is
///    attempted, so a screen that forgets to check still cannot corrupt data.
///  * **Database** - Postgres row-level security policies (see
///    `supabase/schema.sql`) reject the write server-side. This is the only
///    layer an attacker cannot bypass: a modified client talking straight to
///    the REST API still hits the policy.
///
/// The UI check is convenience, the repository check is a safety net, and the
/// RLS policy is the actual security boundary.
enum ClinicRole {
  /// Runs Auris itself: creates clinics and gives accounts access to them.
  /// Cloud mode only, and granted only with SQL in Supabase, never from the
  /// app. Sees no clinic's patients except those of an optional home clinic,
  /// where they act as its administrator.
  superAdmin('super_admin', 'Super admin'),

  /// Full access to their own clinic, including deleting patients and
  /// approving the people who ask to join it.
  admin('admin', 'Administrator'),

  /// Registers patients and runs tests. Cannot delete patient records.
  clinician('clinician', 'Clinician'),

  /// Read-only. Can review history and print reports, but cannot test or edit.
  /// Intended for reception and trainees.
  viewer('viewer', 'Viewer'),

  /// A new account that an administrator has not approved yet. Sees no patient
  /// records at all, on the device or in the cloud. Every self-registered
  /// account after the first starts here, so installing the app and signing
  /// up is never enough to read a clinic's records.
  pending('pending', 'Awaiting approval');

  const ClinicRole(this.id, this.label);

  /// Stable identifier used in the database. Never rename these.
  final String id;

  /// Human-readable name shown in the UI.
  final String label;

  static ClinicRole fromId(String? id) => switch (id) {
        'super_admin' => ClinicRole.superAdmin,
        'admin' => ClinicRole.admin,
        'clinician' => ClinicRole.clinician,
        'viewer' => ClinicRole.viewer,
        'pending' => ClinicRole.pending,
        // An unknown or missing role must fail closed, not open: no access.
        _ => ClinicRole.pending,
      };

  /// Administrator rights in the user's own clinic. A super admin has them in
  /// their home clinic, if they have one.
  bool get _isClinicAdmin =>
      this == ClinicRole.admin || this == ClinicRole.superAdmin;

  bool get _canWrite => _isClinicAdmin || this == ClinicRole.clinician;

  bool get canRegisterPatients => _canWrite;

  bool get canEditPatients => _canWrite;

  bool get canRunTests => _canWrite;

  /// Deleting a patient cascades to every test they have ever had, so it is
  /// restricted to administrators.
  bool get canDeletePatients => _isClinicAdmin;

  bool get canDeleteSessions => _isClinicAdmin;

  /// Calibration affects the validity of every subsequent test, so a viewer
  /// must not be able to change it.
  bool get canCalibrate => _canWrite;

  /// Approve people into the clinic and change their roles.
  bool get canManageUsers => _isClinicAdmin;

  /// Create clinics and place any account in any clinic.
  bool get canManageClinics => this == ClinicRole.superAdmin;

  /// Every approved role may read records and produce a report. An account
  /// awaiting approval may not.
  bool get canViewRecords => this != ClinicRole.pending;
  bool get canExportReports => this != ClinicRole.pending;

  /// Roles an administrator can give a new account. Creating an account only
  /// to leave it without access would be pointless.
  static const List<ClinicRole> assignable = [admin, clinician, viewer];

  String get description => switch (this) {
        ClinicRole.superAdmin =>
          'Runs Auris: creates clinics and gives accounts access to them. '
              'Sees patient records only in a home clinic, if one is set.',
        ClinicRole.admin =>
          'Full access: run tests, manage patient records, delete records, '
              'calibrate the device and manage other users.',
        ClinicRole.clinician =>
          'Register patients, run tests, generate reports and calibrate. '
              'Cannot delete patient records.',
        ClinicRole.viewer =>
          'Read-only: review history and print reports. Cannot run tests or '
              'change any record.',
        ClinicRole.pending =>
          'No access yet. Sees no patient records until an administrator '
              'gives the account a role.',
      };
}

/// Thrown when a signed-in user attempts something their role forbids.
class PermissionDeniedException implements Exception {
  const PermissionDeniedException(this.action);

  /// Plain-language description of what was refused, e.g. "delete patients".
  final String action;

  @override
  String toString() =>
      'Your role does not allow you to $action. Ask an administrator.';
}
