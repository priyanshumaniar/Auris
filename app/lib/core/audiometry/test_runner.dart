import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../data/models/test_protocol.dart';
import '../../data/models/test_session.dart';
import 'audiometry.dart';
import 'hughson_westlake.dart';

/// Delivers one stimulus and completes when it has finished playing. Injected
/// so the sequencing can be tested without audio hardware.
typedef PresentStimulus = Future<void> Function({
  required int frequencyHz,
  required num levelDbHl,
  required Ear ear,
  required bool silent,
  required Duration duration,
});

/// The loudest level that can be presented at [frequencyHz] in [ear]: the
/// output limit of the headphones under the current calibration, capped at
/// [kMaxLevelDbHl].
typedef MaxLevelFor = int Function(Ear ear, int frequencyHz);

enum TestPhase {
  /// Not started.
  idle,

  /// Practice tones at 1000 Hz before any threshold is measured. Not scored.
  familiarising,

  /// Familiarisation responses did not match the tone twice. The runner waits
  /// here until [AudiometryTestRunner.continueAfterReinstruction] is called.
  reinstruct,

  /// A tone is sounding.
  presenting,

  /// Tone finished; the response window is open.
  awaitingResponse,

  /// Randomised gap before the next stimulus.
  interStimulus,

  /// One ear is finished and the next has not started. The runner waits here
  /// until [AudiometryTestRunner.continueToNextEar] is called, giving the
  /// patient a break and a chance to reseat the headphones.
  earChangeover,

  /// The test has run for [AudiometryTestRunner.breakAfter]. The runner waits
  /// here until [AudiometryTestRunner.continueAfterBreak] is called.
  breakOffered,

  paused,
  complete,
  aborted,
}

/// One planned measurement in one ear.
class _Step {
  const _Step(this.frequencyHz, {this.isRetest = false});

  final int frequencyHz;
  final bool isRetest;
}

/// Runs a full pure-tone test, following ASHA (2005) and BSA (2018).
///
///  * Familiarisation at 1000 Hz before the first ear (BSA 6.6).
///  * Each ear in the order given; the caller puts the better ear first.
///  * Frequencies in [frequencies] order, with 1000 Hz retested in the first
///    ear after the high frequencies. If the retest differs by more than
///    [kRetestToleranceDb], 2000 Hz is retested too and the second ear also
///    gets a 1000 Hz retest.
///  * Interoctave frequencies (750, 1500 Hz) added when adjacent octaves
///    differ by [kInteroctaveDifferenceDb] or more.
///  * Each new frequency starts about [kStartAboveAdjacentDb] above the
///    nearest threshold already measured in that ear (BSA 6.7).
///  * Tone length varies between [minToneMs] and [maxToneMs]; the gap between
///    tones varies between [minInterStimulusGap] and [maxInterStimulusGap] and
///    is never shorter than the next tone (ASHA).
///  * A break is offered after [breakAfter] of testing (BSA 6.8).
///
/// The runner owns sequencing and timing; the clinical decision rule lives in
/// [HughsonWestlakeSearch]. Keeping them apart is what lets the threshold logic
/// be tested exhaustively without simulating a UI.
class AudiometryTestRunner extends ChangeNotifier {
  AudiometryTestRunner({
    required PresentStimulus present,
    PresentStimulus? prepare,
    MaxLevelFor? maxLevelFor,
    this.ears = const [Ear.right, Ear.left],
    this.frequencies = kTestOrderHz,
    this.responseWindow = const Duration(milliseconds: 1500),
    this.minInterStimulusGap = const Duration(milliseconds: 1000),
    this.maxInterStimulusGap = const Duration(milliseconds: 3000),
    this.minToneMs = kMinToneMs,
    this.maxToneMs = kMaxToneMs,
    this.toneStepMs = kToneStepMs,
    this.catchTrialProbability = 0.1,
    this.startLevelDbHl = kStartLevelDbHl,
    this.pauseBetweenEars = true,
    this.familiarise = true,
    this.retestFirstEar = true,
    this.addInteroctave = true,
    this.breakAfter = kBreakAfter,
    this.releaseWait = const Duration(milliseconds: 1500),
    Random? random,
  }) : assert(minToneMs > 0 && maxToneMs >= minToneMs),
       assert(toneStepMs > 0),
       _present = present,
       _prepare = prepare,
       _maxLevelFor = maxLevelFor,
       _random = random ?? Random();

