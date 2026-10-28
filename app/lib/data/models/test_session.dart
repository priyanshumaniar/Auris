import 'dart:convert';

import '../../core/audiometry/audiometry.dart';
import '../../core/audiometry/calibration.dart';
import '../../core/audiometry/classification.dart';
import 'test_protocol.dart';

/// What kind of result a [ThresholdPoint] holds, beyond its number.
enum ThresholdQualifier {
  /// An ordinary threshold that met the ascending criterion.
  measured,

  /// Heard reliably at the quietest level the app can present. The true
  /// threshold is at or below the recorded value.
  atFloor,

  /// The search ran out of presentations before the criterion was met. There
  /// is no threshold to report, and the frequency should be retested.
  notEstablished,
}

/// One threshold measurement: a single ear at a single frequency.
class ThresholdPoint {
  const ThresholdPoint({
    required this.ear,
    required this.frequencyHz,
    required this.thresholdDbHl,
    required this.noResponse,
    this.tonesPresented = 0,
    this.catchTrials = 0,
    this.falsePositives = 0,
    this.qualifier = ThresholdQualifier.measured,
  });

  final Ear ear;
  final int frequencyHz;

  /// Threshold in dB HL, or null when the patient did not respond at the
  /// maximum presentable level.
  final int? thresholdDbHl;

  /// True when the point is a "no response" - plotted as an arrow on the
  /// audiogram, never as a threshold.
  final bool noResponse;

  final int tonesPresented;
  final int catchTrials;
  final int falsePositives;

  final ThresholdQualifier qualifier;

  bool get isAtFloor => qualifier == ThresholdQualifier.atFloor;
  bool get isNotEstablished => qualifier == ThresholdQualifier.notEstablished;

  Map<String, Object?> toMap(String sessionId) => {
        'session_id': sessionId,
        'ear': ear.name,
        'frequency_hz': frequencyHz,
        'threshold_db_hl': thresholdDbHl,
        'no_response': noResponse ? 1 : 0,
        'tones_presented': tonesPresented,
        'catch_trials': catchTrials,
        'false_positives': falsePositives,
        // Null for an ordinary threshold, so rows from older versions and
        // new ordinary rows look the same.
        'qualifier':
            qualifier == ThresholdQualifier.measured ? null : qualifier.name,
      };

  factory ThresholdPoint.fromMap(Map<String, Object?> map) => ThresholdPoint(
        ear: Ear.values.byName(map['ear'] as String),
        frequencyHz: (map['frequency_hz'] as num).toInt(),
        thresholdDbHl: (map['threshold_db_hl'] as num?)?.toInt(),
        noResponse: readFlag(map['no_response']),
        tonesPresented: (map['tones_presented'] as num?)?.toInt() ?? 0,
        catchTrials: (map['catch_trials'] as num?)?.toInt() ?? 0,
        falsePositives: (map['false_positives'] as num?)?.toInt() ?? 0,
        qualifier: ThresholdQualifier.values.firstWhere(
          (q) => q.name == map['qualifier'],
          orElse: () => ThresholdQualifier.measured,
        ),
      );
}

/// A frequency where the two ears differ by at least the interaural
/// attenuation, so the worse ear's result may be the better ear hearing the
/// tone across the head (a "shadow" response). BSA (2018) masking rule 1.
class MaskingFlag {
  const MaskingFlag({
    required this.frequencyHz,
    required this.worseEar,
    required this.differenceDb,
    required this.isLowerBound,
  });

  final int frequencyHz;
  final Ear worseEar;
  final int differenceDb;

  /// True when the worse ear was a no-response, so the real difference is at
  /// least [differenceDb].
  final bool isLowerBound;
}

/// A completed (or in-progress) audiometric test.
class TestSession {
  const TestSession({
    required this.id,
    required this.patientId,
    required this.testedAt,
    required this.clinicianName,
    required this.points,
    required this.calibration,
    this.notes,
    this.isComplete = false,
    this.syncedAt,
    this.protocol,
  });

  final String id;
  final String patientId;
  final DateTime testedAt;
  final String clinicianName;
  final List<ThresholdPoint> points;

  /// The calibration in force when this test was run, stored with the result.
  ///
  /// Recalibrating the device later must not silently change the meaning of
  /// historical audiograms, so each session carries its own snapshot.
  final CalibrationProfile calibration;

  final String? notes;
  final bool isComplete;

