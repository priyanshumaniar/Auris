import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'calibration.dart';

/// Persists the device's [CalibrationProfile].
///
/// Calibration belongs to the *device and headphone pair*, not to the clinic or
/// the patient, so it is stored locally and never synced.
class CalibrationStore extends ChangeNotifier {
  CalibrationStore._(this._prefs, this._profile);

  static const _key = 'auris.calibration.v1';

  final SharedPreferences _prefs;
  CalibrationProfile _profile;

  CalibrationProfile get profile => _profile;

  static Future<CalibrationStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);

    var profile = const CalibrationProfile();
    if (raw != null) {
      try {
        profile = CalibrationProfile.decode(raw);
      } catch (e) {
        // FormatException for broken JSON, TypeError for JSON of the wrong shape.
        // Never let a corrupt preference block the app; fall back to
        // uncalibrated, which is the safe default.
        debugPrint('Auris: discarding unreadable calibration profile - $e');
      }
    }
    return CalibrationStore._(prefs, profile);
  }

  Future<void> save(CalibrationProfile profile) async {
    _profile = profile;
    await _prefs.setString(_key, profile.encode());
    notifyListeners();
  }

  Future<void> reset() => save(const CalibrationProfile());
}
