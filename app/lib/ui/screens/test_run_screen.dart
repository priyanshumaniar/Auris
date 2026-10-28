import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../core/audio/tone_player.dart';
import '../../core/audiometry/audiometry.dart';
import '../../core/audiometry/progress_estimator.dart';
import '../../core/audiometry/test_runner.dart';
import '../../data/models/patient.dart';
import '../../data/models/test_protocol.dart';
import '../../data/models/test_session.dart';
import '../../utils/route_constants.dart';
import '../app_scope.dart';
import '../theme.dart';
import '../widgets/response_button.dart';
import '../widgets/test_progress.dart';

/// Runs the test and captures the patient's responses.
///
/// ## What the patient may see
///
/// The patient is holding the device, so the default view shows only things
/// that carry no information about the stimulus: which ear, how far along, an
/// estimate of the time left, and confirmation that their own press landed.
///
/// It deliberately does **not** show when a tone is playing or how loud it is.
/// A patient who can see that will press on sight, and the audiogram stops
/// being a measurement of hearing. The presentation level lives behind the
/// clinician-view toggle in the app bar.
class TestRunScreen extends StatefulWidget {
  const TestRunScreen({
    super.key,
    required this.patient,
    required this.ears,
    required this.protocol,
  });

  final Patient patient;

  /// Ears in test order, better ear first.
  final List<Ear> ears;

  /// What was set up before the test: transducer, checklist, reason. The
  /// runner adds how the test itself went.
  final TestProtocolRecord protocol;

  @override
  State<TestRunScreen> createState() => _TestRunScreenState();
}

