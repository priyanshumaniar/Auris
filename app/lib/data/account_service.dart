import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import 'auth_service.dart';
import 'models/change_request.dart';
import 'models/clinic.dart';
import 'models/clinic_role.dart';

/// What happened to a change the user asked for.
enum ChangeOutcome {
  /// Saved and in effect now.
  applied,

  /// Waiting for someone to approve it. Nothing visible has changed yet.
  requested,
}

/// Everything the profile screen shows about the signed-in user.
class MyAccount {
  const MyAccount({
    required this.profile,
    this.clinic,
    this.clinicAdmins = const [],
    this.approvedBy,
    this.requestedClinicName,
    this.requestedClinicNo,
    this.requests = const [],
    this.hasPassword = true,
    this.loginName,
  });

  /// The approved profile: what others see and what reports print.
  final ClinicAccount profile;

  /// The clinic this account belongs to, if any.
  final Clinic? clinic;

  /// The people who run [clinic].
  final List<ClinicAccount> clinicAdmins;

  /// Who approved this account's access, when known.
  final String? approvedBy;

  /// For an account waiting to join: the clinic it asked for.
  final String? requestedClinicName;
  final int? requestedClinicNo;

  /// This account's requests, newest first.
  final List<ChangeRequest> requests;

  /// False for an account that only signs in with Google.
  final bool hasPassword;

  /// What the user signs in with: an email in the cloud, a username locally.
  final String? loginName;

  String? get requestedClinicLabel => requestedClinicName == null
      ? null
      : requestedClinicNo == null
      ? requestedClinicName
      : '$requestedClinicName (${formatClinicNo(requestedClinicNo!)})';

  /// The open request of [kind], if there is one.
  ChangeRequest? open(ChangeKind kind) {
    for (final r in requests) {
      if (r.kind == kind && r.isPending) return r;
    }
    return null;
  }

  /// An approved email change still waiting for the code from the new address.
  ChangeRequest? get emailToConfirm {
    // Only the newest email request counts: an older approval was replaced.
    for (final r in requests) {
      if (r.kind == ChangeKind.email) {
        return r.status == ChangeStatus.approved ? r : null;
      }
    }
    return null;
  }
}

/// The signed-in user's own account: profile, clinic, password and requests.
///
/// Changes do not re-read the profile themselves: the caller reloads once
/// afterwards ([load], or the dashboard's refresh), rather than every step
/// paying for its own round trip.
///
/// In cloud mode most changes become requests that someone else approves
/// (see `supabase/schema.sql`, "Profiles and change requests"). On a device
/// without a cloud clinic there is nobody to approve them, so they apply at
/// once.
abstract class AccountService {
  /// True when changes go through approval (cloud mode).
  bool get usesApprovals;

  Future<MyAccount?> load();

  /// The examiner credentials printed on reports: qualification and
  /// registration number.
  Future<String?> credentials();

  Future<ChangeOutcome> updateProfile({
    required String displayName,
    String? phone,
    String? qualification,
    String? registrationNo,
  });

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  });

  // Cloud only. The local implementation throws [AuthException].

  /// Asks to change the login email. Returns [ChangeOutcome.applied] when it
  /// was approved at once and the user should now confirm the new address.
  Future<ChangeOutcome> requestEmailChange(String newEmail);

  /// Has Supabase send a code to the approved new address.
  Future<void> sendEmailChangeCode(String newEmail);

  /// Completes an approved email change with the code sent to [newEmail].
  Future<void> confirmEmailChange({
    required String newEmail,
    required String code,
  });

  /// Asks to join (or move to) the clinic with [joinCode]. Returns its name.
  Future<String> requestClinic(String joinCode);

  /// Leaves the clinic. Access to its records ends at once.
  Future<void> leaveClinic();

  Future<void> requestDeletion(String? reason);

  Future<void> cancelRequest(String requestId);

  Future<void> setEmailAlerts(bool on);
}

// ---------------------------------------------------------------------------
// Cloud
// ---------------------------------------------------------------------------

class CloudAccountService implements AccountService {
  CloudAccountService(this._client, this._auth);

  final sb.SupabaseClient _client;
  final SupabaseAuthService _auth;

