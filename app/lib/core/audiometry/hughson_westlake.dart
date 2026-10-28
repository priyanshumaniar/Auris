import 'dart:math';

import 'audiometry.dart';

/// Modified Hughson-Westlake threshold search ("down 10, up 5").
///
/// ## The procedure
///
/// This is the threshold-seeking procedure used in clinical manual pure-tone
/// audiometry. It originates with Hughson & Westlake (1944), was modified by
/// Carhart & Jerger (1959), and is specified in:
///
///   * ASHA, *Guidelines for Manual Pure-Tone Threshold Audiometry* (2005)
///   * ISO 8253-1:2010, *Acoustics - Audiometric test methods, Part 1*
///
/// The rules:
///
///  1. Present a tone at a clearly audible level.
///  2. **If the patient responds, drop the level by 10 dB.**
///  3. **If the patient does not respond, raise the level by 5 dB.**
///  4. Repeat. Each time the level is raised after a miss and the patient then
///     responds, that counts as one *ascending* response at that level.
///  5. **Threshold is the lowest level at which the patient responds on at
///     least half of the ascending trials, with at least two responses.** In
///     practice that is 2 of 2, 2 of 3 or 2 of 4 (BSA 2018). 2 of 5 is not
///     enough.
///
/// Two edge cases are handled explicitly, because both used to put a number
/// on the report that the procedure had not earned:
///
///  * **The floor.** No level below [minLevelDbHl] can be presented, so no
///    ascending run can confirm it. A response at the floor is repeated, and
///    the floor is accepted only after two responses there, on at least half
///    of the presentations there. It is then reported as "at or below" the
///    floor ([ThresholdResult.atFloor]), never as a measured threshold.
///  * **The presentation budget.** If the search runs out of presentations
///    before the criterion is met, the result is "not established"
///    ([ThresholdResult.notEstablished]), not a best guess.
///
/// Step 5 is the part most naive implementations get wrong: only *ascending*
/// presentations count. A response on the way down tells you the patient can
/// hear the tone, but not that you have found the quietest level they can hear.
/// The 2-of-3 criterion exists because a single response at a near-threshold
/// level is unreliable - at threshold, detection is probabilistic.
///
/// ## Design
///
/// This class is deliberately free of Flutter, audio and I/O dependencies: it
/// is a pure state machine, so the clinically important logic can be unit
/// tested exhaustively. The caller drives it:
///
/// ```dart
/// final search = HughsonWestlakeSearch();
/// while (!search.isComplete) {
///   final p = search.current;          // what to present now
///   await player.present(p);           // ... play it
///   search.recordResponse(responded: patientPressedButton);
/// }
/// final result = search.result;
/// ```
class HughsonWestlakeSearch {
  HughsonWestlakeSearch({
    this.startLevelDbHl = kStartLevelDbHl,
    this.minLevelDbHl = kMinLevelDbHl,
    this.maxLevelDbHl = kMaxLevelDbHl,
    this.descendStepDb = kDescendStepDb,
    this.ascendStepDb = kAscendStepDb,
    this.requiredAscendingResponses = 2,
    this.maxPresentations = 40,
    this.catchTrialProbability = 0.0,
    Random? random,
  })  : assert(descendStepDb > 0),
        assert(ascendStepDb > 0),
        assert(requiredAscendingResponses >= 1),
        assert(catchTrialProbability >= 0 && catchTrialProbability <= 1),
        _random = random ?? Random(),
        _level = startLevelDbHl {
    _prepareNext(isFirst: true);
  }

  final int startLevelDbHl;
  final int minLevelDbHl;
  final int maxLevelDbHl;
  final int descendStepDb;
  final int ascendStepDb;
  final int requiredAscendingResponses;

  /// Hard stop so a patient responding at random cannot loop forever.
  final int maxPresentations;

  /// Probability that any given trial is a silent *catch trial*.
  ///
  /// A catch trial presents nothing. A patient who "responds" to silence is
  /// guessing, and the false-positive count is a reliability indicator that
  /// belongs on the report. Set to 0 to disable.
  final double catchTrialProbability;

  final Random _random;

  int _level;
  bool _arrivedAscending = false;
  bool _pendingCatchTrial = false;