  final PresentStimulus _present;

  /// Gets the next stimulus ready (for example, writes its audio file) while
  /// the gap before it runs, so the tone starts the moment the gap ends and
  /// the response window lines up with what the patient hears.
  final PresentStimulus? _prepare;

  final MaxLevelFor? _maxLevelFor;

  /// Ears in test order. Put the better ear first.
  final List<Ear> ears;

  /// Base frequency order for every ear. The 1000 Hz retest and interoctave
  /// frequencies are added by the runner.
  final List<int> frequencies;

  /// How long after the tone ends a press still counts as a response.
  ///
  /// Neither ASHA (2005) nor BSA (2018) gives a number. 1.5 s is this app's
  /// own choice: long enough for a slow response to a faint tone, short enough
  /// that a missed tone does not leave a long silence.
  final Duration responseWindow;

  /// Bounds of the randomised gap between stimuli.
  ///
  /// The gap is randomised on purpose. A patient who can predict when the next
  /// tone arrives starts pressing to the rhythm rather than to what they hear,
  /// which pushes every threshold artificially low. BSA (2018) asks for 1 s to
  /// at least 3 s, varied unpredictably.
  final Duration minInterStimulusGap;
  final Duration maxInterStimulusGap;

  /// Bounds of the tone length, in milliseconds, drawn in [toneStepMs] steps.
  final int minToneMs;
  final int maxToneMs;
  final int toneStepMs;

  final double catchTrialProbability;

  /// Starting level used when no threshold has been measured yet in an ear.
  final int startLevelDbHl;

  /// Whether to stop between ears and wait for [continueToNextEar].
  final bool pauseBetweenEars;

  /// Whether to run the familiarisation step before the first ear.
  final bool familiarise;

  /// Whether to retest 1000 Hz in the first ear.
  final bool retestFirstEar;

  /// Whether to add 750 and 1500 Hz when the interoctave rule calls for them.
  final bool addInteroctave;

  /// Offer a break after this much testing. Null never offers one.
  final Duration? breakAfter;

  /// During familiarisation, how long after the tone ends to wait for the
  /// patient to let go of the button.
  final Duration releaseWait;

  final Random _random;

  // ------------------------------------------------------------------ state

  TestPhase _phase = TestPhase.idle;

  /// The phase to return to when a pause ends.
  TestPhase _phaseBeforePause = TestPhase.idle;

  Ear? _currentEar;
  int? _currentFrequencyHz;
  int? _currentLevelDbHl;
  bool _currentIsRetest = false;

  final Map<Ear, Map<int, ThresholdPoint>> _results = {};
  final Map<Ear, List<_Step>> _plans = {};
  final List<ThresholdPoint> _orderedPoints = [];
  int _completedSteps = 0;

  // Response handling.
  Completer<bool>? _response;
  bool _pressed = false;
  Duration? _pressAt;
  Duration? _releaseAt;
  Completer<void>? _releaseSignal;
  bool _countGapPresses = false;
  final Map<Ear, int> _pressesBetweenTones = {};

  // Gates.
  Completer<void>? _resume;
  Completer<void>? _earGate;
  Completer<void>? _reinstructGate;
  Completer<void>? _breakGate;
  bool _aborted = false;
  bool _skipRequested = false;

  /// True only while a frequency is being measured: the only time it can be
  /// skipped.
  bool _measuring = false;

  /// True from the start of a tone until its response window closes.
  bool _toneActive = false;

  /// Set when the test was paused while a tone was sounding or its response
  /// window was open. That trial is thrown away and the same stimulus is
  /// presented again after the pause: the patient may not have heard it
  /// out, and a miss recorded for it would be wrong.
  bool _trialInterrupted = false;

  // Clocks.
  final Stopwatch _clock = Stopwatch();
  final Stopwatch _sinceBreak = Stopwatch();
  final Stopwatch _thresholdTimer = Stopwatch();
  Duration? _firstToneAt;
  Duration? _lastToneEndAt;

  // Protocol record.
  FamiliarisationOutcome? _familiarisation;
  final List<RetestRecord> _retests = [];
  final List<FrequencyRef> _interoctaveAdded = [];
  final List<FrequencyRef> _skipped = [];
  final List<OutputLimit> _outputLimits = [];
  int _breaksOffered = 0;
  bool _firstEarRetestFailed = false;