  /// When this session was last pushed to the cloud; null means local-only.
  final DateTime? syncedAt;

  /// How the test was run. Null for sessions saved before this was recorded.
  final TestProtocolRecord? protocol;

  /// Thresholds for [ear], keyed by frequency. A null value is a no-response.
  ///
  /// Frequencies whose threshold was not established are left out entirely:
  /// they have no number to plot or average, and must not read as a
  /// no-response either.
  Map<int, int?> thresholdsFor(Ear ear) => {
        for (final p in points.where((p) => p.ear == ear && !p.isNotEstablished))
          p.frequencyHz: p.noResponse ? null : p.thresholdDbHl,
      };

  /// Frequencies in [ear] reported as "at or below" the quietest level.
  Set<int> floorFrequenciesFor(Ear ear) => {
        for (final p in points)
          if (p.ear == ear && p.isAtFloor) p.frequencyHz,
      };

  /// Frequencies in [ear] where no threshold could be established.
  Set<int> notEstablishedFor(Ear ear) => {
        for (final p in points)
          if (p.ear == ear && p.isNotEstablished) p.frequencyHz,
      };

  /// Frequencies where masking would be needed (BSA 2018 rule 1), using the
  /// interaural attenuation of the transducer recorded for this test.
  List<MaskingFlag> get maskingFlags {
    final limit = (protocol?.transducerType ?? TransducerType.headphones)
        .interauralAttenuationDb;
    final right = thresholdsFor(Ear.right);
    final left = thresholdsFor(Ear.left);
    final flags = <MaskingFlag>[];
    for (final hz in kAudiometricFrequenciesHz) {
      if (!right.containsKey(hz) || !left.containsKey(hz)) continue;
      final r = right[hz];
      final l = left[hz];
      if (r == null && l == null) continue;
      // A no-response is at least the loudest level presented there (lower
      // than the maximum where the headphones could not reach it), so the
      // difference is a lower bound.
      final rLevel = r ?? protocol?.maxLevelFor(Ear.right, hz) ?? kMaxLevelDbHl;
      final lLevel = l ?? protocol?.maxLevelFor(Ear.left, hz) ?? kMaxLevelDbHl;
      final difference = (rLevel - lLevel).abs();
      if (difference < limit) continue;
      final worse = rLevel > lLevel ? Ear.right : Ear.left;
      flags.add(MaskingFlag(
        frequencyHz: hz,
        worseEar: worse,
        differenceDb: difference,
        isLowerBound: (worse == Ear.right ? r : l) == null,
      ));
    }
    return flags;
  }

  PureToneAverage? ptaFor(Ear ear) =>
      PureToneAverage.compute(thresholdsFor(ear));

  /// The PTA for [ear] as text, or null when no PTA frequency was tested.
  ///
  /// When a contributing threshold was at the quietest level the app can
  /// present, the true average is at or below the value, so it gets "≤".
  String? ptaDisplayFor(Ear ear) {
    final pta = ptaFor(ear);
    if (pta == null) return null;
    final floor = floorFrequenciesFor(ear);
    final belowFloor = pta.frequenciesUsed.any(floor.contains);
    if (belowFloor && !pta.isLowerBound) {
      return '≤${pta.valueDbHl.toStringAsFixed(0)} dB HL';
    }
    return pta.displayValue;
  }

  /// Frequencies actually measured, in standard reporting order.
  List<int> get testedFrequencies {
    final present = points.map((p) => p.frequencyHz).toSet();
    return kAudiometricFrequenciesHz.where(present.contains).toList();
  }

  Set<Ear> get testedEars => points.map((p) => p.ear).toSet();

  int get totalFalsePositives =>
      points.fold(0, (sum, p) => sum + p.falsePositives);
  int get totalCatchTrials => points.fold(0, (sum, p) => sum + p.catchTrials);

  /// False-positive rate across the whole session, or null if no catch trials
  /// were run.
  double? get falsePositiveRate =>
      totalCatchTrials == 0 ? null : totalFalsePositives / totalCatchTrials;

  int get totalTonesPresented =>
      points.fold(0, (sum, p) => sum + p.tonesPresented);

  int get pressesBetweenTones => protocol?.totalPressesBetweenTones ?? 0;

  /// Presses between tones as a share of tones presented, or null when no
  /// tones were recorded.
  double? get pressesBetweenTonesRate => totalTonesPresented == 0
      ? null
      : pressesBetweenTones / totalTonesPresented;

