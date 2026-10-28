import 'clinic.dart';

/// What a change request asks for.
enum ChangeKind {
  profile('profile', 'Profile change'),
  email('email', 'Email change'),
  join('join', 'Request to join'),
  move('move', 'Request to move clinic'),
  clinic('clinic', 'Clinic details change'),
  delete('delete', 'Account deletion'),
  leave('leave', 'Left the clinic');

  const ChangeKind(this.id, this.label);
  final String id;
  final String label;

  static ChangeKind? fromId(Object? id) {
    for (final k in values) {
      if (k.id == id) return k;
    }
    return null;
  }
}

/// Where a request stands.
enum ChangeStatus {
  pending('pending', 'Waiting for approval'),
  approved('approved', 'Approved'),
  rejected('rejected', 'Not approved'),
  cancelled('cancelled', 'Withdrawn'),
  completed('completed', 'Done'),
  flagged('flagged', 'Changed without approval');

  const ChangeStatus(this.id, this.label);
  final String id;
  final String label;

  static ChangeStatus fromId(Object? id) => values.firstWhere(
        (s) => s.id == id,
        orElse: () => ChangeStatus.pending,
      );
}

/// One request to change a profile, an email, a clinic, or clinic details.
/// See `supabase/schema.sql`, "Profiles and change requests".
class ChangeRequest {
  const ChangeRequest({
    required this.id,
    required this.kind,
    required this.status,
    required this.reviewerLevel,
    this.userId,
    this.userEmail,
    this.userName,
    this.clinicId,
    this.fromClinicId,
    this.payload = const {},
    this.previous = const {},
    this.reason,
    this.decisionNote,
    this.reviewedAt,
    this.createdAt,
  });

  final String id;
  final ChangeKind kind;
  final ChangeStatus status;

  /// 'clinic_admin' or 'super_admin': who may decide it.
  final String reviewerLevel;

  /// Null once the account has been deleted.
  final String? userId;
  final String? userEmail;
  final String? userName;
  final String? clinicId;
  final String? fromClinicId;
  final Map<String, Object?> payload;
  final Map<String, Object?> previous;
  final String? reason;
  final String? decisionNote;
  final DateTime? reviewedAt;
  final DateTime? createdAt;

  bool get isPending => status == ChangeStatus.pending;

  String get who => userName ?? userEmail ?? 'A deleted account';

  /// For a join or move: the clinic asked for, as the requester saw it.
  String? get requestedClinicLabel {
    final name = payload['clinic_name'];
    if (name is! String) return null;
    final no = payload['clinic_no'];
    return no is num ? '$name (${formatClinicNo(no.toInt())})' : name;
  }

  static const _fields = {
    'display_name': 'Name',
    'phone': 'Phone',
    'qualification': 'Qualification',
    'registration_no': 'Registration no.',
    'email': 'Email',
    'name': 'Clinic name',
    'address': 'Address',
  };

  /// "Field: before → after" lines for the fields this request changes.
  List<(String, String, String)> get differences => [
        for (final entry in _fields.entries)
          if (payload.containsKey(entry.key) &&
              '${payload[entry.key] ?? ''}' != '${previous[entry.key] ?? ''}')
            (
              entry.value,
              _show(previous[entry.key]),
              _show(payload[entry.key]),
            ),
      ];

  static String _show(Object? v) =>
      v == null || (v is String && v.trim().isEmpty) ? '(none)' : '$v';

  factory ChangeRequest.fromRow(Map<String, dynamic> row) => ChangeRequest(
        id: row['id'] as String,
        kind: ChangeKind.fromId(row['kind']) ?? ChangeKind.profile,
        status: ChangeStatus.fromId(row['status']),
        reviewerLevel: row['reviewer_level'] as String? ?? 'super_admin',
        userId: row['user_id'] as String?,
        userEmail: row['user_email'] as String?,
        userName: row['user_name'] as String?,
        clinicId: row['clinic_id'] as String?,
        fromClinicId: row['from_clinic_id'] as String?,
        payload: _map(row['payload']),
        previous: _map(row['previous']),
        reason: row['reason'] as String?,
        decisionNote: row['decision_note'] as String?,
        reviewedAt: DateTime.tryParse(row['reviewed_at'] as String? ?? ''),
        createdAt: DateTime.tryParse(row['created_at'] as String? ?? ''),
      );

  static Map<String, Object?> _map(Object? raw) =>
      raw is Map ? raw.map((k, v) => MapEntry('$k', v)) : const {};
}
