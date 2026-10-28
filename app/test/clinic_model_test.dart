import 'package:auris/data/models/clinic.dart';
import 'package:auris/data/models/clinic_role.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Clinic', () {
    test('reads a row from the clinics table', () {
      final c = Clinic.fromRow({
        'id': 'c1',
        'name': ' Fix Maniar ENT Clinic ',
        'address': '100 Feet Road',
        'phone': '',
        'join_code': 'AUR-7K2PQ',
      });
      expect(c.name, 'Fix Maniar ENT Clinic');
      expect(c.address, '100 Feet Road');
      expect(c.phone, isNull, reason: 'blank means not given');
      expect(c.joinCode, 'AUR-7K2PQ');
      expect(c.details.name, 'Fix Maniar ENT Clinic');
    });

    test('a clinic without a name still reads', () {
      expect(Clinic.fromRow({'id': 'c1', 'name': null}).name, 'Unnamed clinic');
    });
  });

  group('ClinicAccount', () {
    test('reads a pending request', () {
      final a = ClinicAccount.fromRow({
        'id': 'u1',
        'email': 'staff@example.com',
        'display_name': null,
        'role': 'pending',
        'clinic_id': null,
        'requested_clinic_id': 'c1',
        'requested_clinic': 'AUR-7K2PQ',
        'created_at': '2026-10-22T10:00:00Z',
      });
      expect(a.isPending, isTrue);
      expect(
        a.displayName,
        'staff@example.com',
        reason: 'falls back to the email',
      );
      expect(a.requestedClinicId, 'c1');
      expect(a.createdAt, isNotNull);
    });

    test('an unknown role reads as no access', () {
      final a = ClinicAccount.fromRow({
        'id': 'u1',
        'display_name': 'X',
        'role': 'owner',
      });
      expect(a.role, ClinicRole.pending);
    });
  });

  group('Clinic number', () {
    test('reads as CLN- and four digits', () {
      expect(formatClinicNo(7), 'CLN-0007');
      expect(formatClinicNo(1234), 'CLN-1234');
      expect(formatClinicNo(12345), 'CLN-12345');
    });

    test('comes from clinic_no, and survives the cache', () {
      final c = Clinic.fromRow({
        'id': 'c1',
        'name': 'Clinic A',
        'join_code': 'AUR-1',
        'clinic_no': 7,
      });
      expect(c.clinicLabel, 'CLN-0007');
      final back = Clinic.fromJson(c.toJson())!;
      expect(back.clinicNo, 7);
      expect(back.joinCode, 'AUR-1');
      expect(Clinic.fromRow({'id': 'c2', 'name': 'B'}).clinicLabel, isNull);
      expect(Clinic.fromJson({'name': 'no id'}), isNull);
    });
  });

  group('ClinicAccount profile', () {
    test('reads the profile fields', () {
      final a = ClinicAccount.fromRow({
        'id': 'u1',
        'display_name': 'Dr. A',
        'role': 'clinician',
        'phone': ' 98765 ',
        'qualification': 'MS (ENT)',
        'registration_no': 'MMC-123',
        'approved_at': '2026-10-01T09:00:00Z',
        'email_alerts': false,
      });
      expect(a.phone, '98765');
      expect(a.credentials, 'MS (ENT), Reg. No. MMC-123');
      expect(a.approvedAt, isNotNull);
      expect(a.emailAlerts, isFalse);
    });

    test('credentials need at least one part', () {
      ClinicAccount make(String? q, String? r) => ClinicAccount.fromRow({
        'id': 'u1',
        'display_name': 'A',
        'role': 'viewer',
        'qualification': q,
        'registration_no': r,
      });
      expect(make(null, null).credentials, isNull);
      expect(make('BASLP', null).credentials, 'BASLP');
      expect(make(null, '42').credentials, 'Reg. No. 42');
      expect(make('', '  ').credentials, isNull);
    });

    test('email alerts are on unless switched off', () {
      final a = ClinicAccount.fromRow({'id': 'u1', 'role': 'viewer'});
      expect(a.emailAlerts, isTrue);
    });

    test('survives the profile cache round trip', () {
      final a = ClinicAccount.fromRow({
        'id': 'u1',
        'email': 'a@example.com',
        'display_name': 'Dr. A',
        'role': 'admin',
        'clinic_id': 'c1',
        'qualification': 'MS (ENT)',
        'created_at': '2026-10-01T09:00:00.000Z',
        'email_alerts': false,
      });
      final back = ClinicAccount.fromJson(a.toJson())!;
      expect(back.role, ClinicRole.admin);
      expect(back.clinicId, 'c1');
      expect(back.qualification, 'MS (ENT)');
      expect(back.createdAt, a.createdAt);
      expect(back.emailAlerts, isFalse);
      expect(ClinicAccount.fromJson('nope'), isNull);
    });
  });

  group('ClinicDetails', () {
    test('survives the profile cache round trip', () {
      const d = ClinicDetails(name: 'Clinic B', phone: '123');
      final back = ClinicDetails.fromJson(d.toJson())!;
      expect(back.name, 'Clinic B');
      expect(back.phone, '123');
      expect(back.address, isNull);
      expect(ClinicDetails.fromJson({'name': ''}), isNull);
      expect(ClinicDetails.fromJson(null), isNull);
    });
  });
}
