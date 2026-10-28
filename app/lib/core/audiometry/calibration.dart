import 'dart:convert';
import 'dart:math' as math;

import 'audiometry.dart';

/// Reference Equivalent Threshold Sound Pressure Level (RETSPL) for TDH-39
/// supra-aural earphones measured in a 6 cm³ coupler, per ANSI S3.6 / ISO 389-1.
///
/// This is what makes "dB HL" mean anything. 0 dB HL is *not* a fixed sound
/// pressure - it is the median threshold of a normal-hearing young adult, and
/// that threshold differs a lot across frequency: the ear is far less sensitive
/// at 250 Hz than at 1 kHz. To present 40 dB HL at 250 Hz you must produce
/// 40 + 25.5 = 65.5 dB SPL, but at 1 kHz only 40 + 7.0 = 47.0 dB SPL.
///
/// An audiometer that ignores this curve and just plays "40 dB" at every
/// frequency is not measuring hearing level at all.
const Map<int, double> kRetsplTdh39DbSpl = {
  125: 45.0,
  250: 25.5,
  500: 11.5,
  750: 8.0,
  1000: 7.0,
  1500: 6.5,
  2000: 9.0,
  3000: 10.0,
  4000: 9.5,
  6000: 15.5,
  8000: 13.0,
};

/// How a device's calibration was established.
///
/// This is recorded on every test and printed on the report, because the three
/// methods do not carry the same weight and a reader has to be able to tell
/// them apart.
enum CalibrationMethod {
  /// Nothing measured. Levels are internally consistent but not anchored to
  /// real dB HL. Screening only.
  none('Not calibrated', 'Screening only - levels are not real dB HL'),

  /// Anchored against a listener known to have normal hearing.
  ///
  /// The standard "biological check" used in clinics as a daily verification.
  /// It is genuinely useful and far better than nothing, but it inherits every
  /// error in the assumption that the reference listener hears normally - so it
  /// is not a substitute for a meter.
  biological('Biological check',
      'Anchored to a normal-hearing reference listener, not a meter'),

  /// Measured with a sound level meter. The only method that makes the absolute
  /// dB HL values trustworthy.
  soundLevelMeter('Sound level meter', 'Measured against a sound level meter');

  const CalibrationMethod(this.label, this.summary);

  final String label;
  final String summary;

  static CalibrationMethod fromId(String? id) => switch (id) {
        'soundLevelMeter' => CalibrationMethod.soundLevelMeter,
        'biological' => CalibrationMethod.biological,
        // Unknown or missing must mean "not calibrated" - never claim more
        // accuracy than was actually established.
        _ => CalibrationMethod.none,
      };
}

/// Shown in the app and printed on every report that relies on a calibration
/// done with a human listener instead of a sound level meter.
const String kHumanCalibrationWarning =
    'Calibration with a human listener is not a standard calibration. It '
    'relies on that person really having normal, equal hearing in both ears, '
    'a quiet room and careful responses, so the dB HL values it produces may '
    'not be accurate. Use a sound level meter where results will inform '
    'clinical decisions.';

/// How one ear's correction came about.
enum EarCalibrationSource {
  /// Measured on this ear, or carried over from a profile saved before
  /// per-ear calibration existed (which applied one value to both ears).
  measured,

  /// Copied from the other ear after a single-ear calibration, at the
  /// administrator's request. Shown and printed as such, never as measured.
  copiedFromOtherEar;

  static EarCalibrationSource fromId(String? id) =>
      id == 'copiedFromOtherEar' ? copiedFromOtherEar : measured;
}

/// The calibration of one side of the headphones.
///
/// Left and right drivers are rarely identical, and one side can be partly
/// blocked or damaged. With a single shared correction, any difference between
/// them shows up on the audiogram as a difference between the patient's ears,
/// which is exactly what a hearing test must not invent. So each ear carries
/// its own correction on top of the shared fields of [CalibrationProfile].
class EarCalibration {
  const EarCalibration({
    this.method = CalibrationMethod.none,
    this.offsetDb = 0.0,
    this.source = EarCalibrationSource.measured,
    this.calibratedAt,
  });

  /// How this ear was calibrated. [CalibrationMethod.none] = uncalibrated.
  final CalibrationMethod method;

  /// Added to the required output for this ear only, in dB.
  final double offsetDb;

  final EarCalibrationSource source;

  /// When this ear was last calibrated. Null for profiles saved before
  /// per-ear calibration existed.
  final DateTime? calibratedAt;

