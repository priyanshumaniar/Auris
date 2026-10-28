/// Shared vocabulary for pure-tone audiometry.
///
/// Values and conventions follow the standard clinical test battery described in
/// ASHA's *Guidelines for Manual Pure-Tone Threshold Audiometry* (2005) and
/// ISO 8253-1. See `hughson_westlake.dart` for the threshold-search procedure.
library;

/// The ear under test. Air-conduction testing is always done one ear at a time.
enum Ear {
  right,
  left;

  String get label => this == Ear.right ? 'Right' : 'Left';

  /// Clinical audiogram convention: right ear is plotted with a red circle (O),
  /// left ear with a blue cross (X).
  String get marker => this == Ear.right ? 'O' : 'X';

  Ear get other => this == Ear.right ? Ear.left : Ear.right;
}

/// Every frequency Auris can test, in Hz, in *reporting* order: the
/// left-to-right order they appear on an audiogram.
///
/// 750 and 1500 Hz are interoctave frequencies, added only when the rule in
/// [interoctaveFrequenciesNeeded] calls for them.
const List<int> kAudiometricFrequenciesHz = [
  250, 500, 750, 1000, 1500, 2000, 3000, 4000, 6000, 8000,
];

/// The diagnostic air-conduction set tested on every ear, in Hz.
///
/// ASHA (2005) lists 250, 500, 1000, 2000, 3000, 4000, 6000 and 8000 Hz for
/// diagnostic air-conduction testing.
const List<int> kStandardFrequenciesHz = [
  250, 500, 1000, 2000, 3000, 4000, 6000, 8000,
];

/// The order frequencies are presented in during a test.
///
/// ASHA (2005): start at 1000 Hz, go up through 2000, 3000, 4000, 6000 and
/// 8000 Hz, retest 1000 Hz (first ear only), then 500 and 250 Hz. The retest is
/// inserted by the test runner, so it is not listed here.
const List<int> kTestOrderHz = [1000, 2000, 3000, 4000, 6000, 8000, 500, 250];

/// Largest acceptable difference between the first 1000 Hz threshold and its
/// retest, in dB. BSA (2018) and ASHA (2005) both use 5 dB.
const int kRetestToleranceDb = 5;

/// Interoctave rule from ASHA (2005): when adjacent octave thresholds between
/// 500 and 2000 Hz differ by 20 dB or more, test the frequency in between.
const int kInteroctaveDifferenceDb = 20;

/// The interoctave frequency between each octave pair the rule applies to.
const Map<int, (int, int)> kInteroctavePairs = {
  750: (500, 1000),
  1500: (1000, 2000),
};

/// Interoctave frequencies that [thresholds] call for, in reporting order.
///
/// [thresholds] maps frequency to threshold for one ear. A pair is only judged
/// when both of its octave thresholds are known numbers.
List<int> interoctaveFrequenciesNeeded(Map<int, int?> thresholds) => [
      for (final entry in kInteroctavePairs.entries)
        if (thresholds[entry.value.$1] != null &&
            thresholds[entry.value.$2] != null &&
            !thresholds.containsKey(entry.key) &&
            (thresholds[entry.value.$1]! - thresholds[entry.value.$2]!).abs() >=
                kInteroctaveDifferenceDb)
          entry.key,
    ];

/// Interaural attenuation used by the masking check, in dB.
///
/// BSA (2018) rule 1: masking is needed when the unmasked air-conduction
/// thresholds of the two ears differ by 40 dB or more with supra-aural or
/// circumaural earphones, or 55 dB or more with insert earphones.
enum TransducerType {
  /// Over-ear, on-ear and consumer in-ear headphones. Consumer in-ear
  /// earphones are not shown to attenuate like clinical insert earphones, so
  /// they use the cautious 40 dB value.
  headphones('Headphones (over-ear, on-ear or consumer in-ear)', 40),

  /// Clinical insert earphones with foam tips.
  insertEarphones('Clinical insert earphones', 55);

  const TransducerType(this.label, this.interauralAttenuationDb);

  final String label;
  final int interauralAttenuationDb;
}

/// Lowest level the audiometer will present, in dB HL.
///
/// Real clinical audiometers go to -10 dB HL. Whether an uncalibrated consumer
/// headphone can actually *reproduce* -10 dB HL is a separate question - see
/// the calibration disclaimer in the README.
const int kMinLevelDbHl = -10;

/// Highest level the audiometer will present, in dB HL.
///
/// Capped at 90 dB HL deliberately. Clinical audiometers reach 120 dB HL, but
/// this app drives uncalibrated consumer hardware where a mis-set system volume
/// at very high nominal levels risks real hearing damage.
const int kMaxLevelDbHl = 90;

/// Level the search starts at, in dB HL. Comfortably audible for normal hearing
/// without being startling.
const int kStartLevelDbHl = 30;

/// Step sizes for the modified Hughson-Westlake procedure ("down 10, up 5").
const int kDescendStepDb = 10;
const int kAscendStepDb = 5;

/// Shortest and longest tone, in milliseconds.
///
/// ASHA (2005) asks for tones of 1 to 2 seconds; BSA (2018) asks for the
/// duration to be varied (between 1 and 3 seconds). Varying it between 1 and
/// 2 seconds meets both. Durations are drawn in 250 ms steps so the tone
/// cache can reuse files.
const int kMinToneMs = 1000;
const int kMaxToneMs = 2000;
const int kToneStepMs = 250;

/// Default tone length, used by the headphone check and the calibration
/// wizard, which do not need varied durations.
const Duration kToneDuration = Duration(milliseconds: 1000);

/// Familiarisation level, in dB HL: about 40 dB HL for a listener with normal
/// hearing (BSA 2018). If it is not heard the level rises in 10 dB steps up to
/// [kFamiliarisationMaxDbHl], then in 5 dB steps.
const int kFamiliarisationLevelDbHl = 40;
const int kFamiliarisationMaxDbHl = 80;

/// Starting level for each new frequency, relative to the nearest threshold
/// already measured in that ear. BSA (2018): about 30 dB above it.
const int kStartAboveAdjacentDb = 30;

/// Lowest and highest starting level used for a new frequency, in dB HL.
const int kMinStartLevelDbHl = 20;
const int kMaxStartLevelDbHl = 80;

/// After this much testing a break is offered. BSA (2018): a subject may
/// benefit from a break when the test runs longer than 20 minutes.
const Duration kBreakAfter = Duration(minutes: 20);

/// Rise/fall envelope applied to each tone.
///
/// A tone switched on instantaneously produces a broadband click ("spectral
/// splatter") that a patient can hear even when the tone itself is below
/// threshold - it would corrupt every reading. ISO 389 requires a gradual
/// onset; 20 ms of raised-cosine ramp removes the click while keeping the tone
/// perceptually instantaneous.
const Duration kToneRampDuration = Duration(milliseconds: 20);

/// Pure-tone average (PTA) frequencies.
///
/// The PTA is the mean threshold at 500, 1000 and 2000 Hz - the "speech
/// frequencies". It is the number used to classify degree of hearing loss.
const List<int> kPtaFrequenciesHz = [500, 1000, 2000];

/// Short frequency label for charts and tables: 750, 1k, 1.5k, 8k.
String formatHzShort(int hz) => hz < 1000 ? '$hz' : '${_kilo(hz)}k';

/// Long frequency label: 750 Hz, 1 kHz, 1.5 kHz.
String formatHzLong(int hz) => hz < 1000 ? '$hz Hz' : '${_kilo(hz)} kHz';

String _kilo(int hz) => hz % 1000 == 0 ? '${hz ~/ 1000}' : '${hz / 1000}';
