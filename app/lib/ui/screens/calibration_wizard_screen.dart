import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/audio/tone_player.dart';
import '../../core/audiometry/audiometry.dart';
import '../../core/audiometry/calibration.dart';
import '../../core/audiometry/hughson_westlake.dart';
import '../../data/calibration_history.dart';
import '../app_scope.dart';
import '../calibration_record_actions.dart';
import '../theme.dart';
import '../widgets/auris_button.dart';
import '../widgets/calibration_by_ear.dart';
import '../widgets/response_button.dart';

/// Guided calibration.
///
/// The previous version put a reference tone, a text box and a formula on one
/// screen and expected the reader to know what dB SPL meant. This walks through
/// it one decision at a time, in plain language, and offers a route for the
/// common case of not owning a sound level meter.
///
/// Two paths:
///
///  * **Sound level meter** - measure the real output once and the app solves
///    for the rest. The only method that makes absolute dB HL trustworthy.
///  * **Biological check** - test somebody known to hear normally and use the
///    difference as the correction. The standard daily verification in clinics.
///    Clearly labelled as the weaker option, on screen and on every report.
class CalibrationWizardScreen extends StatefulWidget {
  const CalibrationWizardScreen({super.key});

  @override
  State<CalibrationWizardScreen> createState() =>
      _CalibrationWizardScreenState();
}

enum _Path { undecided, meter, biological }

