import 'package:auris/data/account_service.dart';
import 'package:auris/data/models/change_request.dart';
import 'package:auris/data/models/clinic.dart';
import 'package:auris/data/models/clinic_role.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _row({
  String id = 'r1',
  String kind = 'profile',
  String status = 'pending',
  Map<String, dynamic>? payload,
  Map<String, dynamic>? previous,
  String? created,
}) => {
  'id': id,
  'user_id': 'u1',
  'user_email': 'a@example.com',
  'user_name': 'Dr. A',
  'kind': kind,
  'clinic_id': 'c1',
  'reviewer_level': 'clinic_admin',
  'payload': payload ?? {},
  'previous': previous ?? {},
  'status': status,
  'created_at': created ?? '2026-10-20T10:00:00Z',
};

void main() {
  group('ChangeRequest', () {
    test('reads a row', () {
      final r = ChangeRequest.fromRow(_row(status: 'rejected')
        ..['decision_note'] = 'Wrong number'
        ..['reviewed_at'] = '2026-10-21T10:00:00Z');
      expect(r.kind, ChangeKind.profile);
      expect(r.status, ChangeStatus.rejected);
      expect(r.isPending, isFalse);
      expect(r.decisionNote, 'Wrong number');
      expect(r.reviewedAt, isNotNull);
      expect(r.who, 'Dr. A');
    });

    test('lists only the fields that change, old beside new', () {
      final r = ChangeRequest.fromRow(_row(
        payload: {
          'display_name': 'Dr. A',
          'phone': '999',
          'qualification': 'MS (ENT)',
          'registration_no': null,
        },
        previous: {
          'display_name': 'Dr. A',
          'phone': null,
          'qualification': 'MBBS',
          'registration_no': null,
        },
      ));
      expect(r.differences, [
        ('Phone', '(none)', '999'),
        ('Qualification', 'MBBS', 'MS (ENT)'),
      ]);
    });

    test('names the clinic asked for, with its number', () {
      final r = ChangeRequest.fromRow(_row(
        kind: 'join',
        payload: {'clinic_name': 'Clinic B', 'clinic_no': 12},
      ));
      expect(r.requestedClinicLabel, 'Clinic B (${formatClinicNo(12)})');
      expect(ChangeRequest.fromRow(_row()).requestedClinicLabel, isNull);
    });

    test('a deleted account still has a name to show', () {
      final r = ChangeRequest.fromRow(_row()
        ..['user_id'] = null
        ..['user_name'] = null
        ..['user_email'] = null);
      expect(r.userId, isNull);
      expect(r.who, 'A deleted account');
    });

    test('every kind and status in the database is known', () {
      for (final k in [
        'profile', 'email', 'join', 'move', 'clinic', 'delete', 'leave',
      ]) {
        expect(ChangeKind.fromId(k)?.id, k);
      }
      for (final s in [
        'pending', 'approved', 'rejected', 'cancelled', 'completed', 'flagged',
      ]) {
        expect(ChangeStatus.fromId(s).id, s);
      }
      expect(ChangeKind.fromId('other'), isNull);
    });
  });

  group('MyAccount', () {
    const me = ClinicAccount(
      id: 'u1',
      displayName: 'Dr. A',
      role: ClinicRole.clinician,
    );

    test('finds the open request of a kind', () {
      final account = MyAccount(profile: me, requests: [
        ChangeRequest.fromRow(_row(id: 'a', kind: 'email', status: 'rejected')),
        ChangeRequest.fromRow(_row(id: 'b', kind: 'profile')),
      ]);
      expect(account.open(ChangeKind.profile)?.id, 'b');
      expect(account.open(ChangeKind.email), isNull);
    });

    test('an approved email change waits for its code', () {
      final account = MyAccount(profile: me, requests: [
        ChangeRequest.fromRow(_row(
          id: 'new',
          kind: 'email',
          status: 'approved',
          payload: {'email': 'new@example.com'},
        )),
      ]);
      expect(account.emailToConfirm?.id, 'new');
    });

    test('only the newest email request counts', () {
      // Requests come newest first.
      final account = MyAccount(profile: me, requests: [
        ChangeRequest.fromRow(_row(id: 'done', kind: 'email', status: 'completed')),
        ChangeRequest.fromRow(_row(id: 'old', kind: 'email', status: 'approved')),
      ]);
      expect(account.emailToConfirm, isNull);
    });

    test('labels the clinic a pending account asked for', () {
      expect(
        const MyAccount(
          profile: me,
          requestedClinicName: 'Clinic B',
          requestedClinicNo: 3,
        ).requestedClinicLabel,
        'Clinic B (CLN-0003)',
      );
      expect(const MyAccount(profile: me).requestedClinicLabel, isNull);
    });
  });
}
