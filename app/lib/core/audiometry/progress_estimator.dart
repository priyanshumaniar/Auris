/// Estimates how much longer a test will take.
///
/// "How long is this going to take?" is the single most common thing a patient
/// wants to know, and an audiometric test cannot answer it exactly - the number
/// of presentations per threshold depends on the patient's hearing and how
/// decisively they respond. So this starts from a prior and then learns from
/// the thresholds already completed in this session.
///
/// Pure Dart and clock-injected, so the behaviour can be tested directly.
class TestProgressEstimator {
  TestProgressEstimator({
    required int totalThresholds,
    this.priorPerThreshold = const Duration(seconds: 40),
  })  : assert(totalThresholds > 0),
        _total = totalThresholds;

  int _total;

  /// Measurements planned. Can grow during a test, when a retest or an
  /// interoctave frequency is added.
  int get totalThresholds => _total;
  set totalThresholds(int value) {
    if (value > 0) _total = value;
  }

  /// Starting guess before any threshold has finished.
  ///
  /// A threshold typically needs 9 to 11 presentations, and each presentation
  /// is a randomised gap (1 to 3 s, about 2 s on average) plus a 1 to 2 s tone
  /// plus the response, roughly 4 s, so about 40 s. The first estimate a patient sees is based on this; it is replaced by
  /// measured pace as soon as there is any.
  final Duration priorPerThreshold;

  final List<Duration> _completed = [];

  int get completedCount => _completed.length;
  int get remainingCount => totalThresholds - _completed.length;
  bool get isComplete => remainingCount <= 0;

  /// Fraction of the test finished, 0.0-1.0.
  double get progress => (_completed.length / totalThresholds).clamp(0.0, 1.0);

  /// Records how long one threshold took.
  void recordThreshold(Duration elapsed) {
    if (elapsed < Duration.zero) return;
    _completed.add(elapsed);
  }

  /// Mean time per completed threshold, or [priorPerThreshold] if none yet.
  ///
  /// Weighted towards recent thresholds: a patient who settles into the task
  /// speeds up, and a stale average would keep over-promising.
  Duration get pacePerThreshold {
    if (_completed.isEmpty) return priorPerThreshold;

    // Simple recency weighting - the last three carry the most weight.
    final recent = _completed.length <= 3
        ? _completed
        : _completed.sublist(_completed.length - 3);
    final micros =
        recent.fold<int>(0, (sum, d) => sum + d.inMicroseconds) ~/ recent.length;
    return Duration(microseconds: micros);
  }

  /// Best estimate of the time left.
  Duration get estimatedRemaining {
    if (isComplete) return Duration.zero;
    return pacePerThreshold * remainingCount;
  }

  /// A deliberately coarse, human phrasing of [estimatedRemaining].
  ///
  /// Rounded to avoid implying precision the estimate does not have, and it
  /// never counts down second by second - a visible ticking clock makes a
  /// waiting task feel longer, not shorter.
  String get remainingLabel {
    if (isComplete) return 'Finishing up';

    final seconds = estimatedRemaining.inSeconds;
    if (seconds <= 30) return 'Almost done';
    if (seconds < 90) return 'About a minute left';

    final minutes = (seconds / 60).round();
    if (minutes <= 5) return 'About $minutes minutes left';
    // Round to the nearest 5 minutes beyond that; the estimate is not good
    // enough to justify anything finer.
    final rounded = (minutes / 5).round() * 5;
    return 'About $rounded minutes left';
  }
}