class _TestRunScreenState extends State<TestRunScreen>
    with WidgetsBindingObserver {
  late final TonePlayer _player;
  late final AudiometryTestRunner _runner;
  late final TestProgressEstimator _estimator;

  bool _showClinicianView = false;
  bool _saving = false;
  bool _acknowledging = false;
  String? _error;
  int _lastRecordedStep = 0;
  bool _initialised = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _estimator = TestProgressEstimator(
      totalThresholds: widget.ears.length * kTestOrderHz.length + 1,
    );
  }

  /// Builds the player and runner here rather than in [initState], because
  /// they need [AppScope], and here rather than after the first frame, because
  /// [build] reads the runner on that first frame.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialised) return;
    _initialised = true;

    final services = AppScope.of(context);
    final calibration = services.calibration.profile;
    _player = TonePlayer(calibration: calibration);

    _runner = AudiometryTestRunner(
      ears: widget.ears,
      // The loudest 5 dB step the headphones can actually produce. Asking for
      // more would play at full volume, quieter than asked, and record a
      // wrong level.
      maxLevelFor: (ear, hz) {
        var level = kMaxLevelDbHl;
        while (level > kMinLevelDbHl &&
            !calibration.canRepresent(hz, level, ear: ear)) {
          level -= 5;
        }
        return level;
      },
      prepare: ({
        required int frequencyHz,
        required num levelDbHl,
        required Ear ear,
        required bool silent,
        required Duration duration,
      }) =>
          _player.prepare(
        frequencyHz: frequencyHz,
        levelDbHl: levelDbHl,
        ear: ear,
        silent: silent,
        duration: duration,
      ),
      present: ({
        required int frequencyHz,
        required num levelDbHl,
        required Ear ear,
        required bool silent,
        required Duration duration,
      }) =>
          _player.present(
        frequencyHz: frequencyHz,
        levelDbHl: levelDbHl,
        ear: ear,
        silent: silent,
        duration: duration,
      ),
    )..addListener(_onRunnerChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
  }

  Future<void> _begin() async {
    try {
      final points = await _runner.run();
      if (!mounted) return;
      if (_runner.phase == TestPhase.aborted) return;
      await _saveAndShowResults(points);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// Leaving the app mid-test (a call, the home button) pauses it, so tones
  /// are not played, and misses scored, while nobody is listening.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    if (_runner.isRunning && _runner.phase != TestPhase.paused) {
      _runner.pause();
      _player.stop();
    }
  }

  void _onRunnerChanged() {
    if (!mounted) return;

    // Feed each finished threshold into the estimate, so the time remaining
    // reflects this patient's actual pace rather than a fixed guess.
    final durations = _runner.thresholdDurations;
    while (_lastRecordedStep < durations.length) {
      _estimator.recordThreshold(durations[_lastRecordedStep]);
      _lastRecordedStep++;
    }
    _estimator.totalThresholds = _runner.totalSteps;
    setState(() {});
  }

  /// The button went down: a response, and a confirmation that it landed.
  void _press() {
    _runner.press();
    setState(() => _acknowledging = true);
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _acknowledging = false);
    });
  }

  void _release() => _runner.release();

  Future<void> _saveAndShowResults(List<ThresholdPoint> points) async {
    setState(() => _saving = true);
    final services = AppScope.of(context);

    final session = TestSession(
      id: const Uuid().v4(),
      patientId: widget.patient.id,
      testedAt: DateTime.now(),
      clinicianName:
          services.auth.currentClinician?.displayName ?? 'Unknown clinician',
      points: points,
      // Snapshot the calibration in force now, so recalibrating later cannot
      // silently change what this audiogram means.
      calibration: services.calibration.profile,
      isComplete: true,
      protocol: _runner.protocolRecord.copyWith(
        transducerType: widget.protocol.transducerType,
        reasonForTest: widget.protocol.reasonForTest,
        examinerCredentials: widget.protocol.examinerCredentials,
        checklist: widget.protocol.checklist,
        reducedPrecisionAudio: _player.usingFallbackFormat,
      ),
    );

    try {
      final saved = await services.repository.saveSession(session);
      if (!mounted) return;
      Navigator.pushReplacementNamed(
        context,
        resultsRoute,
        arguments: (patient: widget.patient, session: saved, isFresh: true),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'The test finished but could not be saved. $e';
        });
      }
    }
  }

  Future<bool> _confirmAbandon() async {
    // Once the test has finished it is being saved: there is nothing left to
    // stop, and leaving now would contradict "nothing will be saved".
    if (_saving || !_runner.isRunning) return false;
    final wasPaused = _runner.phase == TestPhase.paused;
    _runner.pause();
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop this test?'),
        content: Text(
          'The ${_runner.completedSteps} '
          'threshold${_runner.completedSteps == 1 ? '' : 's'} measured so far '
          'will be discarded and nothing will be saved. '
          '${widget.patient.fullName.split(' ').first} would need to start again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep going'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AurisTheme.rightEar),
            child: const Text('Stop and discard'),
          ),
        ],
      ),
    );

    if (leave == true) {
      _runner.abort();
      return true;
    }
    // Keep going means back to where it was: still paused if it was paused.
    if (!wasPaused) _runner.resume();
    return false;
  }

  /// Skipping is for a patient who is tiring (BSA 2018 6.8). The frequency
  /// is listed on the report as not tested.
  Future<void> _confirmSkip() async {
    final hz = _runner.currentFrequencyHz;
    if (hz == null) return;
    final skip = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Skip ${formatHzLong(hz)}?'),
        content: const Text(
          'No threshold will be recorded for this frequency, and the report '
          'will list it as skipped.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep testing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Skip'),
          ),
        ],
      ),
    );
    // The test may have moved on while the dialog was open.
    if (skip == true && _runner.currentFrequencyHz == hz) {
      _runner.skipCurrentFrequency();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _runner.removeListener(_onRunnerChanged);
    _runner.dispose();
    _player.dispose();
    super.dispose();
  }

  /// Frequencies already finished for the ear under test.
  Set<int> get _completedFrequencies {
    final ear = _runner.currentEar;
    return ear == null ? const {} : _runner.completedFrequenciesFor(ear);
  }

  List<int> get _currentFrequencies {
    final ear = _runner.currentEar ?? widget.ears.first;
    return _runner.frequenciesFor(ear);
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return _errorScaffold();

    final phase = _runner.phase;
    final paused = phase == TestPhase.paused;
    final changeover = phase == TestPhase.earChangeover;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (await _confirmAbandon()) navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Hearing test'),
          leading: _saving
              ? const SizedBox.shrink()
              : IconButton(
                  tooltip: 'Stop test',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () async {
                    final navigator = Navigator.of(context);
                    if (await _confirmAbandon()) navigator.pop();
                  },
                ),
          actions: [
            IconButton(
              tooltip: _showClinicianView
                  ? 'Hide details from the patient'
                  : 'Clinician view',
              icon: Icon(_showClinicianView
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined),
              onPressed: () =>
                  setState(() => _showClinicianView = !_showClinicianView),
            ),
          ],
        ),
        body: _saving
            ? const Center(child: CircularProgressIndicator())
            : changeover
                ? EarChangeoverCard(
                    finishedEar: _runner.finishedEar ?? widget.ears.first,
                    nextEar: _runner.finishedEar == Ear.right
                        ? Ear.left
                        : Ear.right,
                    onContinue: _runner.continueToNextEar,
                  )
                : phase == TestPhase.reinstruct
                    ? TestGateCard(
                        icon: Icons.record_voice_over_outlined,
                        title: 'Repeat the instructions',
                        message: 'Twice the presses did not match the tone. '
                            'Explain again: press as soon as the tone starts, '
                            'keep holding, and let go as soon as it stops. '
                            'One more practice tone follows.',
                        buttonLabel: 'Instructions repeated',
                        onContinue: _runner.continueAfterReinstruction,
                      )
                    : phase == TestPhase.breakOffered
                        ? TestGateCard(
                            icon: Icons.free_breakfast_outlined,
                            title: 'Time for a short break?',
                            message: 'The test has been running for 20 '
                                'minutes. Offer the patient a short rest, '
                                'then continue when they are ready.',
                            buttonLabel: 'Continue the test',
                            onContinue: _runner.continueAfterBreak,
                          )
                        : _testBody(paused),
      ),
    );
  }

  Widget _testBody(bool paused) {
    final familiarising = _runner.phase == TestPhase.familiarising;
    return Column(
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: _estimator.progress),
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOut,
          builder: (context, value, _) => LinearProgressIndicator(
            value: value,
            minHeight: 5,
            backgroundColor: AurisTheme.hairline,
          ),
        ),
        const SizedBox(height: 24),
        TestProgressHeader(
          ear: _runner.currentEar,
          completed: _estimator.completedCount,
          total: _estimator.totalThresholds,
          remainingLabel: familiarising
              ? 'Practice tone'
              : _estimator.remainingLabel,
          frequencies: _currentFrequencies,
          currentFrequencyHz: _runner.currentFrequencyHz,
          completedFrequencies: _completedFrequencies,
        ),
        if (_showClinicianView) ...[
          const SizedBox(height: 16),
          _clinicianStrip(),
        ],
        // The button shrinks to fit a small phone, or the clinician strip,
        // rather than pushing the rest off the screen.
        Expanded(
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: ResponseButton(
                enabled: !paused,
                onPressed: _press,
                onReleased: _release,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 26,
          child: _acknowledging
              ? const ResponseAcknowledgement(visible: true)
              : Text(
                  paused
                      ? 'Paused. Press resume when ready'
                      : familiarising
                          ? 'Practice: hold while you hear it'
                          : 'Hold while you hear a tone, however faint',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 14.5, color: AurisTheme.muted),
                ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.only(bottom: 26),
          child: Column(
            children: [
              if (!paused)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 40, vertical: 8),
                  child: Text(
                    'Some of the time there is no tone at all. Only press when '
                    'you actually hear one.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12.5, height: 1.5, color: AurisTheme.muted),
                  ),
                ),
              TextButton.icon(
                onPressed: () => setState(() {
                  paused ? _runner.resume() : _runner.pause();
                }),
                icon: Icon(paused
                    ? Icons.play_arrow_rounded
                    : Icons.pause_rounded),
                label: Text(paused ? 'Resume' : 'Pause'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Level, frequency and phase - hidden from the patient by default.
  Widget _clinicianStrip() => Container(
        margin: const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: AurisTheme.ink.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AurisTheme.hairline),
        ),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _stat(
                    _runner.currentIsRetest ? 'Retest' : 'Frequency',
                    _runner.currentFrequencyHz == null
                        ? '-'
                        : formatHzLong(_runner.currentFrequencyHz!)),
                _stat('Level',
                    _runner.currentLevelDbHl == null
                        ? '-'
                        : '${_runner.currentLevelDbHl} dB HL'),
                _stat('State', _phaseLabel(_runner.phase)),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Visible to you only. Keep this hidden while the patient holds '
              'the device.',
              style: TextStyle(fontSize: 11, color: AurisTheme.muted),
            ),
            if (_runner.phase != TestPhase.familiarising &&
                _runner.currentFrequencyHz != null) ...[
              const SizedBox(height: 4),
              TextButton.icon(
                icon: const Icon(Icons.skip_next_rounded, size: 18),
                label: const Text('Skip this frequency'),
                onPressed: _confirmSkip,
              ),
            ],
          ],
        ),
      );

  Widget _stat(String label, String value) => Column(
        children: [
          Text(label.toUpperCase(),
              style: const TextStyle(
                  fontSize: 9,
                  letterSpacing: 0.6,
                  fontWeight: FontWeight.w700,
                  color: AurisTheme.muted)),
          const SizedBox(height: 2),
          Text(value,
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AurisTheme.ink)),
        ],
      );

  static String _phaseLabel(TestPhase phase) => switch (phase) {
        TestPhase.idle => 'Starting',
        TestPhase.familiarising => 'Practice',
        TestPhase.reinstruct => 'Re-instruct',
        TestPhase.breakOffered => 'Break',
        TestPhase.presenting => 'Tone on',
        TestPhase.awaitingResponse => 'Listening',
        TestPhase.interStimulus => 'Gap',
        TestPhase.earChangeover => 'Ear change',
        TestPhase.paused => 'Paused',
        TestPhase.complete => 'Done',
        TestPhase.aborted => 'Stopped',
      };

  Widget _errorScaffold() => Scaffold(
        appBar: AppBar(title: const Text('Hearing test')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline,
                    size: 44, color: AurisTheme.warning),
                const SizedBox(height: 14),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 14, height: 1.5, color: AurisTheme.muted),
                ),
                const SizedBox(height: 20),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Back to patient'),
                ),
              ],
            ),
          ),
        ),
      );
}