class _CalibrationWizardScreenState extends State<CalibrationWizardScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  static const _referenceFrequencyHz = 1000;
  static const _referenceLevelDbHl = 70;

  /// Lowest level the meter tone is allowed to drop to. See [_meterLevelDbHl].
  static const _minReferenceLevelDbHl = 40;

  final _pageController = PageController();
  final _transducerController = TextEditingController();
  final _measuredController = TextEditingController();

  TonePlayer? _player;
  _Path _path = _Path.undecided;
  int _page = 0;
  bool _playing = false;
  bool _initialised = false;

  // Biological check state.
  HughsonWestlakeSearch? _search;
  bool _bioRunning = false;
  int? _bioResultDbHl;

  // Which ears this run covers, and progress through them.
  CalibrationEarChoice _earChoice = CalibrationEarChoice.both;
  List<Ear> _queue = const [];
  Ear _currentEar = Ear.right;
  int get _earNumber => _earChoice.ears.length - _queue.length + 1;
  bool get _multiEar => _earChoice.ears.length > 1;

  /// The calibration being built during this run. Saved only when every
  /// chosen ear is done, so leaving half way changes nothing.
  CalibrationProfile? _working;
  final Map<Ear, double> _corrections = {};

  /// Human-listener calibration of both ears needs the listener to hear the
  /// same in both. The user confirms that before starting.
  bool _listenerEqualEars = false;

  /// A left/right difference above this, in dB, is flagged before saving.
  static const double _imbalanceWarnDb = 10;

  CalibrationEvent? _savedEvent;
  bool _finishing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialised) return;
    _initialised = true;
    _transducerController.text = _profile.transducerName;
  }

  /// Leaving the app during the listener check stops it: tones played while
  /// nobody is listening would be scored as not heard.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed || !_bioRunning) return;
    _player?.stop();
    final pending = _response;
    if (pending != null && !pending.isCompleted) pending.complete(false);
    setState(_resetEarStep);
    _toast('The check stopped because Auris went into the background. '
        'Start it again when the listener is ready.');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    _transducerController.dispose();
    _measuredController.dispose();
    _player?.dispose();
    super.dispose();
  }

  CalibrationProfile get _profile => AppScope.of(context).calibration.profile;

  /// What tones play with during a run: the calibration as it stands,
  /// including any ear already done in this run.
  CalibrationProfile get _runProfile => _working ?? _profile;

  TonePlayer _ensurePlayer() {
    final player = _player ??= TonePlayer(calibration: _runProfile);
    player.calibration = _runProfile;
    return player;
  }

  Future<void> _save(CalibrationProfile profile) async {
    await AppScope.of(context).calibration.save(profile);
    if (mounted) setState(() {});
  }

  void _goTo(int page) {
    setState(() => _page = page);
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
    );
  }

  // ------------------------------------------------------------ meter path

  /// The level of the meter tone: 70 dB HL, or lower in 10 dB steps when this
  /// ear's existing correction would push 70 dB HL past full scale.
  ///
  /// A tone past full scale is clipped, so the meter reads less than Auris
  /// asked for and the correction would come out several dB too large.
  int get _meterLevelDbHl {
    var level = _referenceLevelDbHl;
    while (level > _minReferenceLevelDbHl &&
        !_runProfile.canRepresent(_referenceFrequencyHz, level,
            ear: _currentEar)) {
      level -= 10;
    }
    return level;
  }

  bool get _meterToneFits => _runProfile
      .canRepresent(_referenceFrequencyHz, _meterLevelDbHl, ear: _currentEar);

  static const _meterToneTooLoud =
      'This ear already has a large correction, so the meter tone would be '
      'distorted. Reset the calibration in Settings, then calibrate again.';

  Future<void> _playReferenceTone() async {
    if (!_meterToneFits) {
      _toast(_meterToneTooLoud);
      return;
    }
    setState(() => _playing = true);
    try {
      await _ensurePlayer().present(
        frequencyHz: _referenceFrequencyHz,
        levelDbHl: _meterLevelDbHl,
        ear: _currentEar,
        duration: const Duration(seconds: 5),
      );
    } catch (e) {
      _toast('Could not play the tone: $e');
    } finally {
      if (mounted) setState(() => _playing = false);
    }
  }

  /// Solves for the true full-scale output from one measurement.
  ///
  /// The tone was generated for a target SPL under the *assumed* full-scale
  /// figure. If the meter reads something else, the whole chain is off by
  /// exactly that difference, so the correction is a straight addition.
  Future<void> _applyMeterReading() async {
    final measured = double.tryParse(_measuredController.text.trim());
    if (measured == null) {
      _toast('Enter the number your meter showed.');
      return;
    }

    if (!_meterToneFits) {
      _toast(_meterToneTooLoud);
      return;
    }

    // The tone was made to produce `target` dB SPL in this ear. If the meter
    // read more, this ear is louder than Auris thinks by the difference, so
    // its correction moves down by that much (and up if it read less).
    final target =
        _runProfile.targetDbSpl(_referenceFrequencyHz, _meterLevelDbHl);
    await _recordEar(target - measured);
  }

  // ------------------------------------------------------- biological path

  /// Runs a short threshold search at 1 kHz on a normal-hearing listener.
  Future<void> _runBiologicalCheck() async {
    final search = HughsonWestlakeSearch(
      startLevelDbHl: 40,
      // Never above what this ear's output can reach without clipping.
      maxLevelDbHl: _bioCeiling,
    );
    setState(() {
      _bioRunning = true;
      _bioResultDbHl = null;
      _search = search;
    });

    // This run is current only while [_search] is still the search it
    // started. A check stopped (going to the background, leaving the step)
    // and started again must not be continued by the old loop.
    bool current() => mounted && identical(_search, search);

    final player = _ensurePlayer();
    try {
      while (current() && !search.isComplete) {
        final stimulus = search.current;
        await Future<void>.delayed(
            Duration(milliseconds: 500 + (stimulus.levelDbHl.abs() % 7) * 120));
        if (!current()) return;

        // Armed before the tone, so a press while it is still playing counts.
        final response = _response = Completer<bool>();
        await player.present(
          frequencyHz: _referenceFrequencyHz,
          levelDbHl: stimulus.levelDbHl,
          ear: _currentEar,
          silent: stimulus.isCatchTrial,
        );
        if (!current()) return;

        // Wait for a press, or treat silence as "not heard".
        final heard = await response.future.timeout(
          const Duration(milliseconds: 2000),
          onTimeout: () => false,
        );
        if (!current()) return;
        _response = null;
        search.recordResponse(responded: heard);
        setState(() {});
      }

      if (!mounted || _search == null) return;
      final result = _search!.result;
      setState(() {
        _bioResultDbHl = result.thresholdDbHl;
        _bioRunning = false;
      });
      if (result.atFloor) {
        // Heard even the quietest tone: the true threshold is somewhere below
        // -10 dB HL, so -10 would under-correct. Do not offer it.
        setState(() => _bioResultDbHl = null);
        _toast('The listener heard even the quietest tone, so this device is '
            'too loud to calibrate this way. Lower the system volume and run '
            'the check again.');
      } else if (result.thresholdDbHl == null) {
        _toast(result.noResponse
            ? 'The listener did not respond even at the loudest level. Check '
                'the headphones and the system volume, then try again.'
            : 'No clear threshold was found. Repeat the instructions and try '
                'again.');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _bioRunning = false);
        _toast('Could not run the check: $e');
      }
    }
  }

  /// The listener's answer to the tone being played, while one is.
  Completer<bool>? _response;

  void _listenerPressed() {
    final pending = _response;
    if (pending != null && !pending.isCompleted) pending.complete(true);
  }

  /// The loudest 5 dB step at the reference frequency this ear can produce.
  int get _bioCeiling {
    var level = kMaxLevelDbHl;
    while (level > kMinLevelDbHl &&
        !_runProfile.canRepresent(_referenceFrequencyHz, level,
            ear: _currentEar)) {
      level -= 5;
    }
    return level;
  }

  /// Applies the biological result.
  ///
  /// A listener with normal hearing should threshold at about 0 dB HL. If they
  /// measured at, say, 30 dB HL, the output is 30 dB quieter than the app
  /// believes, so everything shifts up by that amount.
  Future<void> _applyBiological() async {
    final measured = _bioResultDbHl;
    if (measured == null) return;
    await _recordEar(measured.toDouble());
  }

  // ------------------------------------------------------------- the run

  CalibrationMethod get _runMethod => _path == _Path.meter
      ? CalibrationMethod.soundLevelMeter
      : CalibrationMethod.biological;

  /// Starts (or restarts) a run over the chosen ears, right ear first.
  void _startRun() {
    setState(() {
      _working = _profile;
      _queue = List<Ear>.of(_earChoice.ears);
      _currentEar = _queue.first;
      _corrections.clear();
      _resetEarStep();
      _savedEvent = null;
    });
    _goTo(2);
  }

  void _resetEarStep() {
    _measuredController.clear();
    _bioResultDbHl = null;
    _search = null;
    _bioRunning = false;
  }

  /// Applies [correctionDb] to the current ear and moves to the next one, or
  /// finishes the run.
  Future<void> _recordEar(double correctionDb) async {
    // Nothing left to record: a second tap on Apply after the run finished.
    if (_queue.isEmpty) return;
    final working = _working ?? _profile;
    _corrections[_currentEar] = correctionDb;
    _working = working.withMeasuredEar(
      _currentEar,
      method: _runMethod,
      correctionDb: correctionDb,
      at: DateTime.now(),
      transducerName: _transducerName,
    );
    final done = _currentEar;
    _queue = _queue.sublist(1);

    if (_queue.isNotEmpty) {
      setState(() {
        _currentEar = _queue.first;
        _resetEarStep();
      });
      _toast('${done.label} ear done. Now the ${_currentEar.label.toLowerCase()} '
          'ear.');
      return;
    }
    await _finishRun();
  }

  Future<void> _finishRun() async {
    var profile = _working ?? _profile;
    final measured = _earChoice.ears;
    final now = DateTime.now();
    var copied = false;
    double? imbalance;
    var imbalanceAccepted = false;

    if (measured.length == 1) {
      // One ear done: the administrator decides what happens to the other.
      copied = await _askCopyOrKeep(measured.single, profile);
      if (!mounted) return;
      if (copied) profile = profile.copyEarToOther(measured.single, at: now);
    } else {
      imbalance = profile.earImbalanceDb;
      if (imbalance > _imbalanceWarnDb) {
        final save = await _confirmImbalance(imbalance);
        if (!mounted) return;
        if (!save) {
          _startRun();
          return;
        }
        imbalanceAccepted = true;
      }
    }

    setState(() => _finishing = true);
    try {
      await _save(profile);
    } catch (e) {
      _toast('Could not save the calibration: $e');
      if (mounted) setState(() => _finishing = false);
      return;
    }
    if (!mounted) return;

    // The calibration is saved from here on. A failure below only loses the
    // history entry, and must not be reported as a failed calibration.
    try {
      final services = AppScope.of(context);

      EarRecord recordFor(Ear ear) => EarRecord(
            action: measured.contains(ear)
                ? EarAction.measured
                : copied
                    ? EarAction.copied
                    : EarAction.kept,
            correctionDb: _corrections[ear],
            methodAfter: profile.ear(ear).method,
            offsetAfterDb: profile.totalCorrectionDb(ear),
          );

      final event = await services.calibrationHistory?.record(
        performedBy:
            services.auth.currentClinician?.displayName ?? 'Unknown user',
        method: _runMethod,
        earChoice: _earChoice,
        right: recordFor(Ear.right),
        left: recordFor(Ear.left),
        profile: profile,
        imbalanceDb: imbalance,
        imbalanceAccepted: imbalanceAccepted,
        listenerConfirmedEqualEars:
            _runMethod == CalibrationMethod.biological && _multiEar
                ? _listenerEqualEars
                : false,
        at: now,
      );
      if (!mounted) return;
      setState(() => _savedEvent = event);
    } catch (e) {
      _toast('Calibration saved, but its history entry could not be '
          'recorded: $e');
    } finally {
      if (mounted) {
        setState(() {
          _working = null;
          _finishing = false;
        });
        _goTo(3);
      }
    }
  }

  /// After a single-ear calibration: copy it to the other ear, or leave the
  /// other ear exactly as it was (which may itself be a valid calibration).
  Future<bool> _askCopyOrKeep(Ear done, CalibrationProfile profile) async {
    final other = done.other;
    final otherNow = describeEarCalibration(profile.ear(other), other);
    final copy = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('What about the ${other.label.toLowerCase()} ear?'),
        content: Text(
          'You calibrated the ${done.label.toLowerCase()} ear.\n\n'
          'The ${other.label.toLowerCase()} ear is currently: $otherNow.\n\n'
          'Copy the ${done.label.toLowerCase()} ear\'s calibration to it, or '
          'keep it exactly as it is? A copied ear is marked as copied, not '
          'measured, on screen and on every report.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Keep ${other.label.toLowerCase()} ear as it is'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Copy to ${other.label.toLowerCase()} ear'),
          ),
        ],
      ),
    );
    return copy ?? false;
  }

  /// Both ears measured, but they differ a lot. Usually a hardware problem.
  Future<bool> _confirmImbalance(double imbalanceDb) async {
    final save = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('The two sides differ by '
            '${imbalanceDb.toStringAsFixed(1)} dB'),
        content: Text(
          'Left and right normally come out within a few dB of each other. A '
          'difference of more than ${_imbalanceWarnDb.toStringAsFixed(0)} dB '
          'usually means one earpiece is damaged, blocked or not sitting '
          'properly${_runMethod == CalibrationMethod.biological ? ', or that the listener hears differently in each ear' : ''}.\n\n'
          'Check the headphones and redo both ears. Save anyway only if you '
          'are sure; the record will show this difference.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save anyway'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Redo both ears'),
          ),
        ],
      ),
    );
    return save ?? false;
  }

  String get _transducerName => _transducerController.text.trim().isEmpty
      ? 'Unnamed headphones'
      : _transducerController.text.trim();

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Calibrate this device'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(
        children: [
          _StepBar(current: _page),
          Expanded(
            child: PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _whyPage(),
                _choosePathPage(),
                _path == _Path.biological ? _biologicalPage() : _meterPage(),
                _donePage(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------- step 1: why

  Widget _whyPage() => ListView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
        children: [
          const _Hero(
            icon: Icons.tune_rounded,
            title: 'What calibration does',
            body: 'Auris knows how strong a signal it is sending. It has no way '
                'to know how loud that actually sounds in your headphones - '
                'that depends on the volume setting, the sound card and the '
                'headphones themselves.',
          ),
          const SizedBox(height: 18),
          const _Comparison(),
          const SizedBox(height: 18),
          const AurisCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.schedule_rounded, size: 18, color: AurisTheme.muted),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'This takes about five minutes and only has to be done once '
                    'per device and headphone pair - then again if you change '
                    'either, or the volume setting.',
                    style: TextStyle(
                        fontSize: 13, height: 1.5, color: AurisTheme.muted),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 26),
          Center(
            child: AurisButton(
              buttonName: 'Start',
              width: 220,
              onTap: () => _goTo(1),
            ),
          ),
        ],
      );

  // -------------------------------------------------- step 2: choose a path

  Widget _choosePathPage() => ListView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
        children: [
          const Text(
            'Do you have a sound level meter?',
            style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w700,
                color: AurisTheme.ink),
          ),
          const SizedBox(height: 8),
          const Text(
            'A device that measures how loud a sound really is. Any audiology '
            'or ENT department will have one.',
            style: TextStyle(
                fontSize: 14, height: 1.5, color: AurisTheme.muted),
          ),
          const SizedBox(height: 22),
          _PathCard(
            selected: _path == _Path.meter,
            recommended: true,
            icon: Icons.speaker_phone_rounded,
            title: 'Yes, I have a meter',
            body: 'Play one tone, tell Auris what the meter reads, done. This '
                'is the only method that makes the numbers on the audiogram '
                'properly reliable.',
            onTap: () => setState(() => _path = _Path.meter),
          ),
          const SizedBox(height: 12),
          _PathCard(
            selected: _path == _Path.biological,
            icon: Icons.person_search_rounded,
            title: 'No - use a normal-hearing person instead',
            body: 'Someone with known normal hearing takes a two-minute test. '
                'If they appear to have a loss, your setup is that much too '
                'quiet, and Auris corrects for it.',
            caveat: 'Better than nothing, and clinics use it as a daily check. '
                'But it is only as good as the assumption that your reference '
                'person really does hear normally - so reports will say the '
                'device was calibrated this way.',
            onTap: () => setState(() => _path = _Path.biological),
          ),
          const SizedBox(height: 22),
          const SectionLabel('Which headphones?'),
          const SizedBox(height: 8),
          AurisCard(
            child: TextField(
              controller: _transducerController,
              decoration: const InputDecoration(
                hintText: 'e.g. Sennheiser HD 280, TDH-39P',
                border: InputBorder.none,
                isDense: true,
              ),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Printed on every report. A calibration is only valid for the exact '
            'headphones it was done with.',
            style: TextStyle(fontSize: 11.5, color: AurisTheme.muted),
          ),
          const SizedBox(height: 22),
          const SectionLabel('Which ears?'),
          const SizedBox(height: 8),
          SegmentedButton<CalibrationEarChoice>(
            segments: const [
              ButtonSegment(
                  value: CalibrationEarChoice.both, label: Text('Both ears')),
              ButtonSegment(
                  value: CalibrationEarChoice.left, label: Text('Left only')),
              ButtonSegment(
                  value: CalibrationEarChoice.right, label: Text('Right only')),
            ],
            selected: {_earChoice},
            onSelectionChanged: (s) => setState(() => _earChoice = s.first),
          ),
          const SizedBox(height: 6),
          Text(
            _earChoice == CalibrationEarChoice.both
                ? 'Recommended. Each side of the headphones gets its own '
                    'correction, and Auris warns you if the two sides differ a '
                    'lot.'
                : 'Only the ${_earChoice == CalibrationEarChoice.left ? 'left' : 'right'} '
                    'ear is measured. Afterwards you choose whether to copy the '
                    'result to the other ear or leave that ear as it is.',
            style: const TextStyle(fontSize: 11.5, color: AurisTheme.muted),
          ),
          const SizedBox(height: 24),
          Center(
            child: AurisButton(
              buttonName: 'Continue',
              width: 220,
              onTap: _path == _Path.undecided ? null : _startRun,
            ),
          ),
          if (_path == _Path.undecided) ...[
            const SizedBox(height: 10),
            const Center(
              child: Text('Pick one to continue',
                  style: TextStyle(fontSize: 12.5, color: AurisTheme.muted)),
            ),
          ],
        ],
      );

  // ------------------------------------------------- step 3a: meter measure

  Widget _meterPage() {
    final target =
        _runProfile.targetDbSpl(_referenceFrequencyHz, _meterLevelDbHl);

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
      children: [
        Text(
          'Measure the output: ${_currentEar.label.toLowerCase()} ear',
          style: const TextStyle(
              fontSize: 21, fontWeight: FontWeight.w700, color: AurisTheme.ink),
        ),
        if (_multiEar) ...[
          const SizedBox(height: 4),
          Text('Ear $_earNumber of ${_earChoice.ears.length}',
              style: const TextStyle(fontSize: 13, color: AurisTheme.muted)),
        ],
        const SizedBox(height: 18),
        const _NumberedStep(
          1,
          'Set the volume where you want it',
          'Pick the level the clinic will always use, then do not change it '
              'again. Everything below assumes this setting.',
        ),
        _NumberedStep(
          2,
          'Put the meter against the ${_currentEar.label.toLowerCase()} earcup',
          'Use a coupler or artificial ear if you have one. If not, press the '
              'earcup firmly over the microphone so no sound leaks out.',
        ),
        _NumberedStep(
          3,
          'Play the tone and read the meter',
          'It plays for five seconds in the '
              '${_currentEar.label.toLowerCase()} ear. Take the reading while '
              'it is steady.',
        ),
        const SizedBox(height: 12),
        Center(
          child: AurisOutlineButton(
            buttonName: _playing ? 'Playing…' : 'Play the tone',
            icon: Icons.volume_up_rounded,
            width: 230,
            onTap: _playing ? null : _playReferenceTone,
          ),
        ),
        const SizedBox(height: 22),
        const _NumberedStep(
          4,
          'Type in what the meter showed',
          'Just the number. Auris works out the rest.',
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _measuredController,
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true, signed: true),
                decoration: const InputDecoration(
                  hintText: 'Meter reading',
                  suffixText: 'dB SPL',
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 10),
            AurisButton(
              buttonName: 'Apply',
              height: 46,
              width: 100,
              busy: _finishing,
              onTap: _applyMeterReading,
            ),
          ],
        ),
        const SizedBox(height: 14),
        AurisCard(
          padding: const EdgeInsets.all(13),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.lightbulb_outline_rounded,
                  size: 18, color: AurisTheme.muted),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'With the current settings Auris expects about '
                  '${target.toStringAsFixed(0)} dB SPL. A very different reading '
                  'is normal and is exactly what this step corrects - but if it '
                  'is off by more than about 40 dB, check the meter is in the '
                  'right place and the volume is not muted.',
                  style: const TextStyle(
                      fontSize: 12.5, height: 1.5, color: AurisTheme.muted),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Center(
          child: TextButton(
            onPressed: () => _goTo(1),
            child: const Text('Back'),
          ),
        ),
      ],
    );
  }

  // -------------------------------------------- step 3b: biological check

  Widget _biologicalPage() {
    final done = _bioResultDbHl != null;

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
      children: [
        Text(
          'Test a normal-hearing person: ${_currentEar.label.toLowerCase()} ear',
          style: const TextStyle(
              fontSize: 21, fontWeight: FontWeight.w700, color: AurisTheme.ink),
        ),
        if (_multiEar) ...[
          const SizedBox(height: 4),
          Text('Ear $_earNumber of ${_earChoice.ears.length}',
              style: const TextStyle(fontSize: 13, color: AurisTheme.muted)),
        ],
        const SizedBox(height: 10),
        const Text(
          'Someone with no known hearing problems, ideally under 40 and not '
          'recently exposed to loud noise. It can be you.',
          style: TextStyle(fontSize: 14, height: 1.5, color: AurisTheme.muted),
        ),
        const SizedBox(height: 18),
        const _NumberedStep(
          1,
          'Set the volume where you want it',
          'The same setting the clinic will always use.',
        ),
        _NumberedStep(
          2,
          'Put the headphones on, in a quiet room',
          'The tone plays in the ${_currentEar.label.toLowerCase()} ear only.',
        ),
        const _NumberedStep(
          3,
          'Press the button whenever you hear a beep',
          'Even if it is very faint. Takes about two minutes.',
        ),
        const SizedBox(height: 18),
        if (_multiEar && _earNumber == 1 && !_bioRunning && !done) ...[
          AurisCard(
            padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
            child: CheckboxListTile(
              value: _listenerEqualEars,
              onChanged: (v) =>
                  setState(() => _listenerEqualEars = v ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'The listener has no known hearing difference between their '
                'ears',
                style: TextStyle(fontSize: 13.5, color: AurisTheme.ink),
              ),
              subtitle: const Text(
                'Calibrating each ear on a person assumes both their ears '
                'hear the same. If one is weaker, that weakness would be '
                'built into this device.',
                style: TextStyle(fontSize: 12, color: AurisTheme.muted),
              ),
            ),
          ),
          if (!_listenerEqualEars)
            Center(
              child: TextButton(
                onPressed: () {
                  setState(() => _earChoice = CalibrationEarChoice.right);
                  _startRun();
                },
                child: const Text(
                    'Not sure? Calibrate the right ear only instead'),
              ),
            ),
          const SizedBox(height: 10),
        ],
        if (!_bioRunning && !done)
          Center(
            child: AurisButton(
              buttonName: 'Start the check',
              width: 220,
              onTap: (_multiEar && _earNumber == 1 && !_listenerEqualEars)
                  ? null
                  : _runBiologicalCheck,
            ),
          ),
        if (_bioRunning) ...[
          Center(
            child: ResponseButton(
              size: 170,
              onPressed: _listenerPressed,
              onReleased: () {},
            ),
          ),
          const SizedBox(height: 14),
          const Center(
            child: Text(
              'Press every time you hear a beep, however faint',
              style: TextStyle(fontSize: 13.5, color: AurisTheme.muted),
            ),
          ),
        ],
        if (done) ...[
          _BiologicalResult(
            measuredDbHl: _bioResultDbHl!,
            onApply: _applyBiological,
            onRetry: _runBiologicalCheck,
          ),
        ],
        const SizedBox(height: 14),
        Center(
          child: TextButton(
            onPressed: _bioRunning ? null : () => _goTo(1),
            child: const Text('Back'),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------- step 4: done

  Widget _donePage() {
    final profile = _profile;
    final meter = profile.method == CalibrationMethod.soundLevelMeter;

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 30, 24, 40),
      children: [
        Center(
          child: Container(
            height: 92,
            width: 92,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: (meter ? AurisTheme.success : AurisTheme.warning)
                  .withValues(alpha: 0.10),
            ),
            child: Icon(
              meter ? Icons.verified_rounded : Icons.check_rounded,
              size: 46,
              color: meter ? AurisTheme.success : AurisTheme.warning,
            ),
          ),
        ),
        const SizedBox(height: 20),
        Center(
          child: Text(
            switch (profile.method) {
              CalibrationMethod.soundLevelMeter => 'Calibrated',
              CalibrationMethod.biological => 'Roughly calibrated',
              CalibrationMethod.none => 'Partly calibrated',
            },
            style: const TextStyle(
                fontSize: 23,
                fontWeight: FontWeight.w700,
                color: AurisTheme.ink),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          switch (profile.method) {
            CalibrationMethod.soundLevelMeter =>
              'The levels Auris reports are now anchored to a real '
                  'measurement on ${profile.transducerName}. Audiograms from '
                  'this device can be read as actual dB HL.',
            CalibrationMethod.biological =>
              'Auris has corrected for how quiet your setup was, using a '
                  'normal-hearing listener on ${profile.transducerName}. This '
                  'is far better than no calibration, but reports will say it '
                  'was not measured with a meter, because it was not.',
            CalibrationMethod.none =>
              'One ear is calibrated and the other is not. Tests on the '
                  'uncalibrated ear, and reports that include it, are marked '
                  'screening only until it is calibrated too.',
          },
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 14, height: 1.6, color: AurisTheme.muted),
        ),
        const SizedBox(height: 22),
        AurisCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _summaryRow('Headphones', profile.transducerName),
              const Divider(height: 20),
              CalibrationByEar(profile: profile),
              for (final ear in Ear.values)
                if (_corrections[ear] != null) ...[
                  const Divider(height: 20),
                  _summaryRow(
                    '${ear.label} ear correction this time',
                    '${_corrections[ear]! >= 0 ? '+' : ''}'
                        '${_corrections[ear]!.toStringAsFixed(1)} dB',
                  ),
                ],
            ],
          ),
        ),
        if (profile.usesHumanListener) ...[
          const SizedBox(height: 14),
          const HumanCalibrationNotice(),
        ],
        if (_savedEvent != null) ...[
          const SizedBox(height: 14),
          Center(
            child: AurisOutlineButton(
              buttonName: 'View calibration record (PDF)',
              icon: Icons.picture_as_pdf_rounded,
              width: 300,
              onTap: () => printCalibrationRecord(context, _savedEvent!),
            ),
          ),
          const SizedBox(height: 4),
          const Center(
            child: Text(
              'Also kept under Settings → Calibration history.',
              style: TextStyle(fontSize: 11.5, color: AurisTheme.muted),
            ),
          ),
        ],
        const SizedBox(height: 14),
        const AurisCard(
          padding: EdgeInsets.all(13),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.event_repeat_rounded,
                  size: 18, color: AurisTheme.muted),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Repeat this after changing headphones, changing device, or '
                  'changing the volume setting - and as a routine check every '
                  'few months.',
                  style: TextStyle(
                      fontSize: 12.5, height: 1.5, color: AurisTheme.muted),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 26),
        Center(
          child: AurisButton(
            buttonName: 'Done',
            width: 220,
            onTap: () => Navigator.pop(context),
          ),
        ),
      ],
    );
  }

  Widget _summaryRow(String label, String value) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 13, color: AurisTheme.muted)),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: AurisTheme.ink),
            ),
          ),
        ],
      );
}