  /// The ear just finished, while sitting in [TestPhase.earChangeover].
  Ear? _finishedEar;
  Ear? get finishedEar => _finishedEar;

  /// Duration of each completed measurement, in order. Drives the time
  /// estimate.
  final List<Duration> _thresholdDurations = [];
  List<Duration> get thresholdDurations =>
      List.unmodifiable(_thresholdDurations);

  TestPhase get phase => _phase;
  Ear? get currentEar => _currentEar;
  int? get currentFrequencyHz => _currentFrequencyHz;

  /// True while 1000 Hz (or 2000 Hz) is being measured a second time.
  bool get currentIsRetest => _currentIsRetest;

  /// The level being presented. Shown to the clinician, never to the patient.
  /// A patient who can see the dial responds to the number, not the tone.
  int? get currentLevelDbHl => _currentLevelDbHl;

  /// One point per ear and frequency, in the order they were finished. A
  /// retest updates the existing point rather than adding a second one.
  List<ThresholdPoint> get points => List.unmodifiable(_orderedPoints);

  /// Unique frequencies planned for [ear] so far, in test order.
  List<int> frequenciesFor(Ear ear) {
    final plan = _plans[ear] ?? _basePlan(ear);
    final seen = <int>{};
    return [
      for (final step in plan)
        if (seen.add(step.frequencyHz)) step.frequencyHz,
    ];
  }

  /// Frequencies finished in [ear].
  Set<int> completedFrequenciesFor(Ear ear) =>
      (_results[ear] ?? const <int, ThresholdPoint>{}).keys.toSet()
        ..addAll(_skipped.where((s) => s.ear == ear).map((s) => s.frequencyHz));

  /// Measurements planned in total. It grows when a retest or an interoctave
  /// frequency is added.
  int get totalSteps =>
      ears.fold(0, (sum, ear) => sum + (_plans[ear] ?? _basePlan(ear)).length);

  int get completedSteps => _completedSteps;
  double get progress =>
      totalSteps == 0 ? 0 : (_completedSteps / totalSteps).clamp(0.0, 1.0);

  bool get isRunning =>
      _phase != TestPhase.idle &&
      _phase != TestPhase.complete &&
      _phase != TestPhase.aborted;

  /// Everything about how the test ran, for the session record. The caller
  /// adds what the runner cannot know (reason, checklist, transducer).
  TestProtocolRecord get protocolRecord => TestProtocolRecord(
    earOrder: List.unmodifiable(ears),
    familiarisation: _familiarisation,
    retests: List.unmodifiable(_retests),
    interoctaveAdded: List.unmodifiable(_interoctaveAdded),
    skipped: List.unmodifiable(_skipped),
    breaksOffered: _breaksOffered,
    pressesBetweenTones: Map.unmodifiable(_pressesBetweenTones),
    testDuration: _firstToneAt == null || _lastToneEndAt == null
        ? null
        : _lastToneEndAt! - _firstToneAt!,
    minToneMs: minToneMs,
    maxToneMs: maxToneMs,
    minGapMs: minInterStimulusGap.inMilliseconds,
    maxGapMs: maxInterStimulusGap.inMilliseconds,
    catchTrialsUsed: catchTrialProbability > 0,
    outputLimits: List.unmodifiable(_outputLimits),
  );

  // ---------------------------------------------------------------- control

  /// Runs the whole sequence. Completes when the test finishes or is aborted.
  Future<List<ThresholdPoint>> run() async {
    if (_phase != TestPhase.idle) {
      throw StateError('This runner has already been used.');
    }
    _clock.start();
    _sinceBreak.start();

    int? familiarLevel;
    if (familiarise && ears.isNotEmpty) {
      familiarLevel = await _familiarise(ears.first);
    }

    for (var earIndex = 0; earIndex < ears.length && !_aborted; earIndex++) {
      final ear = ears[earIndex];

      if (earIndex > 0 && pauseBetweenEars) {
        _finishedEar = ears[earIndex - 1];
        await _waitAtGate(TestPhase.earChangeover, (gate) => _earGate = gate);
        _earGate = null;
        _finishedEar = null;
        if (_aborted) break;
      }

      final plan = _plans[ear] = _basePlan(ear);
      _currentEar = ear;
      _notify();

      for (var i = 0; i < plan.length && !_aborted; i++) {
        await _offerBreakIfDue();
        if (_aborted) break;

        final step = plan[i];
        final useFamiliarLevel =
            earIndex == 0 && i == 0 && familiarLevel != null;
        await _runStep(
          ear,
          step,
          startLevel: useFamiliarLevel
              ? familiarLevel
              : _startLevelFor(ear, step.frequencyHz),
        );
        if (_aborted) break;

        // Interoctave frequencies are judged once the base plan is done, so
        // both octaves of each pair are known.
        if (i == plan.length - 1 && addInteroctave) {
          final measured = _thresholdMap(ear);
          for (final hz in interoctaveFrequenciesNeeded(measured)) {
            if (plan.any((s) => s.frequencyHz == hz)) continue;
            plan.add(_Step(hz));
            _interoctaveAdded.add(FrequencyRef(ear, hz));
          }
          _notify();
        }
      }
    }

    _clock.stop();
    _setPhase(_aborted ? TestPhase.aborted : TestPhase.complete);
    return points;
  }

