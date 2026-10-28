import 'audiometry.dart';

/// Degree of hearing loss, classified from the pure-tone average.
///
/// Boundaries follow the Goodman (1965) scale:
///
/// | PTA (dB HL) | Degree              |
/// |-------------|---------------------|
/// | ≤ 25        | Normal              |
/// | 26 - 40     | Mild                |
/// | 41 - 55     | Moderate            |
/// | 56 - 70     | Moderately severe   |
/// | 71 - 90     | Severe              |
/// | > 90        | Profound            |
///
/// Note this classifies *degree*, not *type*. Distinguishing conductive from
/// sensorineural loss requires bone-conduction testing, which this app does not
/// do - see the limitations section of the README.
enum HearingLossDegree {
  normal('Normal'),
  mild('Mild'),
  moderate('Moderate'),
  moderatelySevere('Moderately severe'),
  severe('Severe'),
  profound('Profound');

  const HearingLossDegree(this.label);
  final String label;

  static HearingLossDegree fromPta(double pta) {
    if (pta <= 25) return HearingLossDegree.normal;
    if (pta <= 40) return HearingLossDegree.mild;
    if (pta <= 55) return HearingLossDegree.moderate;
    if (pta <= 70) return HearingLossDegree.moderatelySevere;
    if (pta <= 90) return HearingLossDegree.severe;
    return HearingLossDegree.profound;
  }
}

/// Pure-tone average for one ear, with the classification it implies.
class PureToneAverage {
  const PureToneAverage({
    required this.valueDbHl,
    required this.degree,
    required this.isLowerBound,
    required this.frequenciesUsed,
  });

  /// The averaged threshold across [kPtaFrequenciesHz], in dB HL.
  final double valueDbHl;

  final HearingLossDegree degree;

  /// True when at least one contributing frequency was a "no response" at the
  /// maximum presentable level. The real average is at least [valueDbHl] but
  /// its true value is unknown, so it should be displayed as "≥".
  final bool isLowerBound;

  final List<int> frequenciesUsed;

  String get displayValue =>
      '${isLowerBound ? '≥' : ''}${valueDbHl.toStringAsFixed(0)} dB HL';

  /// Computes the PTA from a frequency→threshold map for a single ear.
  ///
  /// A null value means "no response at maximum level". Such a frequency is
  /// floored at [kMaxLevelDbHl] so the average stays computable, and the result
  /// is flagged with [isLowerBound]. Returns null when no PTA frequency was
  /// tested at all.
  static PureToneAverage? compute(Map<int, int?> thresholdsByFrequency) {
    final used = <int>[];
    var sum = 0;
    var lowerBound = false;

    for (final hz in kPtaFrequenciesHz) {
      if (!thresholdsByFrequency.containsKey(hz)) continue;
      final t = thresholdsByFrequency[hz];
      if (t == null) {
        sum += kMaxLevelDbHl;
        lowerBound = true;
      } else {
        sum += t;
      }
      used.add(hz);
    }

    if (used.isEmpty) return null;

    final avg = sum / used.length;
    return PureToneAverage(
      valueDbHl: avg,
      degree: HearingLossDegree.fromPta(avg),
      isLowerBound: lowerBound,
      frequenciesUsed: used,
    );
  }
}