// ---------------------------------------------------------------- widgets

class _StepBar extends StatelessWidget {
  const _StepBar({required this.current});
  final int current;

  static const _labels = ['Why', 'Method', 'Measure', 'Done'];

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
        child: Row(
          children: [
            for (var i = 0; i < _labels.length; i++) ...[
              Expanded(
                child: Column(
                  children: [
                    Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: i <= current
                            ? AurisTheme.primary
                            : AurisTheme.hairline,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _labels[i],
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight:
                            i == current ? FontWeight.w700 : FontWeight.w400,
                        color: i <= current
                            ? AurisTheme.primary
                            : AurisTheme.muted,
                      ),
                    ),
                  ],
                ),
              ),
              if (i != _labels.length - 1) const SizedBox(width: 6),
            ],
          ],
        ),
      );
}

class _Hero extends StatelessWidget {
  const _Hero({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Container(
            height: 78,
            width: 78,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AurisTheme.primary.withValues(alpha: 0.10),
            ),
            child: Icon(icon, size: 38, color: AurisTheme.primary),
          ),
          const SizedBox(height: 18),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w700,
                color: AurisTheme.ink),
          ),
          const SizedBox(height: 10),
          Text(
            body,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 14.5, height: 1.6, color: AurisTheme.muted),
          ),
        ],
      );
}