  /// The patient pressed the button.
  ///
  /// A press while a response window is open is a response. A press while a
  /// test tone could not have been heard (the gap between tones) is counted
  /// as a press between tones, which is reported as a reliability measure.
  void press() {
    if (_pressed) return;
    _pressed = true;
    _pressAt = _clock.elapsed;
    _releaseAt = null;

    final pending = _response;
    if (pending != null && !pending.isCompleted) {
      pending.complete(true);
    } else if (_countGapPresses &&
        _phase == TestPhase.interStimulus &&
        _currentEar != null) {
      final ear = _currentEar!;
      _pressesBetweenTones[ear] = (_pressesBetweenTones[ear] ?? 0) + 1;
    }
  }

  /// The patient let go of the button.
  void release() {
    if (!_pressed) return;
    _pressed = false;
    _releaseAt = _clock.elapsed;
    final signal = _releaseSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  /// A press followed at once by a release, for a tap or a keyboard key.
  void respond() {
    press();
    release();
  }

  /// Leaves [TestPhase.earChangeover] and begins the next ear.
  void continueToNextEar() => _open(_earGate);

  /// Leaves [TestPhase.reinstruct] after the clinician has repeated the
  /// instructions.
  void continueAfterReinstruction() => _open(_reinstructGate);

  /// Leaves [TestPhase.breakOffered].
  void continueAfterBreak() => _open(_breakGate);

  /// Ends the current frequency without a threshold. It is recorded as
  /// skipped, and the report lists it (BSA 2018 6.8).
  void skipCurrentFrequency() {
    // Familiarisation, a break or the change of ears has no frequency to
    // skip, and a request there would be silently dropped or misapplied.
    if (!isRunning || !_measuring || _currentFrequencyHz == null) return;
    _skipRequested = true;
    final pending = _response;
    if (pending != null && !pending.isCompleted) pending.complete(false);
  }

  void pause() {
    if (!isRunning || _phase == TestPhase.paused) return;
    if (_toneActive) _trialInterrupted = true;
    _resume = Completer<void>();
    _phaseBeforePause = _phase;
    _setPhase(TestPhase.paused);
  }

  void resume() {
    final waiter = _resume;
    _resume = null;
    if (waiter != null && !waiter.isCompleted) {
      if (_phase == TestPhase.paused) _setPhase(_phaseBeforePause);
      waiter.complete();
    }
  }

  void abort() {
    _aborted = true;
    resume();
    _open(_earGate);
    _open(_reinstructGate);
    _open(_breakGate);
    final pending = _response;
    if (pending != null && !pending.isCompleted) pending.complete(false);
    final signal = _releaseSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  @override
  void dispose() {
    abort();
    super.dispose();
  }

  // ------------------------------------------------------------- the steps

  /// The steps for [ear] before any are added during the test.
  List<_Step> _basePlan(Ear ear) {
    final steps = [for (final hz in frequencies) _Step(hz)];
    final isFirstEar = ears.isNotEmpty && ears.first == ear;
    final wantsRetest = isFirstEar ? retestFirstEar : _firstEarRetestFailed;
    if (wantsRetest && frequencies.contains(1000)) {
      // After the high frequencies, before the low ones. When the order has
      // no low frequencies, at the end.
      final lowIndex = steps.indexWhere(
        (s) => s.frequencyHz < 1000 && steps.indexOf(s) > 0,
      );
      steps.insert(
        lowIndex < 0 ? steps.length : lowIndex,
        const _Step(1000, isRetest: true),
      );
    }
    return steps;
  }

  /// BSA (2018): start about 30 dB above the nearest threshold already
  /// measured in this ear. Before any threshold exists, [startLevelDbHl].
  int _startLevelFor(Ear ear, int hz) {
    final measured =
        _results[ear]?.values.where(
          (p) =>
              !p.noResponse && !p.isNotEstablished && p.thresholdDbHl != null,
        ) ??
        const <ThresholdPoint>[];
    if (measured.isEmpty) return startLevelDbHl;

    ThresholdPoint? nearest;
    var bestDistance = double.infinity;
    for (final p in measured) {
      final distance = (log(p.frequencyHz / hz) / ln2).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        nearest = p;
      }
    }
    return (nearest!.thresholdDbHl! + kStartAboveAdjacentDb).clamp(
      kMinStartLevelDbHl,
      kMaxStartLevelDbHl,
    );
  }

  Map<int, int?> _thresholdMap(Ear ear) => {
    for (final p in (_results[ear] ?? const <int, ThresholdPoint>{}).values)
      if (!p.isNotEstablished)
        p.frequencyHz: p.noResponse ? null : p.thresholdDbHl,
  };

  Future<void> _runStep(Ear ear, _Step step, {required int startLevel}) async {
    _currentEar = ear;
    _currentFrequencyHz = step.frequencyHz;
    _currentIsRetest = step.isRetest;
    _skipRequested = false;
    _measuring = true;
    _notify();

    _thresholdTimer
      ..reset()
      ..start();
    final ThresholdResult? result;
    try {
      result = await _measure(ear, step.frequencyHz, startLevel);
    } finally {
      _measuring = false;
    }
    _thresholdTimer.stop();
    if (_aborted) return;
    _thresholdDurations.add(_thresholdTimer.elapsed);
    _completedSteps++;

    if (result == null) {
      // Skipped. A skipped retest leaves the first measurement in place.
      if (!step.isRetest) _skipped.add(FrequencyRef(ear, step.frequencyHz));
      _notify();
      return;
    }

    final point = _pointFrom(ear, step.frequencyHz, result);
    final earResults = _results.putIfAbsent(ear, () => {});
    final first = earResults[step.frequencyHz];

    // A retest of a frequency skipped the first time is its only measurement:
    // it is no longer skipped.
    if (step.isRetest && first == null) {
      _skipped.remove(FrequencyRef(ear, step.frequencyHz));
    }

    if (step.isRetest && first != null) {
      final merged = _mergeRetest(ear, first, point);
      earResults[step.frequencyHz] = merged;
      final index = _orderedPoints.indexOf(first);
      if (index >= 0) _orderedPoints[index] = merged;
    } else {
      earResults[step.frequencyHz] = point;
      _orderedPoints.add(point);
    }
    _notify();
  }

  ThresholdPoint _pointFrom(Ear ear, int hz, ThresholdResult r) =>
      ThresholdPoint(
        ear: ear,
        frequencyHz: hz,
        thresholdDbHl: r.thresholdDbHl,
        noResponse: r.noResponse,
        tonesPresented: r.tonesPresented,
        catchTrials: r.catchTrials,
        falsePositives: r.falsePositives,
        qualifier: r.notEstablished
            ? ThresholdQualifier.notEstablished
            : r.atFloor
            ? ThresholdQualifier.atFloor
            : ThresholdQualifier.measured,
      );

  /// Compares a retest with the first measurement and keeps one point.
  ///
  /// Within [kRetestToleranceDb] the more sensitive (lower) value is used
  /// (BSA 2018). Outside it ASHA (2005) allows the lower value to be accepted,
  /// asks for at least one other frequency to be retested, and the result is
  /// flagged on the report.
  ThresholdPoint _mergeRetest(
    Ear ear,
    ThresholdPoint first,
    ThresholdPoint retest,
  ) {
    int? value(ThresholdPoint p) =>
        p.noResponse || p.isNotEstablished ? null : p.thresholdDbHl;

    final a = value(first);
    final b = value(retest);
    final bothNoResponse = first.noResponse && retest.noResponse;
    final within =
        bothNoResponse ||
        (a != null && b != null && (a - b).abs() <= kRetestToleranceDb);

    _retests.add(
      RetestRecord(
        ear: ear,
        frequencyHz: first.frequencyHz,
        firstDbHl: a,
        retestDbHl: b,
        withinTolerance: within,
      ),
    );

    if (!within) {
      if (ear == ears.first) _firstEarRetestFailed = true;
      // ASHA: retest at least one other frequency. 2000 Hz, once per ear.
      final plan = _plans[ear];
      final alreadyPlanned =
          plan?.any((s) => s.isRetest && s.frequencyHz == 2000) ?? true;
      if (first.frequencyHz == 1000 &&
          !alreadyPlanned &&
          (_results[ear]?.containsKey(2000) ?? false)) {
        final index = _currentStepIndex(ear);
        plan!.insert(index + 1, const _Step(2000, isRetest: true));
      }
    }

    // Keep the better of the two usable results.
    final ThresholdPoint kept;
    if (a != null && b != null) {
      kept = b < a ? retest : first;
    } else if (a == null && b != null) {
      kept = retest;
    } else {
      kept = first;
    }
    return ThresholdPoint(
      ear: ear,
      frequencyHz: first.frequencyHz,
      thresholdDbHl: kept.thresholdDbHl,
      noResponse: kept.noResponse,
      qualifier: kept.qualifier,
      tonesPresented: first.tonesPresented + retest.tonesPresented,
      catchTrials: first.catchTrials + retest.catchTrials,
      falsePositives: first.falsePositives + retest.falsePositives,
    );
  }

  int _currentStepIndex(Ear ear) {
    final plan = _plans[ear]!;
    for (var i = 0; i < plan.length; i++) {
      if (plan[i].isRetest && plan[i].frequencyHz == _currentFrequencyHz) {
        return i;
      }
    }
    return plan.length - 1;
  }

  /// Runs one threshold search. Returns null when it was skipped or aborted.
  Future<ThresholdResult?> _measure(Ear ear, int frequencyHz, int start) async {
    final ceiling = _ceiling(ear, frequencyHz);
    final search = HughsonWestlakeSearch(
      startLevelDbHl: start.clamp(kMinLevelDbHl, ceiling),
      maxLevelDbHl: ceiling,
      catchTrialProbability: catchTrialProbability,
      random: _random,
    );

    _countGapPresses = true;
    try {
      while (!search.isComplete && !_aborted && !_skipRequested) {
        final stimulus = search.current;
        _currentLevelDbHl = stimulus.levelDbHl;

        final responded = await _trial(
          ear: ear,
          frequencyHz: frequencyHz,
          levelDbHl: stimulus.levelDbHl,
          silent: stimulus.isCatchTrial,
        );
        if (responded == null) {
          if (_takeInterrupted()) continue; // present it again
          break;
        }
        search.recordResponse(responded: responded);
      }
    } finally {
      _countGapPresses = false;
    }

    if (_aborted || _skipRequested || !search.isComplete) return null;
    return search.result;
  }

  /// The loudest level for [hz] in [ear], recorded when it is below
  /// [kMaxLevelDbHl] so the report can say what a "no response" means there.
  int _ceiling(Ear ear, int hz) {
    final limit = _maxLevelFor?.call(ear, hz) ?? kMaxLevelDbHl;
    final ceiling = limit.clamp(kMinLevelDbHl, kMaxLevelDbHl);
    if (ceiling < kMaxLevelDbHl &&
        !_outputLimits.any((l) => l.ear == ear && l.frequencyHz == hz)) {
      _outputLimits.add(OutputLimit(ear, hz, ceiling));
    }
    return ceiling;
  }

  /// One gap, one stimulus and its response window. Returns whether the
  /// patient responded, or null when the trial was cut short.
  Future<bool?> _trial({
    required Ear ear,
    required int frequencyHz,
    required int levelDbHl,
    required bool silent,
  }) async {
    await _waitWhilePaused();
    if (_aborted || _skipRequested) return null;

    _trialInterrupted = false;
    final duration = _randomToneDuration();
    _setPhase(TestPhase.interStimulus);
    await _gapWhilePreparing(
      frequencyHz: frequencyHz,
      levelDbHl: levelDbHl,
      ear: ear,
      silent: silent,
      duration: duration,
    );
    await _waitWhilePaused();
    if (_aborted || _skipRequested) return null;

    // Arm the response gate as the tone starts, so a patient who responds
    // while it is still playing is recorded correctly. The tone was prepared
    // during the gap, so it sounds without a noticeable delay.
    final gate = Completer<bool>();
    _response = gate;

    _setPhase(TestPhase.presenting);
    _firstToneAt ??= _clock.elapsed;
    _toneActive = true;
    final bool responded;
    try {
      await _present(
        frequencyHz: frequencyHz,
        levelDbHl: levelDbHl,
        ear: ear,
        silent: silent,
        duration: duration,
      );
      _lastToneEndAt = _clock.elapsed;

      if (!gate.isCompleted) _setPhase(TestPhase.awaitingResponse);
      responded = await gate.future
          .timeout(responseWindow, onTimeout: () => false)
          .whenComplete(() => _response = null);
    } finally {
      _toneActive = false;
    }

    if (_aborted || _skipRequested || _trialInterrupted) return null;
    return responded;
  }

  // -------------------------------------------------------- familiarisation

  /// BSA (2018) 6.6. Returns the level the patient responded at, or null when
  /// they did not respond at any level tried.
  Future<int?> _familiarise(Ear ear) async {
    _currentEar = ear;
    _currentFrequencyHz = 1000;
    _setPhase(TestPhase.familiarising);

    final ceiling = _ceiling(ear, 1000);
    var level = min(kFamiliarisationLevelDbHl, ceiling);
    var mismatches = 0;
    var reinstructed = false;

    while (!_aborted) {
      _currentLevelDbHl = level;
      final attempt = await _familiarisationTrial(ear, level);
      if (!_aborted && attempt == null && _takeInterrupted()) continue;
      if (_aborted || attempt == null) return null;

      if (!attempt.heard) {
        if (level >= ceiling) {
          _familiarisation = FamiliarisationOutcome(
            heard: false,
            levelDbHl: level,
            onsetOffsetMatched: false,
            reinstructed: reinstructed,
          );
          return null;
        }
        // 10 dB steps up to 80 dB HL, then 5 dB steps to the loudest level
        // that can be presented (BSA 6.6).
        level = min(
          level < kFamiliarisationMaxDbHl ? level + 10 : level + 5,
          ceiling,
        );
        continue;
      }

      if (attempt.matched || reinstructed) {
        _familiarisation = FamiliarisationOutcome(
          heard: true,
          levelDbHl: level,
          onsetOffsetMatched: attempt.matched,
          reinstructed: reinstructed,
        );
        return level;
      }

      mismatches++;
      if (mismatches >= 2) {
        // Repeated once already: re-instruct, then one last try.
        await _waitAtGate(
          TestPhase.reinstruct,
          (gate) => _reinstructGate = gate,
        );
        _reinstructGate = null;
        reinstructed = true;
        if (_aborted) return null;
        _setPhase(TestPhase.familiarising);
      }
    }
    return null;
  }

  /// Whether the last trial was cut short by a pause, clearing the flag.
  bool _takeInterrupted() {
    final interrupted = _trialInterrupted && !_aborted && !_skipRequested;
    _trialInterrupted = false;
    return interrupted;
  }

  /// One familiarisation tone. Null when cut short.
  Future<({bool heard, bool matched})?> _familiarisationTrial(
    Ear ear,
    int level,
  ) async {
    await _waitWhilePaused();
    if (_aborted) return null;
    _trialInterrupted = false;

    final duration = _randomToneDuration();
    await _gapWhilePreparing(
      frequencyHz: 1000,
      levelDbHl: level,
      ear: ear,
      silent: false,
      duration: duration,
    );
    await _waitWhilePaused();
    if (_aborted) return null;

    final gate = Completer<bool>();
    _response = gate;
    final releaseSignal = Completer<void>();
    _releaseSignal = releaseSignal;

    final toneStart = _clock.elapsed;
    _toneActive = true;
    final Duration toneEnd;
    final bool heard;
    try {
      await _present(
        frequencyHz: 1000,
        levelDbHl: level,
        ear: ear,
        silent: false,
        duration: duration,
      );
      toneEnd = _clock.elapsed;

      heard = await gate.future
          .timeout(responseWindow, onTimeout: () => false)
          .whenComplete(() => _response = null);
    } finally {
      _toneActive = false;
    }
    if (_aborted) return null;
    if (_trialInterrupted) {
      _releaseSignal = null;
      return null;
    }
    if (!heard) {
      _releaseSignal = null;
      return (heard: false, matched: false);
    }

    // Wait for the release, unless it already happened.
    if (_pressed) {
      final waitUntil = toneEnd + releaseWait;
      final remaining = waitUntil - _clock.elapsed;
      if (remaining > Duration.zero) {
        await releaseSignal.future.timeout(remaining, onTimeout: () {});
      }
    }
    _releaseSignal = null;
    if (_aborted) return null;

    final pressAt = _pressAt;
    final releaseAt = _releaseAt;
    // Pressed while the tone played (or just after its start), and let go no
    // earlier than 250 ms before it stopped and no later than [releaseWait]
    // after. The 250 ms allows for audio output latency; it is this app's own
    // value, not a published one.
    final matched =
        pressAt != null &&
        pressAt >= toneStart &&
        releaseAt != null &&
        releaseAt >= toneEnd - const Duration(milliseconds: 250) &&
        releaseAt <= toneEnd + releaseWait;
    return (heard: true, matched: matched);
  }

  // ------------------------------------------------------------------ gates

  Future<void> _offerBreakIfDue() async {
    final limit = breakAfter;
    if (limit == null || _sinceBreak.elapsed < limit) return;
    _breaksOffered++;
    await _waitAtGate(TestPhase.breakOffered, (gate) => _breakGate = gate);
    _breakGate = null;
    _sinceBreak
      ..reset()
      ..start();
  }

  /// Enters [phase] and waits until the gate is opened (or the test aborted).
  Future<void> _waitAtGate(
    TestPhase phase,
    void Function(Completer<void>) register,
  ) async {
    if (_aborted) return;
    // Hold the completer locally: _setPhase notifies listeners synchronously,
    // so a listener may open the gate before this method continues.
    final gate = Completer<void>();
    register(gate);
    _setPhase(phase);
    await gate.future;
    // Leave the gate phase at once, so a listener never sees a gate that has
    // already been passed.
    if (!_aborted) _setPhase(TestPhase.interStimulus);
  }

  void _open(Completer<void>? gate) {
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  // ----------------------------------------------------------------- timing

  /// A tone length between [minToneMs] and [maxToneMs] in [toneStepMs] steps.
  Duration _randomToneDuration() {
    final steps = (maxToneMs - minToneMs) ~/ toneStepMs;
    final ms =
        minToneMs + toneStepMs * (steps <= 0 ? 0 : _random.nextInt(steps + 1));
    return Duration(milliseconds: ms);
  }

  /// The gap before a stimulus, with the stimulus prepared during it. Takes
  /// longer than the gap only if preparing does, which only lengthens a gap
  /// that is random anyway.
  Future<void> _gapWhilePreparing({
    required int frequencyHz,
    required int levelDbHl,
    required Ear ear,
    required bool silent,
    required Duration duration,
  }) async {
    final prepare = _prepare;
    final gap = _randomGap(duration);
    if (prepare != null) {
      try {
        await prepare(
          frequencyHz: frequencyHz,
          levelDbHl: levelDbHl,
          ear: ear,
          silent: silent,
          duration: duration,
        );
      } catch (_) {
        // Preparing is an optimisation; presenting will try again and report
        // any real failure.
      }
    }
    await gap;
  }

  /// A gap between [minInterStimulusGap] and [maxInterStimulusGap], never
  /// shorter than [nextTone] (ASHA 2005).
  Future<void> _randomGap(Duration nextTone) async {
    final low = max(
      minInterStimulusGap.inMilliseconds,
      min(nextTone.inMilliseconds, maxInterStimulusGap.inMilliseconds),
    );
    final high = max(low, maxInterStimulusGap.inMilliseconds);
    final ms = low + (high == low ? 0 : _random.nextInt(high - low + 1));
    if (ms <= 0) return;
    await Future<void>.delayed(Duration(milliseconds: ms));
  }

  Future<void> _waitWhilePaused() async {
    final waiter = _resume;
    if (waiter != null && !waiter.isCompleted) await waiter.future;
  }

  void _setPhase(TestPhase phase) {
    // While paused, a trial already under way may still finish. Remember the
    // phase it reaches for [resume], but keep showing "paused".
    if (_phase == TestPhase.paused &&
        phase != TestPhase.paused &&
        phase != TestPhase.aborted &&
        phase != TestPhase.complete &&
        _resume != null) {
      _phaseBeforePause = phase;
      return;
    }
    if (_phase == phase) return;
    _phase = phase;
    _notify();
  }

  void _notify() {
    if (hasListeners) notifyListeners();
  }
}