  @override
  bool get usesApprovals => true;

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on AuthException {
      rethrow;
    } on sb.PostgrestException catch (e) {
      throw AuthException(e.message);
    } on sb.AuthException catch (e) {
      throw AuthException(e.message);
    } catch (e) {
      throw AuthException('Could not reach the server. $e');
    }
  }

  @override
  Future<MyAccount?> load() => _guard(() async {
    await _auth.refreshProfile();
    final user = _client.auth.currentUser;
    final me = _auth.profile;
    if (user == null || me == null) return null;

    final clinic = _auth.clinicRecord;

    // The profile itself is cached for offline use; the rest is not. Offline,
    // the screen still shows the profile, with the lists left empty.
    var requests = const <ChangeRequest>[];
    var admins = const <ClinicAccount>[];
    String? requestedName;
    int? requestedNo;
    String? approver;
    try {
      final requestRows =
          await _client
                  .from('change_requests')
                  .select()
                  .eq('user_id', user.id)
                  .order('created_at', ascending: false)
                  .limit(50)
              as List<dynamic>;
      requests = [
        for (final row in requestRows.cast<Map<String, dynamic>>())
          ChangeRequest.fromRow(row),
      ];

      if (clinic != null) {
        final rows =
            await _client
                    .from('profiles')
                    .select(SupabaseAuthService.profileColumns)
                    .eq('clinic_id', clinic.id)
                    .inFilter('role', ['admin', 'super_admin'])
                    .order('display_name')
                as List<dynamic>;
        admins = [
          for (final row in rows.cast<Map<String, dynamic>>())
            ClinicAccount.fromRow(row),
        ];
      }

      if (me.isPending && me.requestedClinicId != null) {
        final rows = await _client.rpc('my_requested_clinic') as List<dynamic>;
        if (rows.isNotEmpty) {
          final row = rows.first as Map<String, dynamic>;
          requestedName = row['name'] as String?;
          requestedNo = (row['clinic_no'] as num?)?.toInt();
        }
      }

      if (me.approvedAt != null) {
        approver = await _client.rpc('my_approver') as String?;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Auris: profile details unavailable ($e).');
    }

    final providers = user.appMetadata['providers'];
    return MyAccount(
      profile: me,
      clinic: clinic,
      clinicAdmins: admins,
      approvedBy: approver,
      requestedClinicName: requestedName,
      requestedClinicNo: requestedNo,
      requests: requests,
      hasPassword: providers is! List || providers.contains('email'),
      loginName: user.email,
    );
  });

  @override
  Future<String?> credentials() async => _auth.profile?.credentials;

  @override
  Future<ChangeOutcome> updateProfile({
    required String displayName,
    String? phone,
    String? qualification,
    String? registrationNo,
  }) => _guard(() async {
    final outcome = await _client.rpc(
      'submit_profile_change',
      params: {
        'p_display_name': displayName,
        'p_phone': phone,
        'p_qualification': qualification,
        'p_registration_no': registrationNo,
      },
    );
    return outcome == 'applied'
        ? ChangeOutcome.applied
        : ChangeOutcome.requested;
  });

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) => _guard(() async {
    if (newPassword.length < 8) {
      throw const AuthException('Password must be at least 8 characters.');
    }
    final user = _client.auth.currentUser;
    final email = user?.email;
    if (user == null || email == null) {
      throw const AuthException('Sign in first.');
    }
    final providers = user.appMetadata['providers'];
    final hasPassword = providers is! List || providers.contains('email');
    if (hasPassword) {
      // Signing in again proves the current password before it is replaced.
      try {
        await _client.auth.signInWithPassword(
          email: email,
          password: currentPassword,
        );
      } on sb.AuthApiException catch (e) {
        // Only a refused password means a wrong password; a network or rate
        // limit error says so itself.
        if (e.code == 'invalid_credentials' || e.statusCode == '400') {
          throw const AuthException('Your current password is not right.');
        }
        rethrow;
      }
    }
    await _client.auth.updateUser(sb.UserAttributes(password: newPassword));
  });

  @override
  Future<ChangeOutcome> requestEmailChange(String newEmail) => _guard(() async {
    final outcome = await _client.rpc(
      'submit_email_change',
      params: {'p_new_email': newEmail},
    );
    return outcome == 'approved'
        ? ChangeOutcome.applied
        : ChangeOutcome.requested;
  });

  @override
  Future<void> sendEmailChangeCode(String newEmail) => _guard(() async {
    // With "Secure email change" off, Supabase sends one code, to the new
    // address only. See docs/SUPABASE_SETUP.md.
    await _client.auth.updateUser(sb.UserAttributes(email: newEmail.trim()));
  });

  @override
  Future<void> confirmEmailChange({
    required String newEmail,
    required String code,
  }) => _guard(() async {
    await _client.auth.verifyOTP(
      type: sb.OtpType.emailChange,
      email: newEmail.trim(),
      token: code.trim(),
    );
    // The database copies the new address into the profile and marks the
    // request done.
  });

  @override
  Future<String> requestClinic(String joinCode) => _guard(() async {
    final name = await _client.rpc(
      'request_clinic',
      params: {'p_join_code': joinCode.trim()},
    );
    return name as String;
  });

  @override
  Future<void> leaveClinic() => _guard(() async {
    await _client.rpc('leave_clinic');
  });

  @override
  Future<void> requestDeletion(String? reason) => _guard(() async {
    await _client.rpc(
      'request_account_deletion',
      params: {'p_reason': reason?.trim()},
    );
  });

  @override
  Future<void> cancelRequest(String requestId) => _guard(() async {
    await _client.rpc('cancel_request', params: {'p_request': requestId});
  });

  @override
  Future<void> setEmailAlerts(bool on) => _guard(() async {
    await _client.rpc('set_email_alerts', params: {'p_on': on});
  });
}