  bool get hasCalibration => method != CalibrationMethod.none;
  bool get isCopied => source == EarCalibrationSource.copiedFromOtherEar;

  Map<String, dynamic> toJson() => {
        'method': method.name,
        'offsetDb': offsetDb,
        'source': source.name,
        if (calibratedAt != null)
          'calibratedAt': calibratedAt!.toUtc().toIso8601String(),
      };

  factory EarCalibration.fromJson(Map<String, dynamic> json) => EarCalibration(
        method: CalibrationMethod.fromId(json['method'] as String?),
        offsetDb: (json['offsetDb'] as num?)?.toDouble() ?? 0.0,
        source: EarCalibrationSource.fromId(json['source'] as String?),
        calibratedAt: DateTime.tryParse(json['calibratedAt'] as String? ?? '')
            ?.toLocal(),
      );
}

/// Ranks methods from weakest to strongest, so a profile can report the
/// weakest calibration in force. A report must never claim more accuracy than
/// its least-calibrated ear has.
int _strength(CalibrationMethod m) => switch (m) {
      CalibrationMethod.none => 0,
      CalibrationMethod.biological => 1,
      CalibrationMethod.soundLevelMeter => 2,
    };

/// Per-device calibration for the output chain (app → OS mixer → headphones).
///
/// ## Why this exists
///
/// The app controls a *digital* amplitude. What reaches the eardrum depends on
/// the OS volume setting, the DAC, the amplifier and the headphones - none of
/// which this app can measure. Without calibration against a sound-level meter
/// or a reference audiometer, the numbers on the audiogram are internally
/// consistent but not anchored to real dB HL.
///
/// [fullScaleOutputDbSpl] is the anchor: the SPL produced at the eardrum by a
/// full-scale (0 dBFS) sine at the clinic's fixed volume setting. Measuring it
/// once per device+headphone pair converts this from a screening tool into
/// something whose absolute values mean something.
class CalibrationProfile {
  const CalibrationProfile({
    this.fullScaleOutputDbSpl = kDefaultFullScaleDbSpl,
    this.globalOffsetDb = 0.0,
    this.perFrequencyOffsetDb = const {},
    CalibrationMethod method = CalibrationMethod.none,
    this.transducerName = 'Uncalibrated headphones',
    this.rightEar,
    this.leftEar,
  }) : baseMethod = method;

  /// Assumed SPL at 0 dBFS. The default is a plausible figure for consumer
  /// headphones at a moderate volume setting; it is a placeholder, not a
  /// measurement, which is why [isCalibrated] defaults to false.
  static const double kDefaultFullScaleDbSpl = 100.0;

  final double fullScaleOutputDbSpl;

  /// Broadband correction applied at every frequency.
  final double globalOffsetDb;

  /// Frequency-specific corrections, in dB, keyed by frequency in Hz. Populated
  /// by a full calibration against a sound-level meter.
  final Map<int, double> perFrequencyOffsetDb;

  /// The method stored for the profile as a whole. Profiles saved before
  /// per-ear calibration existed have only this, and it applies to both ears.
  final CalibrationMethod baseMethod;

  /// Per-ear calibration. Null means "same as the profile as a whole", which
  /// is how every profile saved before per-ear calibration reads.
  final EarCalibration? rightEar;
  final EarCalibration? leftEar;

  /// The calibration in force for [side].
  EarCalibration ear(Ear side) =>
      (side == Ear.right ? rightEar : leftEar) ??
      EarCalibration(method: baseMethod);

  /// How this device was calibrated: the WEAKER of the two ears, so that
  /// nothing reads as better calibrated than its worst side.
  CalibrationMethod get method {
    final r = ear(Ear.right).method, l = ear(Ear.left).method;
    return _strength(r) <= _strength(l) ? r : l;
  }

  /// True only when both ears were measured against a sound level meter, the
  /// one case where the absolute dB HL values can be relied on. A biological
  /// check improves the numbers but does not earn this.
  bool get isCalibrated => method == CalibrationMethod.soundLevelMeter;

  /// True when *some* anchoring has been done on at least one ear.
  bool get hasAnyCalibration =>
      ear(Ear.right).hasCalibration || ear(Ear.left).hasCalibration;

  /// True when at least one ear was calibrated with a human listener rather
  /// than a meter. Such calibration is not standardised, and the app and the
  /// reports say so wherever it applies.
  bool get usesHumanListener =>
      ear(Ear.right).method == CalibrationMethod.biological ||
      ear(Ear.left).method == CalibrationMethod.biological;

