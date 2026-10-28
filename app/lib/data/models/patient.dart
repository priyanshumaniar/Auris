/// A patient record.
///
/// This is health data. It is stored in the clinic's own database (locally, and
/// in the clinic's own Supabase project when cloud sync is enabled) and is
/// never sent anywhere else - see the privacy section of the README.
class Patient {
  const Patient({
    required this.id,
    required this.fullName,
    required this.ageYears,
    required this.sex,
    this.clinicRef,
    this.dateOfBirth,
    this.phone,
    this.notes,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String fullName;
  final int ageYears;

  /// Recorded because hearing thresholds are interpreted against age-matched
  /// norms - presbycusis is expected at 70 and not at 20.
  final String sex;

  /// The clinic's own identifier for this patient (MRN, file number).
  final String? clinicRef;

  final DateTime? dateOfBirth;
  final String? phone;
  final String? notes;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// Age at [when], derived from [dateOfBirth] when it is known, otherwise the
  /// age recorded at registration.
  int ageAt(DateTime when) {
    final dob = dateOfBirth;
    if (dob == null) return ageYears;
    var age = when.year - dob.year;
    if (when.month < dob.month ||
        (when.month == dob.month && when.day < dob.day)) {
      age--;
    }
    return age;
  }

  Patient copyWith({
    String? fullName,
    int? ageYears,
    String? sex,
    String? clinicRef,
    DateTime? dateOfBirth,
    String? phone,
    String? notes,
    DateTime? updatedAt,
  }) =>
      Patient(
        id: id,
        fullName: fullName ?? this.fullName,
        ageYears: ageYears ?? this.ageYears,
        sex: sex ?? this.sex,
        clinicRef: clinicRef ?? this.clinicRef,
        dateOfBirth: dateOfBirth ?? this.dateOfBirth,
        phone: phone ?? this.phone,
        notes: notes ?? this.notes,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'full_name': fullName,
        'age_years': ageYears,
        'sex': sex,
        'clinic_ref': clinicRef,
        'date_of_birth': dateOfBirth?.toIso8601String(),
        'phone': phone,
        'notes': notes,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory Patient.fromMap(Map<String, Object?> map) => Patient(
        id: map['id'] as String,
        fullName: map['full_name'] as String,
        ageYears: (map['age_years'] as num).toInt(),
        sex: map['sex'] as String,
        clinicRef: map['clinic_ref'] as String?,
        dateOfBirth: _parseDate(map['date_of_birth']),
        phone: map['phone'] as String?,
        notes: map['notes'] as String?,
        createdAt: _parseDate(map['created_at']) ?? DateTime.now(),
        updatedAt: _parseDate(map['updated_at']) ?? DateTime.now(),
      );

  static DateTime? _parseDate(Object? v) =>
      v == null ? null : DateTime.parse(v as String);

  @override
  bool operator ==(Object other) => other is Patient && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
