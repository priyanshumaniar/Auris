import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/audiometry/calibration_store.dart';
import 'data/account_service.dart';
import 'data/auth_service.dart';
import 'data/calibration_history.dart';
import 'data/cloud_admin_service.dart';
import 'data/env.dart';
import 'data/local_database.dart';
import 'data/local_repository.dart';
import 'data/permissioned_repository.dart';
import 'data/repository.dart';
import 'data/syncing_repository.dart';
import 'report/pdf_report.dart';

/// Everything the UI needs, wired up once at startup.
///
/// Deliberately a plain object passed down through an InheritedWidget rather
/// than a state-management framework: the dependency graph here is small and
/// static, and a hand-wired graph is easier for a reviewer to follow than a
/// container full of registrations.
class AppServices {
  AppServices({
    required this.repository,
    required this.auth,
    required this.account,
    required this.calibration,
    required ClinicDetails clinic,
    required this.cloudSyncEnabled,
    this.syncing,
    this.calibrationHistory,
    this.admin,
  }) : _envClinic = clinic;

  final AudiometryRepository repository;
  final AuthService auth;

  /// The signed-in user's own profile, clinic and requests.
  final AccountService account;

  final CalibrationStore calibration;

  /// The clinic named in `.env`.
  final ClinicDetails _envClinic;

  /// The clinic printed on reports: the signed-in user's own clinic in cloud
  /// mode, otherwise the one named in `.env`.
  ClinicDetails get clinic {
    final current = auth;
    if (current is SupabaseAuthService) return current.clinic ?? _envClinic;
    return _envClinic;
  }

  /// Clinics and access. Non-null only when cloud sync is on.
  final CloudAdminService? admin;

  /// True when `.env` supplied Supabase credentials.
  final bool cloudSyncEnabled;

  /// Non-null only when cloud sync is on; used to retry queued pushes.
  final SyncingRepository? syncing;

  /// This device's calibration history. Null only in tests that do not need
  /// it; the app always provides one.
  final CalibrationHistory? calibrationHistory;

  /// Opens the database, loads settings and selects local or cloud-backed
  /// storage based on `.env`.
  ///
  /// Cloud configuration is best-effort: if Supabase cannot be reached or the
  /// credentials are wrong, the app falls back to local-only rather than
  /// refusing to start. A clinic must still be able to run a test.
  static Future<AppServices> bootstrap() async {
    await Env.load();

    final database = await LocalDatabase.open();
    final local = LocalRepository(database);
    final calibration = await CalibrationStore.load();
    final calibrationHistory = CalibrationHistory(database);

    final clinic = ClinicDetails(
      name: Env.clinicName,
      address: Env.clinicAddress,
      phone: Env.clinicPhone,
    );

    AppServices localOnly() {
      // Local accounts see the device's own records only, never records
      // cached for a cloud clinic.
      local.scope = () => RecordScope.device;
      final auth = LocalAuthService(database);
      return AppServices(
        // Even offline, writes pass through the role check - a viewer account
        // on a shared clinic tablet must not be able to edit records.
        repository: PermissionedRepository(inner: local, auth: auth),
        auth: auth,
        account: LocalAccountService(auth, clinic),
        calibration: calibration,
        clinic: clinic,
        cloudSyncEnabled: false,
        calibrationHistory: calibrationHistory,
      );
    }

    if (!Env.cloudSyncEnabled) return localOnly();

    try {
      await Supabase.initialize(
        url: Env.supabaseUrl!,
        publishableKey: Env.supabaseAnonKey!,
      );
      final client = Supabase.instance.client;
      final auth = SupabaseAuthService(client);

      // The device cache is shared by every account that signs in here. Each
      // account sees only its own clinic's records, and an account awaiting
      // approval sees none.
      local.scope = () {
        final clinician = auth.currentClinician;
        final clinic = clinician?.clinicId;
        if (clinician == null ||
            clinic == null ||
            !clinician.role.canViewRecords) {
          return RecordScope.none;
        }
        return RecordScope.clinic(clinic);
      };

      // Restore the role for a session resumed from disk, otherwise a returning
      // user would be treated as a viewer until they signed in again.
      await auth.refreshProfile();

      final syncing = SyncingRepository(
        local: local,
        client: client,
        auth: auth,
      )..startAutoSync();

      return AppServices(
        repository: PermissionedRepository(inner: syncing, auth: auth),
        auth: auth,
        account: CloudAccountService(client, auth),
        calibration: calibration,
        clinic: clinic,
        cloudSyncEnabled: true,
        syncing: syncing,
        calibrationHistory: calibrationHistory,
        admin: CloudAdminService(client),
      );
    } catch (e) {
      debugPrint('Auris: Supabase init failed, continuing local-only - $e');
      return localOnly();
    }
  }
}