  /// Everything this profile adds to [side] compared with an uncalibrated
  /// device, in dB: the shared correction, the ear's own correction, and any
  /// change to the full-scale figure made by an older meter calibration.
  double totalCorrectionDb(Ear side) =>
      globalOffsetDb +
      ear(side).offsetDb -
      (fullScaleOutputDbSpl - kDefaultFullScaleDbSpl);

  /// Difference between the two ears' corrections, in dB. A large value means
  /// the two sides of the headphones are not equally loud.
  double get earImbalanceDb =>
      (ear(Ear.right).offsetDb - ear(Ear.left).offsetDb).abs();

  final String transducerName;

  /// RETSPL at [frequencyHz], linearly interpolated between table entries for
  /// frequencies that are not tabulated.
  static double retsplFor(int frequencyHz) {
    final exact = kRetsplTdh39DbSpl[frequencyHz];
    if (exact != null) return exact;

    final keys = kRetsplTdh39DbSpl.keys.toList()..sort();
    if (frequencyHz <= keys.first) return kRetsplTdh39DbSpl[keys.first]!;
    if (frequencyHz >= keys.last) return kRetsplTdh39DbSpl[keys.last]!;

    for (var i = 0; i < keys.length - 1; i++) {
      final lo = keys[i], hi = keys[i + 1];
      if (frequencyHz > lo && frequencyHz < hi) {
        final t = (frequencyHz - lo) / (hi - lo);
        return kRetsplTdh39DbSpl[lo]! +
            t * (kRetsplTdh39DbSpl[hi]! - kRetsplTdh39DbSpl[lo]!);
      }
    }
    return kRetsplTdh39DbSpl[keys.last]!;
  }

  /// Target sound pressure level for a given hearing level at a given frequency.
  double targetDbSpl(int frequencyHz, num levelDbHl) =>
      levelDbHl +
      retsplFor(frequencyHz) +
      globalOffsetDb +
      (perFrequencyOffsetDb[frequencyHz] ?? 0.0);

  /// Digital amplitude (linear, 0.0-1.0) for a hearing level at a frequency.
  ///
  /// Returns 0 when the requested level is quieter than the output chain can
  /// represent, and clamps to 1.0 (full scale) when it would otherwise clip -
  /// see [canRepresent] to detect the latter before presenting a tone.
  ///
  /// Pass [ear] for anything that is actually played, so that ear's own
  /// correction is applied. Without it only the shared fields are used.
  double amplitudeFor(int frequencyHz, num levelDbHl, {Ear? ear}) {
    final dbFs = targetDbSpl(frequencyHz, levelDbHl) +
        _earOffset(ear) -
        fullScaleOutputDbSpl;
    if (dbFs >= 0) return 1.0;
    final amplitude = math.pow(10, dbFs / 20).toDouble();
    return amplitude.isFinite ? amplitude.clamp(0.0, 1.0) : 0.0;
  }

  /// Whether the requested level can be produced without clipping.
  ///
  /// When this is false the tone will be presented at full scale, which is
  /// quieter than requested - the reading would be wrong, so the UI must say so
  /// rather than silently recording a threshold.
  bool canRepresent(int frequencyHz, num levelDbHl, {Ear? ear}) =>
      targetDbSpl(frequencyHz, levelDbHl) + _earOffset(ear) <=
      fullScaleOutputDbSpl;

  double _earOffset(Ear? side) => side == null ? 0.0 : ear(side).offsetDb;

  // ------------------------------------------------------- per-ear updates

  /// Returns a profile with [measuredEar] corrected by [correctionDb].
  ///
  /// The correction is relative to what the ear was already playing, so it
  /// stacks on whatever calibration was in force. The other ear is made
  /// explicit but otherwise unchanged ("keep as it is").
  CalibrationProfile withMeasuredEar(
    Ear measuredEar, {
    required CalibrationMethod method,
    required double correctionDb,
    required DateTime at,
    String? transducerName,
  }) {
    final current = ear(measuredEar);
    final updated = EarCalibration(
      method: method,
      offsetDb: current.offsetDb + correctionDb,
      source: EarCalibrationSource.measured,
      calibratedAt: at,
    );
    return _withEars(
      right: measuredEar == Ear.right ? updated : ear(Ear.right),
      left: measuredEar == Ear.left ? updated : ear(Ear.left),
      transducerName: transducerName,
    );
  }

