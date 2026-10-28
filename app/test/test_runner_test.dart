import 'dart:math';

import 'package:auris/core/audiometry/audiometry.dart';
import 'package:auris/core/audiometry/test_runner.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stimulus as the runner delivered it.
typedef Delivered = ({
  int hz,
  num level,
  Ear ear,
  bool silent,
  Duration duration,
});

/// A simulated patient: does this ear hear this tone at this level? [count]
/// is how many tones at this ear and frequency came before, so a patient can
/// change between a measurement and its retest.
typedef Hears = bool Function(Ear ear, int hz, num level, int count);

/// Builds a runner wired to a simulated patient with the given per-ear
/// thresholds. Delays are collapsed to zero so the suite stays fast.
///
/// Familiarisation, the 1000 Hz retest, interoctave frequencies and breaks
/// are off by default so the sequencing tests stay simple; each has its own
/// group below.
({AudiometryTestRunner runner, List<Delivered> delivered}) buildRunner({
  Map<Ear, int> trueThresholds = const {},
  Hears? hears,
  List<Ear> ears = const [Ear.right, Ear.left],
  List<int> frequencies = const [1000, 4000],
  double catchTrialProbability = 0.0,
  bool respondToSilence = false,
  // Off by default here so the sequencing tests run without a UI to press
  // "continue"; the changeover itself is covered in its own group.
  bool pauseBetweenEars = false,
  bool familiarise = false,
  bool retestFirstEar = false,
  bool addInteroctave = false,
  Duration? breakAfter,
  int minToneMs = 1000,
  int maxToneMs = 2000,
  bool hold = false,
  Duration toneTime = Duration.zero,
  MaxLevelFor? maxLevelFor,
}) {
  final delivered = <Delivered>[];
  final counts = <String, int>{};
  late AudiometryTestRunner runner;

  runner = AudiometryTestRunner(
    ears: ears,
    frequencies: frequencies,
    catchTrialProbability: catchTrialProbability,
    pauseBetweenEars: pauseBetweenEars,
    familiarise: familiarise,
    retestFirstEar: retestFirstEar,
    addInteroctave: addInteroctave,
    breakAfter: breakAfter,
    minToneMs: minToneMs,
    maxToneMs: maxToneMs,
    minInterStimulusGap: Duration.zero,
    maxInterStimulusGap: Duration.zero,
    responseWindow: const Duration(milliseconds: 1),
    releaseWait: const Duration(milliseconds: 200),
    random: Random(20260810),
    maxLevelFor: maxLevelFor,
    present: ({
      required int frequencyHz,
      required num levelDbHl,
      required Ear ear,
      required bool silent,
      required Duration duration,
    }) async {
      delivered.add((
        hz: frequencyHz,
        level: levelDbHl,
        ear: ear,
        silent: silent,
        duration: duration,
      ));
      final key = '${ear.name}/$frequencyHz';
      final count = counts[key] = (counts[key] ?? 0) + 1;
      final heard = silent
          ? respondToSilence
          : (hears?.call(ear, frequencyHz, levelDbHl, count - 1) ??
              levelDbHl >= trueThresholds[ear]!);
      if (!heard) {
        if (toneTime > Duration.zero) await Future<void>.delayed(toneTime);
        return;
      }
      // The response gate is armed before the stimulus plays, so a patient
      // responding "during the tone" is exactly this.
      if (hold) {
        runner.press();
        if (toneTime > Duration.zero) await Future<void>.delayed(toneTime);
        // Let go just after the tone ends.
        Future<void>.delayed(const Duration(milliseconds: 5), runner.release);
      } else {
        runner.respond();
        if (toneTime > Duration.zero) await Future<void>.delayed(toneTime);
      }
    },
  );

  return (runner: runner, delivered: delivered);
}

/// The order frequencies were delivered in, with repeats collapsed.
List<int> frequencyOrder(List<Delivered> delivered, {Ear? ear}) {
  final order = <int>[];
  for (final d in delivered) {
    if (ear != null && d.ear != ear) continue;
    if (order.isEmpty || order.last != d.hz) order.add(d.hz);
  }
  return order;
}