  /// The limit used for both false-positive measures. Neither ASHA (2005) nor
  /// BSA (2018) sets a number; 25% is this app's own cut-off.
  static const double unreliableRate = 0.25;

  bool get isReliable =>
      (falsePositiveRate ?? 0) <= unreliableRate &&
      (pressesBetweenTonesRate ?? 0) <= unreliableRate;

  /// Plain-language reasons to treat this result with caution. Empty when
  /// nothing was found.
  List<String> get reliabilityConcerns {
    final concerns = <String>[];
    final rate = falsePositiveRate;
    if (rate != null && rate > unreliableRate) {
      concerns.add('The patient responded to $totalFalsePositives of '
          '$totalCatchTrials silent catch trials.');
    }
    final between = pressesBetweenTonesRate;
    if (between != null && between > unreliableRate) {
      concerns.add('The patient pressed $pressesBetweenTones times while no '
          'tone was playing, against $totalTonesPresented tones presented.');
    }
    for (final r in protocol?.failedRetests ?? const <RetestRecord>[]) {
      final diff = r.differenceDb;
      concerns.add('${r.ear.label} ear ${formatHzLong(r.frequencyHz)} retest '
          '${diff == null ? 'did not match the first result' : 'differed by $diff dB'} '
          '(more than $kRetestToleranceDb dB).');
    }
    final notEstablished = points.where((p) => p.isNotEstablished).toList();
    if (notEstablished.isNotEmpty) {
      concerns.add('No threshold could be established at '
          '${notEstablished.map((p) => '${formatHzLong(p.frequencyHz)} (${p.ear.label.toLowerCase()})').join(', ')}.');
    }
    final familiarisation = protocol?.familiarisation;
    if (familiarisation != null && !familiarisation.onsetOffsetMatched) {
      concerns.add('During familiarisation the responses did not match the '
          'start and end of the tone.');
    }
    return concerns;
  }

  TestSession copyWith({
    List<ThresholdPoint>? points,
    String? notes,
    bool? isComplete,
    DateTime? syncedAt,
    TestProtocolRecord? protocol,
  }) =>
      TestSession(
        id: id,
        patientId: patientId,
        testedAt: testedAt,
        clinicianName: clinicianName,
        points: points ?? this.points,
        calibration: calibration,
        notes: notes ?? this.notes,
        isComplete: isComplete ?? this.isComplete,
        syncedAt: syncedAt ?? this.syncedAt,
        protocol: protocol ?? this.protocol,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'patient_id': patientId,
        'tested_at': testedAt.toIso8601String(),
        'clinician_name': clinicianName,
        'calibration_json': calibration.encode(),
        'notes': notes,
        'is_complete': isComplete ? 1 : 0,
        'synced_at': syncedAt?.toIso8601String(),
        'protocol_json':
            protocol == null ? null : jsonEncode(protocol!.toJson()),
      };

  /// Rebuilds a session from its row plus its threshold rows.
  factory TestSession.fromMap(
    Map<String, Object?> map,
    List<ThresholdPoint> points,
  ) =>
      TestSession(
        id: map['id'] as String,
        patientId: map['patient_id'] as String,
        testedAt: DateTime.parse(map['tested_at'] as String),
        clinicianName: map['clinician_name'] as String? ?? 'Unknown',
        points: points,
        calibration: _decodeCalibration(map['calibration_json']),
        notes: map['notes'] as String?,
        isComplete: readFlag(map['is_complete']),
        syncedAt: map['synced_at'] == null
            ? null
            : DateTime.parse(map['synced_at'] as String),
        protocol: _decodeProtocol(map['protocol_json']),
      );

  static TestProtocolRecord? _decodeProtocol(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, Object?>) return null;
      return TestProtocolRecord.fromJson(json);
    } catch (_) {
      // Malformed or of an unexpected shape: the measurements still stand.
      return null;
    }
  }

  static CalibrationProfile _decodeCalibration(Object? raw) {
    if (raw is! String || raw.isEmpty) return const CalibrationProfile();
    try {
      return CalibrationProfile.decode(raw);
    } catch (_) {
      // A corrupt snapshot must not make an entire historical record
      // unreadable; fall back to the uncalibrated default.
      return const CalibrationProfile();
    }
  }
}

/// Reads a yes/no column. SQLite stores 1 or 0; Postgres (the cloud copy)
/// returns true or false.
bool readFlag(Object? v) => v == true || (v is num && v != 0);