  /// Copies [from]'s calibration onto the other ear, marked as copied.
  CalibrationProfile copyEarToOther(Ear from, {required DateTime at}) {
    final source = ear(from);
    final copy = EarCalibration(
      method: source.method,
      offsetDb: source.offsetDb,
      source: EarCalibrationSource.copiedFromOtherEar,
      calibratedAt: at,
    );
    return _withEars(
      right: from == Ear.right ? source : copy,
      left: from == Ear.left ? source : copy,
    );
  }

  CalibrationProfile _withEars({
    required EarCalibration right,
    required EarCalibration left,
    String? transducerName,
  }) {
    final next = CalibrationProfile(
      fullScaleOutputDbSpl: fullScaleOutputDbSpl,
      globalOffsetDb: globalOffsetDb,
      perFrequencyOffsetDb: perFrequencyOffsetDb,
      transducerName: transducerName ?? this.transducerName,
      rightEar: right,
      leftEar: left,
    );
    // Keep the stored profile-level method equal to the effective one, so an
    // older build reading this profile never sees more than the weakest ear.
    return next.copyWith(method: next.method);
  }

  CalibrationProfile copyWith({
    double? fullScaleOutputDbSpl,
    double? globalOffsetDb,
    Map<int, double>? perFrequencyOffsetDb,
    CalibrationMethod? method,
    String? transducerName,
    EarCalibration? rightEar,
    EarCalibration? leftEar,
  }) =>
      CalibrationProfile(
        fullScaleOutputDbSpl: fullScaleOutputDbSpl ?? this.fullScaleOutputDbSpl,
        globalOffsetDb: globalOffsetDb ?? this.globalOffsetDb,
        perFrequencyOffsetDb: perFrequencyOffsetDb ?? this.perFrequencyOffsetDb,
        method: method ?? baseMethod,
        transducerName: transducerName ?? this.transducerName,
        rightEar: rightEar ?? this.rightEar,
        leftEar: leftEar ?? this.leftEar,
      );

  Map<String, dynamic> toJson() => {
        'fullScaleOutputDbSpl': fullScaleOutputDbSpl,
        'globalOffsetDb': globalOffsetDb,
        'perFrequencyOffsetDb':
            perFrequencyOffsetDb.map((k, v) => MapEntry(k.toString(), v)),
        'method': method.name,
        if (rightEar != null || leftEar != null)
          'ears': {
            'right': ear(Ear.right).toJson(),
            'left': ear(Ear.left).toJson(),
          },
        // Kept so a profile written by this version stays readable by an older
        // build, which only knew the boolean.
        'isCalibrated': isCalibrated,
        'transducerName': transducerName,
      };

  factory CalibrationProfile.fromJson(Map<String, dynamic> json) {
    final raw = (json['perFrequencyOffsetDb'] as Map?) ?? const {};

    // Profiles written before methods existed carry only `isCalibrated`. A
    // true there meant a meter measurement, which is the only method that
    // version could perform.
    final method = json.containsKey('method')
        ? CalibrationMethod.fromId(json['method'] as String?)
        : ((json['isCalibrated'] as bool? ?? false)
            ? CalibrationMethod.soundLevelMeter
            : CalibrationMethod.none);

    return CalibrationProfile(
      fullScaleOutputDbSpl:
          (json['fullScaleOutputDbSpl'] as num?)?.toDouble() ?? kDefaultFullScaleDbSpl,
      globalOffsetDb: (json['globalOffsetDb'] as num?)?.toDouble() ?? 0.0,
      perFrequencyOffsetDb: {
        for (final e in raw.entries)
          int.parse(e.key.toString()): (e.value as num).toDouble(),
      },
      method: method,
      transducerName:
          json['transducerName'] as String? ?? 'Uncalibrated headphones',
      rightEar: _earFromJson(json, 'right'),
      leftEar: _earFromJson(json, 'left'),
    );
  }

  static EarCalibration? _earFromJson(Map<String, dynamic> json, String key) {
    final ears = json['ears'];
    if (ears is! Map) return null;
    final entry = ears[key];
    if (entry is! Map) return null;
    return EarCalibration.fromJson(Map<String, dynamic>.from(entry));
  }

  String encode() => jsonEncode(toJson());

  factory CalibrationProfile.decode(String source) =>
      CalibrationProfile.fromJson(jsonDecode(source) as Map<String, dynamic>);
}