void main() {
  group('sequencing', () {
    test('tests every ear at every frequency', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 20, Ear.left: 35},
        frequencies: const [1000, 2000, 4000],
      );
      final points = await h.runner.run();

      expect(h.runner.phase, TestPhase.complete);
      expect(points, hasLength(6)); // 2 ears x 3 frequencies
      expect(points.where((p) => p.ear == Ear.right), hasLength(3));
      expect(points.where((p) => p.ear == Ear.left), hasLength(3));
      expect(h.runner.progress, 1.0);
    });

    test('finishes one ear before starting the other', () async {
      final h = buildRunner(trueThresholds: {Ear.right: 20, Ear.left: 20});
      await h.runner.run();

      final earOrder = h.delivered.map((d) => d.ear).toList();
      final firstLeft = earOrder.indexOf(Ear.left);
      final lastRight = earOrder.lastIndexOf(Ear.right);
      expect(firstLeft, greaterThan(lastRight),
          reason: 'ears must not be interleaved');
    });

    test('presents frequencies in the configured order', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 20},
        ears: const [Ear.right],
        frequencies: const [1000, 4000, 250],
      );
      await h.runner.run();

      expect(frequencyOrder(h.delivered), [1000, 4000, 250]);
    });

    test('routes every stimulus to the ear under test', () async {
      final h = buildRunner(
        trueThresholds: {Ear.left: 25},
        ears: const [Ear.left],
      );
      await h.runner.run();

      expect(h.delivered.every((d) => d.ear == Ear.left), isTrue);
    });
  });

  group('measurement', () {
    test('records the simulated threshold for each ear', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 15, Ear.left: 45},
        frequencies: const [1000],
      );
      final points = await h.runner.run();

      expect(
        points.firstWhere((p) => p.ear == Ear.right).thresholdDbHl,
        15,
      );
      expect(
        points.firstWhere((p) => p.ear == Ear.left).thresholdDbHl,
        45,
      );
      expect(points.every((p) => p.noResponse == false), isTrue);
    });

    test('records a no-response when the patient never hears', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 9999},
        ears: const [Ear.right],
        frequencies: const [1000],
      );
      final points = await h.runner.run();

      expect(points.single.noResponse, isTrue);
      expect(points.single.thresholdDbHl, isNull);
    });

    test('counts tone presentations per point', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 20},
        ears: const [Ear.right],
        frequencies: const [1000],
      );
      final points = await h.runner.run();

      expect(points.single.tonesPresented, greaterThan(0));
      expect(points.single.tonesPresented,
          h.delivered.where((d) => !d.silent).length);
    });
  });

  group('catch trials', () {
    test('delivers silent stimuli and scores false positives', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 20},
        ears: const [Ear.right],
        frequencies: const [1000],
        catchTrialProbability: 0.5,
        respondToSilence: true,
      );
      final points = await h.runner.run();

      expect(h.delivered.any((d) => d.silent), isTrue,
          reason: 'catch trials must actually reach the audio layer');
      expect(points.single.catchTrials, greaterThan(0));
      expect(points.single.falsePositives, points.single.catchTrials);
    });

    test('an honest patient records no false positives', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 20},
        ears: const [Ear.right],
        frequencies: const [1000],
        catchTrialProbability: 0.5,
      );
      final points = await h.runner.run();

      expect(points.single.falsePositives, 0);
    });
  });

  group('ear changeover', () {
    test('stops between ears and waits to be released', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 20, Ear.left: 20},
        frequencies: const [1000],
        pauseBetweenEars: true,
      );

      var reachedChangeover = false;
      h.runner.addListener(() {
        if (h.runner.phase == TestPhase.earChangeover && !reachedChangeover) {
          reachedChangeover = true;
          // The patient has a moment to reseat the headphones; nothing should
          // be presented until they say they are ready.
          expect(h.runner.finishedEar, Ear.right);
          expect(h.delivered.every((d) => d.ear == Ear.right), isTrue,
              reason: 'the second ear must not start on its own');
          h.runner.continueToNextEar();
        }
      });

      final points = await h.runner.run();
      expect(reachedChangeover, isTrue);
      expect(points, hasLength(2));
      expect(h.runner.phase, TestPhase.complete);
    });

    test('does not pause when there is only one ear', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 20},
        ears: const [Ear.right],
        frequencies: const [1000],
        pauseBetweenEars: true,
      );

      var sawChangeover = false;
      h.runner.addListener(() {
        if (h.runner.phase == TestPhase.earChangeover) sawChangeover = true;
      });

      await h.runner.run();
      expect(sawChangeover, isFalse);
    });

    test('aborting while waiting at the changeover ends the test', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 20, Ear.left: 20},
        frequencies: const [1000],
        pauseBetweenEars: true,
      );

      h.runner.addListener(() {
        if (h.runner.phase == TestPhase.earChangeover) h.runner.abort();
      });

      final points = await h.runner.run();
      expect(h.runner.phase, TestPhase.aborted);
      expect(points, hasLength(1), reason: 'only the first ear completed');
    });
  });

  group('timing', () {
    test('records how long each threshold took', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 20},
        ears: const [Ear.right],
        frequencies: const [1000, 2000],
      );
      await h.runner.run();

      // Feeds the "time remaining" estimate the patient sees.
      expect(h.runner.thresholdDurations, hasLength(2));
      expect(h.runner.thresholdDurations.every((d) => d >= Duration.zero),
          isTrue);
    });
  });

  group('control', () {
    test('abort stops the test and marks it aborted', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 20, Ear.left: 20},
        frequencies: const [1000, 2000, 4000],
      );

      // Abort as soon as the second frequency begins.
      h.runner.addListener(() {
        if (h.runner.currentFrequencyHz == 2000) h.runner.abort();
      });

      final points = await h.runner.run();
      expect(h.runner.phase, TestPhase.aborted);
      expect(points.length, lessThan(6));
    });

    test('a runner cannot be reused', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 20},
        ears: const [Ear.right],
        frequencies: const [1000],
      );
      await h.runner.run();
      expect(h.runner.run, throwsStateError);
    });

    test('notifies listeners as it progresses', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 20},
        ears: const [Ear.right],
        frequencies: const [1000, 2000],
      );
      var notifications = 0;
      h.runner.addListener(() => notifications++);

      await h.runner.run();
      expect(notifications, greaterThan(0));
    });

    test('responding outside a response window is ignored', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 20},
        ears: const [Ear.right],
        frequencies: const [1000],
      );
      // No stimulus is in flight, so this must not throw or be buffered.
      expect(h.runner.respond, returnsNormally);
      final points = await h.runner.run();
      expect(points.single.thresholdDbHl, 20);
    });
  });

  group('tone timing', () {
    test('tone lengths vary in 250 ms steps between 1 and 2 seconds', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 20},
        ears: const [Ear.right],
        frequencies: const [1000, 2000, 4000],
      );
      await h.runner.run();

      final lengths = h.delivered.map((d) => d.duration.inMilliseconds).toSet();
      expect(lengths.length, greaterThan(1), reason: 'durations must vary');
      for (final ms in lengths) {
        expect(ms, inInclusiveRange(1000, 2000));
        expect(ms % 250, 0);
      }
    });
  });

  group('starting level', () {
    test('starts 30 dB above the nearest threshold already measured', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 20},
        ears: const [Ear.right],
        frequencies: const [1000, 2000],
      );
      await h.runner.run();

      final first2k = h.delivered.firstWhere((d) => d.hz == 2000);
      expect(first2k.level, 50);
    });
  });

  group('1 kHz retest', () {
    test('retests 1 kHz after the high frequencies in the first ear only',
        () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 20, Ear.left: 20},
        frequencies: const [1000, 2000, 4000, 500],
        retestFirstEar: true,
      );
      final points = await h.runner.run();

      expect(frequencyOrder(h.delivered, ear: Ear.right),
          [1000, 2000, 4000, 1000, 500]);
      expect(frequencyOrder(h.delivered, ear: Ear.left),
          [1000, 2000, 4000, 500]);
      expect(points, hasLength(8), reason: 'the retest updates, not adds');

      final retests = h.runner.protocolRecord.retests;
      expect(retests, hasLength(1));
      expect(retests.single.withinTolerance, isTrue);
    });

    test('a retest more than 5 dB away is flagged and widens the retest',
        () async {
      // The right ear hears 1 kHz at 40 dB the first time and 20 dB on the
      // retest: a 20 dB disagreement.
      final h = buildRunner(
        hears: (ear, hz, level, count) {
          if (ear == Ear.right && hz == 1000) {
            return level >= (count < 12 ? 40 : 20);
          }
          return level >= 20;
        },
        frequencies: const [1000, 2000, 500],
        retestFirstEar: true,
      );
      final points = await h.runner.run();
      final record = h.runner.protocolRecord;

      final failed = record.failedRetests;
      expect(failed, isNotEmpty);
      expect(failed.first.frequencyHz, 1000);
      expect(record.retests.any((r) => r.frequencyHz == 2000), isTrue,
          reason: 'ASHA: retest at least one other frequency');
      expect(frequencyOrder(h.delivered, ear: Ear.left).first, 1000);
      expect(
          frequencyOrder(h.delivered, ear: Ear.left)
              .where((hz) => hz == 1000)
              .length,
          2,
          reason: 'the second ear gets a retest too after a failed one');

      final right1k = points
          .firstWhere((p) => p.ear == Ear.right && p.frequencyHz == 1000);
      expect(right1k.thresholdDbHl, 20, reason: 'the lower value is kept');
    });
  });

  group('interoctave frequencies', () {
    test('adds 750 Hz when 500 and 1000 Hz differ by 20 dB or more', () async {
      final h = buildRunner(
        hears: (ear, hz, level, count) => level >= (hz <= 500 ? 10 : 40),
        ears: const [Ear.right],
        frequencies: const [1000, 2000, 500],
        addInteroctave: true,
      );
      final points = await h.runner.run();

      expect(points.map((p) => p.frequencyHz), contains(750));
      expect(points.map((p) => p.frequencyHz), isNot(contains(1500)));
      expect(h.runner.protocolRecord.interoctaveAdded.single.frequencyHz, 750);
    });

    test('adds nothing when the octaves are within 20 dB', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 20},
        ears: const [Ear.right],
        frequencies: const [1000, 2000, 500],
        addInteroctave: true,
      );
      final points = await h.runner.run();
      expect(points, hasLength(3));
    });
  });

  group('presses between tones', () {
    test('are counted per ear and do not count as responses', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 20},
        ears: const [Ear.right],
        frequencies: const [1000],
      );
      var gapPresses = 0;
      h.runner.addListener(() {
        if (h.runner.phase == TestPhase.interStimulus && gapPresses < 3) {
          gapPresses++;
          h.runner.respond();
        }
      });
      final points = await h.runner.run();

      expect(h.runner.protocolRecord.pressesBetweenTones[Ear.right], 3);
      expect(points.single.thresholdDbHl, 20,
          reason: 'presses in the gap must not move the search');
    });
  });

  group('familiarisation', () {
    test('a patient who presses and holds passes first time', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 20},
        ears: const [Ear.right],
        frequencies: const [1000],
        familiarise: true,
        hold: true,
        minToneMs: 300,
        maxToneMs: 300,
        toneTime: const Duration(milliseconds: 300),
      );
      await h.runner.run();

      final outcome = h.runner.protocolRecord.familiarisation!;
      expect(outcome.heard, isTrue);
      expect(outcome.onsetOffsetMatched, isTrue);
      expect(outcome.reinstructed, isFalse);
      expect(outcome.levelDbHl, kFamiliarisationLevelDbHl);
      expect(h.delivered.first.level, kFamiliarisationLevelDbHl);
    });

    test('a patient who only taps is re-instructed once, then the test goes on',
        () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 20},
        ears: const [Ear.right],
        frequencies: const [1000],
        familiarise: true,
        minToneMs: 300,
        maxToneMs: 300,
        toneTime: const Duration(milliseconds: 300),
      );
      var gates = 0;
      h.runner.addListener(() {
        if (h.runner.phase == TestPhase.reinstruct) {
          gates++;
          h.runner.continueAfterReinstruction();
        }
      });
      final points = await h.runner.run();

      final outcome = h.runner.protocolRecord.familiarisation!;
      expect(gates, 1);
      expect(outcome.reinstructed, isTrue);
      expect(outcome.onsetOffsetMatched, isFalse);
      expect(points.single.thresholdDbHl, 20);
    });

    test('raises the level until the patient responds', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 65},
        ears: const [Ear.right],
        frequencies: const [1000],
        familiarise: true,
        hold: true,
        minToneMs: 300,
        maxToneMs: 300,
        toneTime: const Duration(milliseconds: 300),
      );
      final points = await h.runner.run();

      final outcome = h.runner.protocolRecord.familiarisation!;
      expect(outcome.levelDbHl, 70, reason: '40, 50, 60, 70');
      expect(points.single.thresholdDbHl, 65);
    });
  });

  group('pausing mid-tone', () {
    test('a trial cut short by a pause is presented again, not scored',
        () async {
      late AudiometryTestRunner runner;
      var paused = false;
      final h = buildRunner(
        ears: const [Ear.right],
        frequencies: const [1000],
        hears: (ear, hz, level, count) {
          if (count == 2 && !paused) {
            // The app goes to the background while this tone plays.
            paused = true;
            runner.pause();
            Future<void>.delayed(
                const Duration(milliseconds: 20), runner.resume);
            return false;
          }
          return level >= 20;
        },
      );
      runner = h.runner;
      final points = await runner.run();

      expect(paused, isTrue);
      // The interrupted stimulus (the third) is delivered again at once.
      expect(h.delivered[3].level, h.delivered[2].level);
      expect(points.single.thresholdDbHl, 20);
    });
  });

  group('output limits', () {
    test('never asks for more than the headphones can produce', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 100},
        ears: const [Ear.right],
        frequencies: const [250, 1000],
        maxLevelFor: (ear, hz) => hz == 250 ? 75 : 90,
      );
      final points = await h.runner.run();

      final at250 = h.delivered.where((d) => d.hz == 250);
      expect(at250.map((d) => d.level).reduce(max), 75);
      expect(points.every((p) => p.noResponse), isTrue);
      final limits = h.runner.protocolRecord.outputLimits;
      expect(limits.single.frequencyHz, 250);
      expect(limits.single.maxDbHl, 75);
      expect(h.runner.protocolRecord.maxLevelFor(Ear.right, 1000), 90);
    });
  });

  group('skipping and breaks', () {
    test('a skip during familiarisation is ignored', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 20},
        ears: const [Ear.right],
        frequencies: const [1000],
        familiarise: true,
        hold: true,
        minToneMs: 300,
        maxToneMs: 300,
        toneTime: const Duration(milliseconds: 300),
      );
      var tried = false;
      h.runner.addListener(() {
        if (!tried && h.runner.phase == TestPhase.familiarising) {
          tried = true;
          h.runner.skipCurrentFrequency();
        }
      });
      final points = await h.runner.run();
      expect(tried, isTrue);
      expect(h.runner.protocolRecord.skipped, isEmpty);
      expect(points.single.thresholdDbHl, 20);
    });

    test('a retest of a skipped frequency un-skips it', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 20},
        ears: const [Ear.right],
        frequencies: const [1000, 2000, 500],
        retestFirstEar: true,
      );
      var skipped = false;
      h.runner.addListener(() {
        if (!skipped &&
            h.runner.currentFrequencyHz == 1000 &&
            !h.runner.currentIsRetest) {
          skipped = true;
          h.runner.skipCurrentFrequency();
        }
      });
      final points = await h.runner.run();
      expect(points.map((p) => p.frequencyHz), contains(1000));
      expect(h.runner.protocolRecord.skipped, isEmpty);
    });

    test('a skipped frequency is recorded and has no point', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 20},
        ears: const [Ear.right],
        frequencies: const [1000, 2000, 4000],
      );
      var skipped = false;
      h.runner.addListener(() {
        if (!skipped && h.runner.currentFrequencyHz == 2000) {
          skipped = true;
          h.runner.skipCurrentFrequency();
        }
      });
      final points = await h.runner.run();

      expect(points.map((p) => p.frequencyHz).toList(), [1000, 4000]);
      expect(h.runner.protocolRecord.skipped.single.frequencyHz, 2000);
      expect(h.runner.phase, TestPhase.complete);
    });

    test('offers a break once the break time has passed', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 20},
        ears: const [Ear.right],
        frequencies: const [1000, 2000],
        breakAfter: Duration.zero,
      );
      var offers = 0;
      h.runner.addListener(() {
        if (h.runner.phase == TestPhase.breakOffered) {
          offers++;
          h.runner.continueAfterBreak();
        }
      });
      await h.runner.run();

      expect(offers, greaterThan(0));
      expect(h.runner.protocolRecord.breaksOffered, offers);
    });
  });

  group('pause', () {
    test('stays paused while a tone already playing finishes', () async {
      final h = buildRunner(
        trueThresholds: {Ear.right: 20},
        ears: const [Ear.right],
        frequencies: const [1000],
        toneTime: const Duration(milliseconds: 20),
      );
      var paused = false;
      final seenWhilePaused = <TestPhase>[];
      h.runner.addListener(() {
        if (!paused && h.runner.phase == TestPhase.presenting) {
          paused = true;
          h.runner.pause();
          Future<void>.delayed(const Duration(milliseconds: 60), () {
            seenWhilePaused.add(h.runner.phase);
            h.runner.resume();
          });
        }
      });
      final points = await h.runner.run();

      expect(seenWhilePaused, [TestPhase.paused]);
      expect(points.single.thresholdDbHl, 20);
    });
  });
}
