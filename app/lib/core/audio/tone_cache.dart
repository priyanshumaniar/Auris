import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// An on-disk, size-bounded cache of generated audio files.
///
/// ## Why this is bounded
///
/// One second of stereo 32-bit float audio at 44.1 kHz is about 345 KB, and a
/// stimulus is identified by frequency, ear *and amplitude* - amplitude changes
/// at every 5 dB step. An unbounded cache would therefore write roughly 85 MB
/// over a full two-ear test and keep it until the app closed cleanly.
///
/// A threshold search revisits the same handful of levels around threshold,
/// though the random tone length means a repeat often needs a new file. Files
/// are therefore written ahead of time, during the gap before each tone (see
/// `TonePlayer.prepare`), and the bound only discards the long tail.
///
/// Deliberately independent of audio playback so it can be tested against a
/// real filesystem without an audio device or plugin.
class ToneCache {
  ToneCache({this.maxEntries = 24, this.staleAfter = const Duration(hours: 1)});

  /// Maximum number of files kept. ~24 files is roughly 8 MB.
  final int maxEntries;

  /// Files older than this are treated as leftovers from a run that did not
  /// shut down cleanly, and are swept on [init].
  final Duration staleAfter;

  static const _dirName = 'auris_tones';

  Directory? _dir;

  /// Insertion-ordered: the first key is the least recently used. Dart's map
  /// iteration order is what makes the eviction below correct.
  final Map<String, String> _files = {};

  bool get isInitialised => _dir != null;
  int get entryCount => _files.length;

  /// Total bytes this cache currently occupies. For diagnostics and tests.
  int get bytesOnDisk {
    var total = 0;
    for (final path in _files.values) {
      final file = File(path);
      if (file.existsSync()) total += file.lengthSync();
    }
    return total;
  }

  /// Prepares the cache directory and reclaims anything stale.
  ///
  /// [directory] overrides the system temporary directory; tests pass a
  /// throwaway folder so they never touch the real one.
  Future<void> init({Directory? directory}) async {
    final root = directory ?? await getTemporaryDirectory();
    _dir = Directory(p.join(root.path, _dirName));
    await _dir!.create(recursive: true);
    _sweepStale();
  }

  /// Returns the path of the file for [key], generating it via [generate] on a
  /// miss. [generate] is only called when there is no usable cached file.
  Future<String> pathFor(String key, Uint8List Function() generate) async {
    assert(isInitialised, 'call init() before using the cache');

    final cached = _files[key];
    if (cached != null && File(cached).existsSync()) {
      // Re-insert to mark it most-recently-used, so tones near threshold stay
      // resident and the one-off loud tones get evicted first.
      _files.remove(key);
      _files[key] = cached;
      return cached;
    }

    final file = File(p.join(_dir!.path, '${md5.convert(key.codeUnits)}.wav'));
    // No flush: the player reads the file back through the same file system
    // cache, and forcing it to disk only delays the tone.
    await file.writeAsBytes(generate());

    _files[key] = file.path;
    _evict();
    return file.path;
  }

  /// Deletes every file this cache owns.
  void discardAll() {
    for (final path in _files.values) {
      _deleteQuietly(path);
    }
    _files.clear();
  }

  void _evict() {
    while (_files.length > maxEntries) {
      final oldest = _files.keys.first;
      final path = _files.remove(oldest);
      if (path != null) _deleteQuietly(path);
    }
  }

  /// Removes files left behind by a previous run.
  ///
  /// [discardAll] normally cleans up, but a crash or force-quit skips it and
  /// those files would sit in temp indefinitely. Only files older than
  /// [staleAfter] go, so a second cache running concurrently keeps its own.
  void _sweepStale() {
    final dir = _dir;
    if (dir == null || !dir.existsSync()) return;

    final cutoff = DateTime.now().subtract(staleAfter);
    var reclaimed = 0;
    try {
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        if (entity.statSync().modified.isAfter(cutoff)) continue;
        reclaimed += entity.lengthSync();
        entity.deleteSync();
      }
    } catch (e) {
      debugPrint('Auris: could not sweep the tone cache - $e');
    }

    if (reclaimed > 0 && kDebugMode) {
      debugPrint('Auris: reclaimed '
          '${(reclaimed / 1048576).toStringAsFixed(1)} MB of stale tone cache.');
    }
  }

  void _deleteQuietly(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (e) {
      // Best effort - the next startup sweep will catch whatever is left.
      debugPrint('Auris: could not delete $path - $e');
    }
  }
}