/// Side-by-side of what an uncalibrated and a calibrated device can claim.
class _Comparison extends StatelessWidget {
  const _Comparison();

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: _panel(
              colour: AurisTheme.warning,
              icon: Icons.trending_down_rounded,
              title: 'Without calibration',
              lines: const [
                'Shape of the audiogram is real',
                'The dB numbers are not',
                'Reports say "screening only"',
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _panel(
              colour: AurisTheme.success,
              icon: Icons.verified_outlined,
              title: 'After calibration',
              lines: const [
                'Shape of the audiogram is real',
                'The dB numbers mean something',
                'Comparable with other clinics',
              ],
            ),
          ),
        ],
      );

  Widget _panel({
    required Color colour,
    required IconData icon,
    required String title,
    required List<String> lines,
  }) =>
      Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: colour.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(AurisTheme.cardRadius),
          border: Border.all(color: colour.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 19, color: colour),
            const SizedBox(height: 8),
            Text(title,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: colour)),
            const SizedBox(height: 8),
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Text('• $line',
                    style: const TextStyle(
                        fontSize: 11.5, height: 1.4, color: AurisTheme.ink)),
              ),
          ],
        ),
      );
}

class _PathCard extends StatelessWidget {
  const _PathCard({
    required this.selected,
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
    this.caveat,
    this.recommended = false,
  });

