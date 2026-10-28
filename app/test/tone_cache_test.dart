import 'dart:io';
import 'dart:typed_data';

import 'package:auris/core/audio/tone_cache.dart';
import 'package:auris/core/audiometry/audiometry.dart';
import 'package:auris/core/audiometry/calibration.dart';
import 'package:auris/core/audiometry/tone_synth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('auris_tone_cache'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Directory cacheDir() => Directory(p.join(root.path, 'auris_tones'));

  int filesOnDisk() => cacheDir().existsSync()
      ? cacheDir().listSync().whereType<File>().length
      : 0;

  Uint8List blob([int bytes = 4096]) => Uint8List(bytes);

  group('bounding', () {
    test('never exceeds maxEntries, on disk as well as in memory', () async {
      final cache = ToneCache(maxEntries: 8);
      await cache.init(directory: root);

      for (var i = 0; i < 100; i++) {
        await cache.pathFor('stimulus-$i', blob);
      }

      expect(cache.entryCount, 8);
      expect(filesOnDisk(), 8,
          reason: 'evicted entries must be deleted, not just forgotten');
    });

    test('bounds the real footprint of a full two-ear test', () async {
      // The shape that would otherwise fill the disk: every frequency, both
      // ears, every 5 dB step - each a distinct file because the cache key
      // includes amplitude.
      const synth = ToneSynth();
      const calibration = CalibrationProfile();
      final cache = ToneCache(maxEntries: 24);
      await cache.init(directory: root);

      var generated = 0;
      for (final hz in kAudiometricFrequenciesHz) {
        for (final ear in Ear.values) {
          for (var db = kMinLevelDbHl; db <= kMaxLevelDbHl; db += 5) {
            final amplitude = calibration.amplitudeFor(hz, db);
            await cache.pathFor('tone_${hz}_${ear.name}_$db', () {
              generated++;
              return synth.tone(
                frequencyHz: hz.toDouble(),
                amplitude: amplitude,
                ear: ear,
                duration: const Duration(milliseconds: 100),
              );
            });
          }
        }
      }

      const levels = (kMaxLevelDbHl - kMinLevelDbHl) ~/ 5 + 1;
      expect(generated, kAudiometricFrequenciesHz.length * 2 * levels,
          reason: 'every frequency x 2 ears x every 5 dB level');
      expect(cache.entryCount, 24);
      // Unbounded, those 420 one-second tones would be ~145 MB. At 100 ms and
      // capped at 24 entries the cache stays under a megabyte.
      expect(cache.bytesOnDisk, lessThan(1024 * 1024));
    });

    test('evicts least-recently-used, not first-inserted', () async {
      final cache = ToneCache(maxEntries: 3);
      await cache.init(directory: root);

      await cache.pathFor('a', blob);
      await cache.pathFor('b', blob);
      await cache.pathFor('c', blob);

      // Touch 'a' so it is the most recent; 'b' becomes the eviction candidate.
      await cache.pathFor('a', blob);

      var regeneratedB = false;
      await cache.pathFor('d', blob); // evicts 'b'
      await cache.pathFor('b', () {
        regeneratedB = true;
        return blob();
      });
      expect(regeneratedB, isTrue, reason: 'b should have been evicted');

      var regeneratedA = false;
      await cache.pathFor('a', () {
        regeneratedA = true;
        return blob();
      });
      expect(regeneratedA, isFalse,
          reason: 'a was used recently and must have survived');
    });
  });

  group('reuse', () {
    test('a repeat hit does not regenerate or write another file', () async {
      final cache = ToneCache();
      await cache.init(directory: root);

      var generations = 0;
      Uint8List generate() {
        generations++;
        return blob();
      }

      final first = await cache.pathFor('tone', generate);
      for (var i = 0; i < 5; i++) {
        expect(await cache.pathFor('tone', generate), first);
      }

      expect(generations, 1);
      expect(filesOnDisk(), 1);
    });

    test('regenerates when the file vanished underneath it', () async {
      final cache = ToneCache();
      await cache.init(directory: root);

      final path = await cache.pathFor('tone', blob);
      File(path).deleteSync(); // e.g. the OS cleared temp

      var regenerated = false;
      await cache.pathFor('tone', () {
        regenerated = true;
        return blob();
      });
      expect(regenerated, isTrue);
      expect(filesOnDisk(), 1);
    });
  });

  group('cleanup', () {
    test('discardAll removes every file it owns', () async {
      final cache = ToneCache();
      await cache.init(directory: root);

      for (var i = 0; i < 5; i++) {
        await cache.pathFor('tone-$i', blob);
      }
      expect(filesOnDisk(), 5);

      cache.discardAll();
      expect(cache.entryCount, 0);
      expect(filesOnDisk(), 0);
    });

    test('startup reclaims files left by a crashed run', () async {
      cacheDir().createSync(recursive: true);

      final stale = File(p.join(cacheDir().path, 'stale.wav'))
        ..writeAsBytesSync(blob());
      stale.setLastModifiedSync(
          DateTime.now().subtract(const Duration(hours: 6)));

      final recent = File(p.join(cacheDir().path, 'recent.wav'))
        ..writeAsBytesSync(blob());

      final cache = ToneCache();
      await cache.init(directory: root);

      expect(stale.existsSync(), isFalse,
          reason: 'a crash must not leak tone files forever');
      expect(recent.existsSync(), isTrue,
          reason: 'a concurrently running player keeps its own files');
    });

    test('creates its directory when missing', () async {
      expect(cacheDir().existsSync(), isFalse);
      final cache = ToneCache();
      await cache.init(directory: root);
      expect(cacheDir().existsSync(), isTrue);
      expect(cache.isInitialised, isTrue);
    });
  });
}
