import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_service.dart';
import 'models/change_request.dart';
import 'models/clinic.dart';
import 'models/clinic_role.dart';

/// A refused or failed administration action, in words for the user.
class AdminException implements Exception {
  const AdminException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Clinics and access, in cloud mode.
///
/// Every change goes through a database function (see `supabase/schema.sql`)
/// that checks who is calling. This class only asks; the database decides.
/// What each list contains is also decided there, by row-level security: a
/// super admin sees every clinic and account, a clinic admin sees their own
/// clinic's members and the people asking to join it.
class CloudAdminService {
  CloudAdminService(this._client);

  final SupabaseClient _client;

  static const _accountColumns = SupabaseAuthService.profileColumns;

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on AdminException {
      rethrow;
    } on PostgrestException catch (e) {
      throw AdminException(e.message);
    } on FunctionException catch (e) {
      final details = e.details;
      final message = details is Map ? details['error'] : null;
      throw AdminException(
          message is String ? message : 'The server refused (${e.status}).');
    } catch (e) {
      throw AdminException('Could not reach the server. $e');
    }
  }

  /// Clinics this user may see, by name.
  Future<List<Clinic>> listClinics() => _guard(() async {
    final rows =
        await _client
                .from('clinics')
                .select(SupabaseAuthService.clinicColumns)
                .order('name')
            as List<dynamic>;
    return [
      for (final row in rows.cast<Map<String, dynamic>>()) Clinic.fromRow(row),
    ];
  });

  /// Accounts this user may see: pending ones first, then by name.
  Future<List<ClinicAccount>> listAccounts() => _guard(() async {
    final rows =
        await _client
                .from('profiles')
                .select(_accountColumns)
                .order('created_at')
            as List<dynamic>;
    final accounts = [
      for (final row in rows.cast<Map<String, dynamic>>())
        ClinicAccount.fromRow(row),
    ];
    accounts.sort((a, b) {
      if (a.isPending != b.isPending) return a.isPending ? -1 : 1;
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
    return accounts;
  });

  /// Super admin only. Returns the new clinic's id.
  Future<String> createClinic({
    required String name,
    String? address,
    String? phone,
  }) => _guard(() async {
    final id = await _client.rpc(
      'create_clinic',
      params: {'p_name': name, 'p_address': address, 'p_phone': phone},
    );
    return id as String;
  });

  /// Super admin, or the clinic's own admin. Returns true when the change
  /// applied at once (a super admin's), false when it went to a super admin
  /// for approval (a clinic admin's, since the details print on reports).
  Future<bool> updateClinic(
    String clinicId, {
    required String name,
    String? address,
    String? phone,
  }) => _guard(() async {
    final outcome = await _client.rpc(
      'update_clinic',
      params: {
        'p_clinic': clinicId,
        'p_name': name,
        'p_address': address,
        'p_phone': phone,
      },
    );
    return outcome == 'applied';
  });

  /// Replaces the join code; the old one stops working. Returns the new code.
  Future<String> regenerateJoinCode(String clinicId) => _guard(() async {
    final code = await _client.rpc(
      'regenerate_join_code',
      params: {'p_clinic': clinicId},
    );
    return code as String;
  });

  /// Gives [userId] [role] in [clinicId].
  Future<void> setMemberAccess({
    required String userId,
    required String clinicId,
    required ClinicRole role,
  }) async {
    if (!ClinicRole.assignable.contains(role)) {
      throw ArgumentError.value(role, 'role', 'not assignable from the app');
    }
    return _guard(() async {
      await _client.rpc(
        'set_member_access',
        params: {'p_user': userId, 'p_clinic': clinicId, 'p_role': role.id},
      );
    });
  }

  /// Takes [userId]'s access away, or turns down their request to join.
  Future<void> revokeMember(String userId) => _guard(() async {
    await _client.rpc('revoke_member', params: {'p_user': userId});
  });

  // -------------------------------------------------------------------------
  // Approvals
  // -------------------------------------------------------------------------

  String? get _myId => _client.auth.currentUser?.id;

  /// Requests this user may decide, oldest first.
  ///
  /// Row-level security returns the caller's own requests too; those are left
  /// out, since nobody decides their own.
  Future<List<ChangeRequest>> listPendingReviews() => _guard(() async {
    final rows =
        await _client
                .from('change_requests')
                .select()
                .eq('status', 'pending')
                .order('created_at')
            as List<dynamic>;
    final me = _myId;
    return [
      for (final row in rows.cast<Map<String, dynamic>>())
        if (row['user_id'] != me) ChangeRequest.fromRow(row),
    ];
  });

  /// Decided requests this user can see, newest first: the record of who
  /// approved what.
  Future<List<ChangeRequest>> listDecided({int limit = 100}) =>
      _guard(() async {
        final rows =
            await _client
                    .from('change_requests')
                    .select()
                    .neq('status', 'pending')
                    .order('created_at', ascending: false)
                    .limit(limit)
                as List<dynamic>;
        return [
          for (final row in rows.cast<Map<String, dynamic>>())
            ChangeRequest.fromRow(row),
        ];
      });

  /// How many requests wait for this user's decision, optionally only
  /// those of [clinicId].
  ///
  /// Asks the server for the number only, without downloading the requests.
  Future<int> pendingReviewCount({String? clinicId}) async {
    final me = _myId;
    if (me == null) return 0;
    try {
      var query = _client
          .from('change_requests')
          .count()
          .eq('status', 'pending')
          .neq('user_id', me);
      if (clinicId != null) query = query.eq('clinic_id', clinicId);
      return await query;
    } catch (_) {
      return 0;
    }
  }

  /// Approves or rejects [request]. [role] is the role to give when approving
  /// a request to join or move. A rejection needs a [note] saying why.
  Future<void> review(
    ChangeRequest request, {
    required bool approve,
    String? note,
    ClinicRole? role,
  }) async {
    if (!approve && (note == null || note.trim().isEmpty)) {
      throw const AdminException('Say why, so they know what to change.');
    }
    if (role != null && !ClinicRole.assignable.contains(role)) {
      throw ArgumentError.value(role, 'role', 'not assignable from the app');
    }
    if (approve && request.kind == ChangeKind.delete) {
      return approveDeletion(request);
    }
    return _guard(() async {
      await _client.rpc(
        'review_request',
        params: {
          'p_request': request.id,
          'p_approve': approve,
          'p_note': note?.trim(),
          'p_role': role?.id,
        },
      );
    });
  }

  /// Super admin only: deletes the account that asked to be deleted. Its
  /// patients and tests stay with the clinic. Done by the `delete-account`
  /// Edge Function, since only the service key can remove a login.
  Future<void> approveDeletion(ChangeRequest request) => _guard(() async {
    final response = await _client.functions.invoke(
      'delete-account',
      body: {'requestId': request.id},
    );
    final data = response.data;
    if (data is! Map || data['deleted'] != true) {
      throw const AdminException('The account could not be deleted.');
    }
  });
}
