import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../audiometry/audiometry.dart';
import '../audiometry/calibration.dart';
import '../audiometry/tone_synth.dart';
import 'tone_cache.dart';

/// Presents calibrated pure tones to one ear.
///
/// Synthesis is done by [ToneSynth]; this class handles the device side -
/// writing the WAV to a cache file and driving the platform audio player.
class TonePlayer {
  TonePlayer({
    ToneSynth synth = const ToneSynth(),
    CalibrationProfile calibration = const CalibrationProfile(),
    AudioPlayer? player,
    ToneCache? cache,
  })  : _synth = synth,
        _calibration = calibration,
        _player = player ?? AudioPlayer(),
        _cache = cache ?? ToneCache();

  ToneSynth _synth;
  final AudioPlayer _player;

  /// Bounded on-disk store for generated WAVs. See [ToneCache] for why it has
  /// to be bounded.
  final ToneCache _cache;

  CalibrationProfile _calibration;
  bool _initialised = false;

  /// Set once we have fallen back from float32 to 16-bit PCM.
  bool _usingFallbackFormat = false;

  /// True when this player had to drop to 16-bit because the platform would
  /// not play float32 WAV. Surfaced so a caller can warn that the quietest
  /// levels are now quantisation-limited.
  bool get usingFallbackFormat => _usingFallbackFormat;

  CalibrationProfile get calibration => _calibration;

  /// Swapping calibration invalidates every cached WAV, since the amplitude of
  /// each cached tone was computed under the old profile.
  set calibration(CalibrationProfile value) {
    if (value.encode() == _calibration.encode()) return;
    _calibration = value;
    _cache.discardAll();
  }

  /// [cacheDirectory] overrides the system temp directory; tests pass a
  /// throwaway folder.
  Future<void> init({Directory? cacheDirectory}) async {
    if (_initialised) return;
    await _cache.init(directory: cacheDirectory);
    // The digital amplitude *is* the level control - the player must never
    // scale it, or every threshold would be wrong by the player's volume.
    await _player.setVolume(1.0);
    await _player.setReleaseMode(ReleaseMode.stop);
    _initialised = true;
  }

  /// Writes the file for a stimulus ahead of time, so [present] can start it
  /// at once. Called during the gap before the stimulus.
  Future<void> prepare({
    required int frequencyHz,
    required num levelDbHl,
    required Ear ear,
    bool silent = false,
    Duration duration = kToneDuration,
  }) async {
    await init();
    await _fileFor(
      frequencyHz: frequencyHz,
      levelDbHl: levelDbHl,
      ear: ear,
      silent: silent,
      duration: duration,
    );
  }

  /// Plays one tone and returns when playback has finished.
  ///
  /// When [silent] is true a same-length silent file is played instead - the
  /// catch trial. It must go through exactly the same path as a real tone so
  /// there is no timing or device cue that gives it away.
  Future<void> present({
    required int frequencyHz,
    required num levelDbHl,
    required Ear ear,
    bool silent = false,
    Duration duration = kToneDuration,
  }) async {
    await init();

    try {
      await _playOnce(
        frequencyHz: frequencyHz,
        levelDbHl: levelDbHl,
        ear: ear,
        silent: silent,
        duration: duration,
      );
    } on Exception catch (e) {
      // Not every platform audio backend decodes 32-bit float WAV. If the
      // first attempt fails outright, drop to 16-bit PCM and retry rather than
      // aborting a test that is already under way. This costs dynamic range at
      // the quietest levels, which is why float32 is tried first.
      //
      // Deliberately `on Exception`, not a bare `catch`: an Error (a bug in
      // this code) must surface rather than silently degrade every subsequent
      // tone to 16-bit. That is exactly what a bare catch did here once.
      if (_usingFallbackFormat || _synth.format == PcmFormat.int16) rethrow;

      if (kDebugMode) {
        debugPrint('Auris: float32 playback failed ($e); '
            'falling back to 16-bit PCM for this session.');
      }
      _usingFallbackFormat = true;
      _synth = ToneSynth(sampleRate: _synth.sampleRate, format: PcmFormat.int16);
      _cache.discardAll();

      await _playOnce(
        frequencyHz: frequencyHz,
        levelDbHl: levelDbHl,
        ear: ear,
        silent: silent,
        duration: duration,
      );
    }
  }

  Future<void> _playOnce({
    required int frequencyHz,
    required num levelDbHl,
    required Ear ear,
    required bool silent,
    required Duration duration,
  }) async {
    final path = await _fileFor(
      frequencyHz: frequencyHz,
      levelDbHl: levelDbHl,
      ear: ear,
      silent: silent,
      duration: duration,
    );

    await _player.stop();
    await _player.play(DeviceFileSource(path), volume: 1.0);

    // Wait for the platform to report completion, but never hang the test if
    // the event is missed - fall back to the known tone duration.
    //
    // No `onTimeout:` callback here on purpose. `onPlayerComplete` is declared
    // as Stream<void> but is really a filtered Stream<AudioEvent>, so at
    // runtime `.first` is a Future<AudioEvent> and any onTimeout callback must
    // return an AudioEvent - a callback returning null type-checks at compile
    // time and then throws. Catching TimeoutException sidesteps that entirely.
    try {
      await _player.onPlayerComplete.first
          .timeout(duration + const Duration(milliseconds: 750));
    } on TimeoutException {
      // The platform never reported completion. The tone has finished by wall
      // clock, so carry on rather than stalling the test.
    }
  }

  Future<void> stop() async {
    if (!_initialised) return;
    await _player.stop();
  }

  Future<void> dispose() async {
    await _player.dispose();
    _cache.discardAll();
  }

  /// Returns a WAV path for this stimulus, generating and caching it if needed.
  Future<String> _fileFor({
    required int frequencyHz,
    required num levelDbHl,
    required Ear ear,
    required bool silent,
    required Duration duration,
  }) async {
    final amplitude =
        silent ? 0.0 : _calibration.amplitudeFor(frequencyHz, levelDbHl, ear: ear);

    // Key on what actually determines the samples, so a calibration change or a
    // different duration can never collide with a stale file.
    final key = silent
        ? 'silence_${_synth.format.name}_${duration.inMilliseconds}'
        : 'tone_${_synth.format.name}_${frequencyHz}_${ear.name}'
            '_${amplitude.toStringAsExponential(6)}_${duration.inMilliseconds}';
    // The cache generates on a miss only; synthesis is skipped on a hit.
    return _cache.pathFor(
      key,
      () => silent
          ? _synth.silence(duration: duration)
          : _synth.tone(
              frequencyHz: frequencyHz.toDouble(),
              amplitude: amplitude,
              ear: ear,
              duration: duration,
            ),
    );
  }
}