  final bool selected;
  final IconData icon;
  final String title;
  final String body;
  final String? caveat;
  final bool recommended;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 170),
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: selected
                ? AurisTheme.primary.withValues(alpha: 0.05)
                : AurisTheme.surface,
            borderRadius: BorderRadius.circular(AurisTheme.cardRadius),
            border: Border.all(
              color: selected ? AurisTheme.primary : AurisTheme.hairline,
              width: selected ? 1.8 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon,
                  size: 22,
                  color: selected ? AurisTheme.primary : AurisTheme.muted),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(title,
                              style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: AurisTheme.ink)),
                        ),
                        if (recommended) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: AurisTheme.success.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Text('Best',
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    color: AurisTheme.success)),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(body,
                        style: const TextStyle(
                            fontSize: 13, height: 1.5, color: AurisTheme.muted)),
                    if (caveat != null) ...[
                      const SizedBox(height: 9),
                      Container(
                        padding: const EdgeInsets.all(9),
                        decoration: BoxDecoration(
                          color: AurisTheme.warningSurface,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(caveat!,
                            style: const TextStyle(
                                fontSize: 11.5,
                                height: 1.45,
                                color: AurisTheme.ink)),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}

class _NumberedStep extends StatelessWidget {
  const _NumberedStep(this.number, this.title, this.body);
  final int number;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 26,
              width: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AurisTheme.primary.withValues(alpha: 0.11),
              ),
              child: Text('$number',
                  style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: AurisTheme.primary)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: AurisTheme.ink)),
                  const SizedBox(height: 3),
                  Text(body,
                      style: const TextStyle(
                          fontSize: 13, height: 1.5, color: AurisTheme.muted)),
                ],
              ),
            ),
          ],
        ),
      );
}

