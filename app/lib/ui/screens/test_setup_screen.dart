import 'package:flutter/material.dart';

import '../../core/audio/tone_player.dart';
import '../../core/audiometry/audiometry.dart';
import '../../data/models/patient.dart';
import '../../data/models/test_protocol.dart';
import '../../data/test_preferences.dart';
import '../../utils/route_constants.dart';
import '../app_scope.dart';
import '../theme.dart';
import '../widgets/auris_button.dart';
import '../widgets/calibration_by_ear.dart';

/// Which ear the patient says hears better. ASHA (2005) and BSA (2018) both
/// test the better ear first.
enum _BetterEar { right, left, notSure }

/// Everything to do before a test: headphone check, which ears and in what
/// order, the headphone type, the pre-test questions and confirmations, and
/// the instructions to read to the patient.
class TestSetupScreen extends StatefulWidget {
  const TestSetupScreen({super.key, required this.patient});

  final Patient patient;

  @override
  State<TestSetupScreen> createState() => _TestSetupScreenState();
}

class _TestSetupScreenState extends State<TestSetupScreen> {
  TonePlayer? _player;
  Ear? _checking;
  final Set<Ear> _confirmed = {};
  Set<Ear> _selectedEars = {Ear.right, Ear.left};
  _BetterEar _betterEar = _BetterEar.notSure;

  TestPreferences? _prefs;
  TransducerType _transducer = TransducerType.headphones;
  PreTestChecklist _checklist = const PreTestChecklist();
  final _reason = TextEditingController();

