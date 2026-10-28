import 'clinic_role.dart';

/// Clinic details printed in the report header.
///
/// In cloud mode they come from the signed-in user's clinic record, so every
/// clinic's reports carry its own name. In local-only mode they come from
/// `.env`.
class ClinicDetails {
  const ClinicDetails({required this.name, this.address, this.phone});

  final String name;
  final String? address;
  final String? phone;

  Map<String, Object?> toJson() =>
      {'name': name, 'address': address, 'phone': phone};

  static ClinicDetails? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    if (name is! String || name.trim().isEmpty) return null;
    return ClinicDetails(
      name: name.trim(),
      address: _text(raw['address']),
      phone: _text(raw['phone']),
    );
  }
}

/// A clinic's permanent number as people read it: CLN-0007.
String formatClinicNo(int no) => 'CLN-${no.toString().padLeft(4, '0')}';

/// A clinic in the cloud project.
class Clinic {
  const Clinic({
    required this.id,
    required this.name,
    this.address,
    this.phone,
    this.joinCode,
    this.clinicNo,
  });

  final String id;
  final String name;
  final String? address;
  final String? phone;

  /// What staff enter at sign-up to ask to join. Only visible to members.
  final String? joinCode;

  /// Permanent number, shown as [clinicLabel]. Never changes.
  final int? clinicNo;

  /// "CLN-0007", or null for a clinic without a number yet.
  String? get clinicLabel =>
      clinicNo == null ? null : formatClinicNo(clinicNo!);

  ClinicDetails get details =>
      ClinicDetails(name: name, address: address, phone: phone);

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'address': address,
        'phone': phone,
        'join_code': joinCode,
        'clinic_no': clinicNo,
      };

  factory Clinic.fromRow(Map<String, dynamic> row) => Clinic(
        id: row['id'] as String,
        name: _text(row['name']) ?? 'Unnamed clinic',
        address: _text(row['address']),
        phone: _text(row['phone']),
        joinCode: _text(row['join_code']),
        clinicNo: (row['clinic_no'] as num?)?.toInt(),
      );

  static Clinic? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] is! String) return null;
    return Clinic.fromRow(raw.map((k, v) => MapEntry('$k', v)));
  }
}

/// One account, as its owner or an administrator sees it.
class ClinicAccount {
  const ClinicAccount({
    required this.id,
    required this.displayName,
    required this.role,
    this.email,
    this.clinicId,
    this.requestedClinicId,
    this.requestedClinic,
    this.createdAt,
    this.phone,
    this.qualification,
    this.registrationNo,
    this.approvedAt,
    this.emailAlerts = true,
  });

  final String id;
  final String displayName;
  final String? email;
  final ClinicRole role;
  final String? clinicId;

  /// The clinic a pending account asked to join, when its code matched one.
  final String? requestedClinicId;

  /// The join code the person typed, kept even when it matched nothing.
  final String? requestedClinic;

  final DateTime? createdAt;
  final String? phone;
  final String? qualification;
  final String? registrationNo;
  final DateTime? approvedAt;
  final bool emailAlerts;

  bool get isPending => role == ClinicRole.pending;

  /// What goes on a report as the examiner's credentials.
  String? get credentials {
    final parts = [
      if (qualification != null) qualification!,
      if (registrationNo != null) 'Reg. No. $registrationNo',
    ];
    return parts.isEmpty ? null : parts.join(', ');
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'display_name': displayName,
        'email': email,
        'role': role.id,
        'clinic_id': clinicId,
        'requested_clinic_id': requestedClinicId,
        'requested_clinic': requestedClinic,
        'created_at': createdAt?.toIso8601String(),
        'phone': phone,
        'qualification': qualification,
        'registration_no': registrationNo,
        'approved_at': approvedAt?.toIso8601String(),
        'email_alerts': emailAlerts,
      };

  factory ClinicAccount.fromRow(Map<String, dynamic> row) => ClinicAccount(
        id: row['id'] as String,
        displayName: _text(row['display_name']) ??
            _text(row['email']) ??
            'Unnamed account',
        email: _text(row['email']),
        role: ClinicRole.fromId(row['role'] as String?),
        clinicId: _text(row['clinic_id']),
        requestedClinicId: _text(row['requested_clinic_id']),
        requestedClinic: _text(row['requested_clinic']),
        createdAt: DateTime.tryParse(row['created_at'] as String? ?? ''),
        phone: _text(row['phone']),
        qualification: _text(row['qualification']),
        registrationNo: _text(row['registration_no']),
        approvedAt: DateTime.tryParse(row['approved_at'] as String? ?? ''),
        emailAlerts: row['email_alerts'] != false,
      );

  static ClinicAccount? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] is! String) return null;
    return ClinicAccount.fromRow(raw.map((k, v) => MapEntry('$k', v)));
  }
}

String? _text(Object? v) =>
    v is String && v.trim().isNotEmpty ? v.trim() : null;