class _BiologicalResult extends StatelessWidget {
  const _BiologicalResult({
    required this.measuredDbHl,
    required this.onApply,
    required this.onRetry,
  });

  final int measuredDbHl;
  final VoidCallback onApply;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    // A normal-hearing listener measuring far from 0 dB HL means the setup is
    // off by that much. A very large number usually means something else is
    // wrong - muted output, or a reference listener who is not normal-hearing.
    final implausible = measuredDbHl.abs() > 60;

    return Column(
      children: [
        AurisCard(
          child: Column(
            children: [
              const SectionLabel('Result'),
              const SizedBox(height: 10),
              Text(
                '$measuredDbHl dB HL',
                style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    color: AurisTheme.ink),
              ),
              const SizedBox(height: 8),
              Text(
                measuredDbHl.abs() <= 5
                    ? 'Your setup is already close to correct - little or no '
                        'adjustment needed.'
                    : 'A normal-hearing listener should measure near 0 dB HL. '
                        'Yours read $measuredDbHl, so Auris will shift '
                        'everything by ${measuredDbHl > 0 ? '+' : ''}$measuredDbHl dB '
                        'to compensate.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 13, height: 1.5, color: AurisTheme.muted),
              ),
            ],
          ),
        ),
        if (implausible) ...[
          const SizedBox(height: 12),
          const CalibrationWarning(
            message: 'That is a very large correction. Check the volume is up, '
                'the headphones are working, and the person being tested really '
                'does have normal hearing - before applying it.',
          ),
        ],
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: AurisOutlineButton(
                buttonName: 'Test again',
                icon: Icons.refresh_rounded,
                width: double.infinity,
                onTap: onRetry,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: AurisButton(
                buttonName: 'Apply',
                height: 52,
                width: double.infinity,
                onTap: onApply,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