  /// Qualification and registration number, from the examiner's profile.
  String? _credentials;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCredentials());
  }

  Future<void> _loadPreferences() async {
    final prefs = await TestPreferences.load();
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _transducer = prefs.transducerType;
    });
  }

  /// Credentials come from the signed-in examiner's own profile, so on a
  /// shared device one person's qualification never prints on another's
  /// report.
  Future<void> _loadCredentials() async {
    String? fromProfile;
    try {
      fromProfile = await AppScope.of(context).account.credentials();
    } catch (_) {
      fromProfile = null;
    }
    if (!mounted) return;
    setState(() => _credentials = fromProfile);
  }

  Future<void> _openProfile() async {
    await Navigator.pushNamed(context, profileRoute);
    if (mounted) await _loadCredentials();
  }

  @override
  void dispose() {
    _player?.dispose();
    _reason.dispose();
    super.dispose();
  }

  TonePlayer _ensurePlayer() => _player ??= TonePlayer(
    calibration: AppScope.of(context).calibration.profile,
  );

  /// Plays a clearly audible 1 kHz tone in one ear so the clinician can verify
  /// the headphones are the right way round before any threshold is recorded.
  Future<void> _checkEar(Ear ear) async {
    setState(() => _checking = ear);
    try {
      await _ensurePlayer().present(
        frequencyHz: 1000,
        levelDbHl: 50,
        ear: ear,
        duration: const Duration(milliseconds: 1200),
      );
      if (!mounted) return;
      setState(() => _checking = null);
      // Playing the tone proves nothing; where the patient heard it does.
      final heardIn = await showDialog<Ear?>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Where did the patient hear it?'),
          content: Text('The tone was played in the ${ear.label.toLowerCase()} '
              'ear.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: const Text('Not heard'),
            ),
            for (final e in Ear.values)
              TextButton(
                onPressed: () => Navigator.pop(context, e),
                child: Text('${e.label} ear'),
              ),
          ],
        ),
      );
      if (!mounted) return;
      if (heardIn == ear) {
        setState(() => _confirmed.add(ear));
      } else {
        setState(() => _confirmed.remove(ear));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(heardIn == null
                ? 'Not heard. Check the headphones are plugged in and the '
                    'volume is up, then try again.'
                : 'Heard in the wrong ear. The headphones are on the wrong '
                    'way round: swap them and check both ears again.'),
          ),
        );
        if (heardIn != null) setState(_confirmed.clear);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not play the check tone: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _checking = null);
    }
  }

  /// The ears in test order: the better ear first, otherwise right first.
  List<Ear> get _earOrder {
    final ears = _selectedEars.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    if (ears.length == 2 && _betterEar == _BetterEar.left) {
      return const [Ear.left, Ear.right];
    }
    return ears;
  }

  bool get _earsChecked => _selectedEars.every(_confirmed.contains);

  bool get _ready =>
      _earsChecked &&
      _checklist.requiredConfirmed &&
      _checklist.questionsAnswered;

  /// True from the first tap on Start, so a double tap cannot open two tests.
  bool _starting = false;

  Future<void> _start() async {
    if (_starting) return;
    setState(() => _starting = true);
    final credentials = _credentials;
    await _prefs?.setTransducerType(_transducer);
    if (!mounted) return;

    final reason = _reason.text.trim();
    Navigator.pushReplacementNamed(
      context,
      testRunRoute,
      arguments: (
        patient: widget.patient,
        ears: _earOrder,
        protocol: TestProtocolRecord(
          earOrder: _earOrder,
          transducerType: _transducer,
          reasonForTest: reason.isEmpty ? null : reason,
          examinerCredentials: credentials,
          checklist: _checklist,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = AppScope.of(context).calibration.profile;
    final calibrated = profile.isCalibrated;
    // Base plan per ear, plus the 1 kHz retest in the first ear.
    final measurements = _selectedEars.length * kTestOrderHz.length + 1;

    return Scaffold(
      appBar: AppBar(title: const Text('Before you start')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          Text(
            widget.patient.fullName,
            style: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w600,
              color: AurisTheme.ink,
            ),
          ),
          Text(
            '${widget.patient.ageAt(DateTime.now())} years · '
            '${widget.patient.sex}',
            style: const TextStyle(fontSize: 13, color: AurisTheme.muted),
          ),
          const SizedBox(height: 18),
          if (!calibrated) ...[
            CalibrationWarning(
              message: calibrationStatusMessage(profile),
              onOpenSettings: () async {
                await Navigator.pushNamed(context, settingsRoute);
                if (mounted) setState(() {});
              },
            ),
            const SizedBox(height: 18),
          ],
          const SectionLabel('1 · Headphone check'),
          const SizedBox(height: 8),
          AurisCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Play a tone in each side and confirm the patient hears it in '
                  'the matching ear. Headphones worn the wrong way round would '
                  'mirror the whole audiogram.',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: AurisTheme.muted,
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    for (final ear in Ear.values) ...[
                      Expanded(
                        child: _EarCheckButton(
                          ear: ear,
                          busy: _checking == ear,
                          confirmed: _confirmed.contains(ear),
                          onTap: _checking == null
                              ? () => _checkEar(ear)
                              : null,
                        ),
                      ),
                      if (ear == Ear.right) const SizedBox(width: 10),
                    ],
                  ],
                ),
                const SizedBox(height: 16),
                const Text(
                  'Headphone type',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AurisTheme.ink,
                  ),
                ),
                const SizedBox(height: 10),
                Center(
                  child: SegmentedButton<TransducerType>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: TransducerType.headphones,
                        label: Text('Headphones'),
                      ),
                      ButtonSegment(
                        value: TransducerType.insertEarphones,
                        label: Text('Insert earphones'),
                      ),
                    ],
                    selected: {_transducer},
                    onSelectionChanged: (s) =>
                        setState(() => _transducer = s.first),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Headphones covers over-ear, on-ear and ordinary in-ear '
                  'earphones; insert earphones means clinical foam-tip '
                  'inserts. Used to decide when masking would be needed: when '
                  'the two ears differ by 40 dB or more with headphones, or '
                  '55 dB or more with insert earphones (BSA 2018).',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.45,
                    color: AurisTheme.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          const SectionLabel('2 · Ears to test'),
          const SizedBox(height: 8),
          AurisCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: SegmentedButton<Ear>(
                    multiSelectionEnabled: true,
                    emptySelectionAllowed: false,
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: Ear.right, label: Text('Right')),
                      ButtonSegment(value: Ear.left, label: Text('Left')),
                    ],
                    selected: _selectedEars,
                    onSelectionChanged: (selection) =>
                        setState(() => _selectedEars = selection),
                  ),
                ),
                if (_selectedEars.length == 2) ...[
                  const SizedBox(height: 14),
                  const Text(
                    'Which ear does the patient say hears better?',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AurisTheme.ink,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: SegmentedButton<_BetterEar>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: _BetterEar.right,
                          label: Text('Right'),
                        ),
                        ButtonSegment(
                          value: _BetterEar.left,
                          label: Text('Left'),
                        ),
                        ButtonSegment(
                          value: _BetterEar.notSure,
                          label: Text('Not sure'),
                        ),
                      ],
                      selected: {_betterEar},
                      onSelectionChanged: (s) =>
                          setState(() => _betterEar = s.first),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'The better ear is tested first. '
                    '${_earOrder.first.label} ear first.',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AurisTheme.muted,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Text(
                  'About $measurements measurements, roughly '
                  '${(measurements * 0.7).round()} to '
                  '${(measurements * 1.2).round()} minutes.',
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AurisTheme.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          const SectionLabel('3 · Ask the patient'),
          const SizedBox(height: 8),
          AurisCard(
            child: Column(
              children: [
                _YesNoQuestion(
                  question:
                      'In the last 24 hours, have you been somewhere so '
                      'loud you had to raise your voice to be heard?',
                  value: _checklist.loudNoiseLast24h,
                  onChanged: (v) => setState(
                    () => _checklist = _checklist.copyWith(loudNoiseLast24h: v),
                  ),
                ),
                const Divider(height: 22),
                _YesNoQuestion(
                  question:
                      'Do you have ringing or buzzing in your ears '
                      '(tinnitus)?',
                  value: _checklist.tinnitus,
                  onChanged: (v) => setState(
                    () => _checklist = _checklist.copyWith(tinnitus: v),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          const SectionLabel('4 · Instructions for the patient'),
          const SizedBox(height: 8),
          const AurisCard(
            child: Text(
              '"You will hear tones of different pitches, first in one ear '
              'and then in the other. We want to find the quietest tones you '
              'can hear. As soon as you hear a tone, however faint, press the '
              'button and keep holding it. Let go as soon as the tone stops. '
              'Some of the time there will be no tone at all, so only press '
              'when you hear one. Please sit still and keep quiet, and do not '
              'eat, drink or chew during the test. Do you have any '
              'questions?"',
              style: TextStyle(
                fontSize: 13.5,
                height: 1.6,
                fontStyle: FontStyle.italic,
                color: AurisTheme.ink,
              ),
            ),
          ),
          const SizedBox(height: 22),
          const SectionLabel('5 · Confirm'),
          const SizedBox(height: 8),
          AurisCard(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
            child: Column(
              children: [
                _Confirm(
                  label:
                      'Hearing aids, glasses and headwear removed '
                      '(after giving the instructions)',
                  value: _checklist.hearingAidsRemoved,
                  onChanged: (v) => setState(
                    () =>
                        _checklist = _checklist.copyWith(hearingAidsRemoved: v),
                  ),
                ),
                _Confirm(
                  label: 'Phones and other devices silenced',
                  value: _checklist.phonesSilenced,
                  onChanged: (v) => setState(
                    () => _checklist = _checklist.copyWith(phonesSilenced: v),
                  ),
                ),
                _Confirm(
                  label: 'Quietest room available, door closed',
                  value: _checklist.quietRoom,
                  onChanged: (v) => setState(
                    () => _checklist = _checklist.copyWith(quietRoom: v),
                  ),
                ),
                _Confirm(
                  label: 'Ear canals looked at and clear (optional)',
                  value: _checklist.earsChecked,
                  onChanged: (v) => setState(
                    () => _checklist = _checklist.copyWith(earsChecked: v),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          const AurisCard(
            padding: EdgeInsets.all(13),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.visibility_off_outlined,
                  size: 18,
                  color: AurisTheme.muted,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Keep the screen out of the patient\'s view. A patient who '
                    'can see the level responds to the number, not the tone.',
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.5,
                      color: AurisTheme.muted,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          const SectionLabel('6 · For the report (optional)'),
          const SizedBox(height: 8),
          AurisCard(
            child: Column(
              children: [
                TextField(
                  controller: _reason,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Reason for the test',
                    hintText: 'e.g. referred for hearing difficulty',
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.badge_outlined,
                        size: 19, color: AurisTheme.muted),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _credentials == null
                            ? 'No qualification in your profile. Add it so '
                                'reports show who tested and how qualified '
                                'they are.'
                            : 'Examiner on the report: $_credentials',
                        style: const TextStyle(
                            fontSize: 12.5,
                            height: 1.4,
                            color: AurisTheme.muted),
                      ),
                    ),
                    TextButton(
                      onPressed: _openProfile,
                      child: Text(_credentials == null ? 'Add' : 'Edit'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 26),
          if (!_ready)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                'Check each ear being tested with the headphone check, answer '
                'both questions and tick the first three confirmations to '
                'start.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: AurisTheme.muted),
              ),
            ),
          Center(
            child: AurisButton(
              buttonName: 'Start test',
              width: 240,
              busy: _starting,
              onTap: _ready ? _start : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _YesNoQuestion extends StatelessWidget {
  const _YesNoQuestion({
    required this.question,
    required this.value,
    required this.onChanged,
  });

  final String question;
  final bool? value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        question,
        style: const TextStyle(
          fontSize: 13,
          height: 1.45,
          color: AurisTheme.ink,
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          ChoiceChip(
            label: const Text('No'),
            selected: value == false,
            onSelected: (_) => onChanged(false),
          ),
          const SizedBox(width: 8),
          ChoiceChip(
            label: const Text('Yes'),
            selected: value == true,
            onSelected: (_) => onChanged(true),
          ),
        ],
      ),
    ],
  );
}

class _Confirm extends StatelessWidget {
  const _Confirm({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => CheckboxListTile(
    value: value,
    dense: true,
    controlAffinity: ListTileControlAffinity.leading,
    contentPadding: EdgeInsets.zero,
    title: Text(label, style: const TextStyle(fontSize: 13)),
    onChanged: (v) => onChanged(v ?? false),
  );
}

class _EarCheckButton extends StatelessWidget {
  const _EarCheckButton({
    required this.ear,
    required this.busy,
    required this.confirmed,
    required this.onTap,
  });

  final Ear ear;
  final bool busy;
  final bool confirmed;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = ear == Ear.right ? AurisTheme.rightEar : AurisTheme.leftEar;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: confirmed
                ? AurisTheme.success
                : color.withValues(alpha: 0.5),
            width: 1.4,
          ),
          color: confirmed
              ? AurisTheme.success.withValues(alpha: 0.07)
              : color.withValues(alpha: 0.04),
        ),
        child: Column(
          children: [
            if (busy)
              const SizedBox(
                height: 22,
                width: 22,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              )
            else
              Icon(
                confirmed
                    ? Icons.check_circle_rounded
                    : Icons.play_arrow_rounded,
                color: confirmed ? AurisTheme.success : color,
                size: 22,
              ),
            const SizedBox(height: 6),
            Text(
              '${ear.label} ear',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: confirmed ? AurisTheme.success : color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