// ---------------------------------------------------------------------------
// Local only
// ---------------------------------------------------------------------------

class LocalAccountService implements AccountService {
  LocalAccountService(this._auth, this._clinic);

  final LocalAuthService _auth;

  /// The clinic from `.env`.
  final ClinicDetails _clinic;

  @override
  bool get usesApprovals => false;

  static const _cloudOnly = AuthException(
    'This needs cloud sync. On this device, an administrator manages '
    'accounts under Settings.',
  );

  @override
  Future<MyAccount?> load() async {
    final me = await _auth.loadProfile();
    if (me == null) return null;
    final accounts = await _auth.listClinicians();
    return MyAccount(
      profile: me,
      clinic: Clinic(
        id: 'local',
        name: _clinic.name,
        address: _clinic.address,
        phone: _clinic.phone,
      ),
      clinicAdmins: [
        for (final c in accounts)
          if (c.role == ClinicRole.admin)
            ClinicAccount(id: c.id, displayName: c.displayName, role: c.role),
      ],
      loginName: _auth.currentClinician?.username,
    );
  }

  @override
  Future<String?> credentials() async => (await _auth.loadProfile())?.credentials;

  @override
  Future<ChangeOutcome> updateProfile({
    required String displayName,
    String? phone,
    String? qualification,
    String? registrationNo,
  }) async {
    await _auth.updateProfile(
      displayName: displayName,
      phone: phone,
      qualification: qualification,
      registrationNo: registrationNo,
    );
    return ChangeOutcome.applied;
  }

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) => _auth.changePassword(
    currentPassword: currentPassword,
    newPassword: newPassword,
  );

  @override
  Future<ChangeOutcome> requestEmailChange(String newEmail) async =>
      throw _cloudOnly;

  @override
  Future<void> sendEmailChangeCode(String newEmail) async => throw _cloudOnly;

  @override
  Future<void> confirmEmailChange({
    required String newEmail,
    required String code,
  }) async => throw _cloudOnly;

  @override
  Future<String> requestClinic(String joinCode) async => throw _cloudOnly;

  @override
  Future<void> leaveClinic() async => throw _cloudOnly;

  @override
  Future<void> requestDeletion(String? reason) async => throw _cloudOnly;

  @override
  Future<void> cancelRequest(String requestId) async => throw _cloudOnly;

  @override
  Future<void> setEmailAlerts(bool on) async => throw _cloudOnly;
}
