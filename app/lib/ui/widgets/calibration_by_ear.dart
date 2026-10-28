import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/audiometry/audiometry.dart';
import '../../core/audiometry/calibration.dart';
import '../theme.dart';

final _date = DateFormat('d MMM yyyy');

/// "Biological check, measured 22 Oct 2026" or "Not calibrated".
String describeEarCalibration(EarCalibration e, Ear ear) {
  if (!e.hasCalibration) return 'Not calibrated';
  final how = e.isCopied
      ? 'copied from the ${ear.other.label.toLowerCase()} ear'
      : 'measured';
  final when = e.calibratedAt == null ? '' : ', ${_date.format(e.calibratedAt!)}';
  return '${e.method.label}, $how$when';
}

/// One row per ear showing how it is calibrated, in the ear's colour.
class CalibrationByEar extends StatelessWidget {
  const CalibrationByEar({super.key, required this.profile});

  final CalibrationProfile profile;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final ear in Ear.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 52,
                    child: Text(
                      ear.label,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: ear == Ear.right
                            ? AurisTheme.rightEar
                            : AurisTheme.leftEar,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      describeEarCalibration(profile.ear(ear), ear),
                      style: const TextStyle(
                          fontSize: 12.5, height: 1.4, color: AurisTheme.ink),
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
}

/// The standing warning for calibration done with a human listener.
class HumanCalibrationNotice extends StatelessWidget {
  const HumanCalibrationNotice({super.key});

  @override
  Widget build(BuildContext context) =>
      const CalibrationWarning(message: kHumanCalibrationWarning);
}

/// The banner text for a device that is not fully meter-calibrated.
///
/// Uncalibrated, one ear only, and calibrated with a human listener are
/// different situations and must not all read as "not calibrated".
String calibrationStatusMessage(CalibrationProfile profile) {
  if (!profile.hasAnyCalibration) {
    return 'This device is not calibrated. The shape of the audiogram is '
        'meaningful, but absolute dB HL values are not. Treat results as '
        'screening only.';
  }
  if (profile.method == CalibrationMethod.none) {
    const oneEar = 'Only one ear of this device is calibrated. Results for '
        'the other ear are screening only.';
    // The calibrated ear may itself have been set with a listener, which
    // needs its own warning.
    return profile.usesHumanListener
        ? '$oneEar $kHumanCalibrationWarning'
        : oneEar;
  }
  if (profile.usesHumanListener) return kHumanCalibrationWarning;
  return 'This device is not fully calibrated against a sound level meter.';
}
