import 'package:shared_preferences/shared_preferences.dart';

import '../core/audiometry/audiometry.dart';

/// Choices on the test setup screen that rarely change between tests, so the
/// clinician does not have to enter them every time.
///
/// Stored on this device only, like the calibration they relate to.
class TestPreferences {
  TestPreferences._(this._prefs);

  static const _transducerKey = 'auris.test.transducerType';

  final SharedPreferences _prefs;

  static Future<TestPreferences> load() async =>
      TestPreferences._(await SharedPreferences.getInstance());

  TransducerType get transducerType {
    final raw = _prefs.getString(_transducerKey);
    return TransducerType.values.firstWhere(
      (t) => t.name == raw,
      orElse: () => TransducerType.headphones,
    );
  }

  Future<void> setTransducerType(TransducerType value) =>
      _prefs.setString(_transducerKey, value.name);
}