  final Map<int, int> _ascendingPresentations = {};
  final Map<int, int> _ascendingResponses = {};

  /// Presentations and responses at [minLevelDbHl], in either direction. Used
  /// only for the floor rule.
  int _floorPresentations = 0;
  int _floorResponses = 0;

  /// Responses at [maxLevelDbHl], in either direction. A miss there is a
  /// "no response" only when the patient has never responded there.
  int _maxResponses = 0;
  final List<PresentationRecord> _log = [];

  int _toneCount = 0;
  int _catchTrials = 0;
  int _falsePositives = 0;

  bool _complete = false;
  int? _threshold;
  bool _noResponse = false;
  bool _atFloor = false;
  bool _notEstablished = false;

  // ---------------------------------------------------------------- queries

  /// The presentation the caller should deliver next.
  Presentation get current => Presentation(
        levelDbHl: _level,
        isCatchTrial: _pendingCatchTrial,
        isAscending: _arrivedAscending,
      );

  bool get isComplete => _complete;

  /// Number of real (non-silent) tones presented so far.
  int get toneCount => _toneCount;

  /// Every presentation made, in order - useful for an audit trail.
  List<PresentationRecord> get log => List.unmodifiable(_log);

  /// Ascending-response tally per level. Exposed for tests and diagnostics.
  Map<int, int> get ascendingResponses => Map.unmodifiable(_ascendingResponses);
  Map<int, int> get ascendingPresentations =>
      Map.unmodifiable(_ascendingPresentations);

  ThresholdResult get result {
    if (!_complete) {
      throw StateError('Search is not complete; check isComplete first.');
    }
    return ThresholdResult(
      thresholdDbHl: _threshold,
      noResponse: _noResponse,
      atFloor: _atFloor,
      notEstablished: _notEstablished,
      tonesPresented: _toneCount,
      catchTrials: _catchTrials,
      falsePositives: _falsePositives,
      log: List.unmodifiable(_log),
    );
  }

  // ----------------------------------------------------------------- driver

  /// Record the patient's answer to [current] and advance the state machine.
  void recordResponse({required bool responded}) {
    if (_complete) {
      throw StateError('Search already complete.');
    }

    _log.add(PresentationRecord(
      levelDbHl: _level,
      isCatchTrial: _pendingCatchTrial,
      isAscending: _arrivedAscending,
      responded: responded,
    ));

    // A catch trial is silent: it scores reliability but does not move the
    // search, because no stimulus was delivered.
    if (_pendingCatchTrial) {
      _catchTrials++;
      if (responded) _falsePositives++;
      _pendingCatchTrial = false;
      return;
    }

    _toneCount++;

    if (_arrivedAscending) {
      _ascendingPresentations[_level] = (_ascendingPresentations[_level] ?? 0) + 1;
      if (responded) {
        _ascendingResponses[_level] = (_ascendingResponses[_level] ?? 0) + 1;
      }
    }

    if (_level == minLevelDbHl) {
      _floorPresentations++;
      if (responded) _floorResponses++;
    }
    if (_level == maxLevelDbHl && responded) _maxResponses++;

    // Stop as soon as any level satisfies the ascending criterion. The first
    // level to reach it is the lowest reliably heard level: the search only
    // reaches a lower level by first responding at a higher one, and a level
    // that fails the criterion is left behind on the way up.
    final settled = _lowestLevelMeetingCriterion();
    if (settled != null) {
      _finish(threshold: settled);
      return;
    }

    // The floor cannot be approached from below, so it has its own rule: two
    // responses there, on at least half of the presentations there.
    if (_floorResponses >= requiredAscendingResponses &&
        _floorResponses * 2 >= _floorPresentations) {
      _finish(threshold: minLevelDbHl, atFloor: true);
      return;
    }

    if (_toneCount >= maxPresentations) {
      // Out of budget before the criterion was met. Reporting the lowest
      // level that got any response would be a guess presented as a
      // threshold, so the result is "not established" instead.
      _finish(threshold: null, notEstablished: true);
      return;
    }

    if (responded) {
      if (_level == minLevelDbHl) {
        // Heard at the floor once: present the floor again rather than
        // stopping, so a single response cannot set the threshold.
        _arrivedAscending = false;
      } else {
        _level = max(_level - descendStepDb, minLevelDbHl);
        _arrivedAscending = false;
      }
    } else {
      if (_level + ascendStepDb > maxLevelDbHl) {
        if (_maxResponses == 0) {
          // No response at the loudest level that can be presented.
          _finish(threshold: null, noResponse: true);
          return;
        }
        // Heard here before, so not a no-response: go down and ascend again.
        // Running out of presentations then gives "not established".
        _level = max(_level - descendStepDb, minLevelDbHl);
        _arrivedAscending = false;
      } else {
        _level += ascendStepDb;
        _arrivedAscending = true;
      }
    }

    _prepareNext();
  }

