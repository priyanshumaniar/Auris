import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../core/audiometry/audiometry.dart';
import '../core/audiometry/calibration.dart';
import 'local_database.dart';

/// Which ears a calibration run covered.
enum CalibrationEarChoice {
  both('Both ears'),
  right('Right ear only'),
  left('Left ear only');

  const CalibrationEarChoice(this.label);
  final String label;

  List<Ear> get ears => switch (this) {
        CalibrationEarChoice.both => const [Ear.right, Ear.left],
        CalibrationEarChoice.right => const [Ear.right],
        CalibrationEarChoice.left => const [Ear.left],
      };

  static CalibrationEarChoice fromId(String? id) => CalibrationEarChoice.values
      .firstWhere((c) => c.name == id, orElse: () => CalibrationEarChoice.both);
}

/// What a calibration run did to one ear.
enum EarAction {
  measured('Measured'),
  copied('Copied from the other ear'),
  kept('Kept as it was'),
  reset('Reset to uncalibrated');

  const EarAction(this.label);
  final String label;

  static EarAction fromId(String? id) => EarAction.values
      .firstWhere((a) => a.name == id, orElse: () => EarAction.kept);
}

/// One ear's line in a calibration record.
class EarRecord {
  const EarRecord({
    required this.action,
    required this.methodAfter,
    required this.offsetAfterDb,
    this.correctionDb,
  });

  final EarAction action;

  /// The correction this run applied, in dB. Null when the ear was not
  /// measured this time.
  final double? correctionDb;

  final CalibrationMethod methodAfter;
  final double offsetAfterDb;

  Map<String, dynamic> toJson() => {
        'action': action.name,
        if (correctionDb != null) 'correctionDb': correctionDb,
        'methodAfter': methodAfter.name,
        'offsetAfterDb': offsetAfterDb,
      };

  factory EarRecord.fromJson(Map<String, dynamic> json) => EarRecord(
        action: EarAction.fromId(json['action'] as String?),
        correctionDb: (json['correctionDb'] as num?)?.toDouble(),
        methodAfter: CalibrationMethod.fromId(json['methodAfter'] as String?),
        offsetAfterDb: (json['offsetAfterDb'] as num?)?.toDouble() ?? 0.0,
      );
}

/// A calibration done on this device, kept so it can be reviewed and
/// reprinted later.
class CalibrationEvent {
  const CalibrationEvent({
    required this.id,
    required this.performedAt,
    required this.performedBy,
    required this.isReset,
    required this.method,
    required this.earChoice,
    required this.right,
    required this.left,
    required this.profile,
    this.imbalanceDb,
    this.imbalanceAccepted = false,
    this.listenerConfirmedEqualEars = false,
  });

  final String id;
  final DateTime performedAt;

  /// Display name of the signed-in user who did it.
  final String performedBy;

  /// True for "Reset calibration", which is recorded too.
  final bool isReset;

  /// The method used in this run.
  final CalibrationMethod method;
  final CalibrationEarChoice earChoice;
  final EarRecord right;
  final EarRecord left;

  /// The complete calibration that resulted.
  final CalibrationProfile profile;

  /// Left/right difference when both ears were measured in this run.
  final double? imbalanceDb;

  /// The user chose to save despite a large left/right difference.
  final bool imbalanceAccepted;

  /// For a human-listener calibration of both ears: the user confirmed the
  /// listener has no known hearing difference between their ears.
  final bool listenerConfirmedEqualEars;

  EarRecord recordFor(Ear ear) => ear == Ear.right ? right : left;

  Map<String, dynamic> detailsJson() => {
        'isReset': isReset,
        'method': method.name,
        'earChoice': earChoice.name,
        'right': right.toJson(),
        'left': left.toJson(),
        if (imbalanceDb != null) 'imbalanceDb': imbalanceDb,
        'imbalanceAccepted': imbalanceAccepted,
        'listenerConfirmedEqualEars': listenerConfirmedEqualEars,
        'transducerName': profile.transducerName,
      };

  factory CalibrationEvent.fromRow(Map<String, Object?> row) {
    final details =
        jsonDecode(row['details_json'] as String) as Map<String, dynamic>;
    return CalibrationEvent(
      id: row['id'] as String,
      performedAt: DateTime.parse(row['performed_at'] as String).toLocal(),
      performedBy: row['performed_by'] as String,
      isReset: details['isReset'] as bool? ?? false,
      method: CalibrationMethod.fromId(details['method'] as String?),
      earChoice: CalibrationEarChoice.fromId(details['earChoice'] as String?),
      right: EarRecord.fromJson(
          Map<String, dynamic>.from(details['right'] as Map? ?? const {})),
      left: EarRecord.fromJson(
          Map<String, dynamic>.from(details['left'] as Map? ?? const {})),
      imbalanceDb: (details['imbalanceDb'] as num?)?.toDouble(),
      imbalanceAccepted: details['imbalanceAccepted'] as bool? ?? false,
      listenerConfirmedEqualEars:
          details['listenerConfirmedEqualEars'] as bool? ?? false,
      profile: CalibrationProfile.decode(row['profile_json'] as String),
    );
  }
}

/// Reads and writes this device's calibration history.
class CalibrationHistory {
  CalibrationHistory(this._local);

  final LocalDatabase _local;
  Database get _db => _local.db;

  static const _uuid = Uuid();

  /// Records a calibration and returns the stored event.
  Future<CalibrationEvent> record({
    required String performedBy,
    required CalibrationMethod method,
    required CalibrationEarChoice earChoice,
    required EarRecord right,
    required EarRecord left,
    required CalibrationProfile profile,
    bool isReset = false,
    double? imbalanceDb,
    bool imbalanceAccepted = false,
    bool listenerConfirmedEqualEars = false,
    DateTime? at,
  }) async {
    final event = CalibrationEvent(
      id: _uuid.v4(),
      performedAt: at ?? DateTime.now(),
      performedBy: performedBy,
      isReset: isReset,
      method: method,
      earChoice: earChoice,
      right: right,
      left: left,
      profile: profile,
      imbalanceDb: imbalanceDb,
      imbalanceAccepted: imbalanceAccepted,
      listenerConfirmedEqualEars: listenerConfirmedEqualEars,
    );
    await _db.insert('calibration_events', {
      'id': event.id,
      'performed_at': event.performedAt.toUtc().toIso8601String(),
      'performed_by': event.performedBy,
      'details_json': jsonEncode(event.detailsJson()),
      'profile_json': profile.encode(),
    });
    return event;
  }

  /// Every recorded calibration, newest first.
  Future<List<CalibrationEvent>> all() async {
    final rows = await _db.query('calibration_events',
        orderBy: 'performed_at DESC');
    final out = <CalibrationEvent>[];
    for (final row in rows) {
      try {
        out.add(CalibrationEvent.fromRow(row));
      } catch (_) {
        // A damaged row must not hide the rest of the history.
      }
    }
    return out;
  }
}