  // ---------------------------------------------------------------- helpers

  void _prepareNext({bool isFirst = false}) {
    // The very first presentation is never a catch trial - the patient needs a
    // real tone to calibrate their own response criterion against.
    _pendingCatchTrial =
        !isFirst && catchTrialProbability > 0 && _random.nextDouble() < catchTrialProbability;
  }

  /// The lowest level with at least [requiredAscendingResponses] ascending
  /// responses on at least half of its ascending presentations.
  int? _lowestLevelMeetingCriterion() {
    int? lowest;
    _ascendingResponses.forEach((level, hits) {
      final tries = _ascendingPresentations[level] ?? 0;
      final meets = hits >= requiredAscendingResponses && hits * 2 >= tries;
      if (meets && (lowest == null || level < lowest!)) lowest = level;
    });
    return lowest;
  }

  void _finish({
    int? threshold,
    bool noResponse = false,
    bool atFloor = false,
    bool notEstablished = false,
  }) {
    _threshold = threshold;
    _noResponse = noResponse;
    _atFloor = atFloor;
    _notEstablished = notEstablished;
    _complete = true;
    _pendingCatchTrial = false;
  }
}

/// A single stimulus the caller should deliver.
class Presentation {
  const Presentation({
    required this.levelDbHl,
    required this.isCatchTrial,
    required this.isAscending,
  });

  final int levelDbHl;

  /// When true, present *silence* for the usual tone duration.
  final bool isCatchTrial;

  /// True when this level was reached by stepping up after a miss.
  final bool isAscending;
}

/// A presentation plus the answer it received.
class PresentationRecord {
  const PresentationRecord({
    required this.levelDbHl,
    required this.isCatchTrial,
    required this.isAscending,
    required this.responded,
  });

  final int levelDbHl;
  final bool isCatchTrial;
  final bool isAscending;
  final bool responded;

  @override
  String toString() => '${isCatchTrial ? 'catch' : '$levelDbHl dB'}'
      '${isAscending ? ' ↑' : ''} → ${responded ? 'responded' : 'no response'}';
}

/// The outcome of a threshold search at one frequency in one ear.
class ThresholdResult {
  const ThresholdResult({
    required this.thresholdDbHl,
    required this.noResponse,
    this.atFloor = false,
    this.notEstablished = false,
    required this.tonesPresented,
    required this.catchTrials,
    required this.falsePositives,
    required this.log,
  });

  /// The established threshold in dB HL. Null for a no-response and for a
  /// threshold that was not established.
  final int? thresholdDbHl;

  /// True when no response was obtained at the loudest level presented
  /// ([kMaxLevelDbHl], or lower where the headphones cannot reach it). On an
  /// audiogram this is plotted as a "no response" arrow, not as a threshold.
  final bool noResponse;

  /// True when the patient responded reliably at the quietest level the app
  /// can present. The true threshold is at or below [thresholdDbHl].
  final bool atFloor;

  /// True when the search ran out of presentations before the criterion was
  /// met. [thresholdDbHl] is null and the frequency should be retested.
  final bool notEstablished;

  final int tonesPresented;
  final int catchTrials;

  /// Responses to silent catch trials. A high count means the patient was
  /// guessing and the whole test should be treated as unreliable.
  final int falsePositives;

  final List<PresentationRecord> log;

  /// At most a quarter of the catch trials answered.
  bool get isReliable => catchTrials == 0 || falsePositives / catchTrials <= 0.25;
}
