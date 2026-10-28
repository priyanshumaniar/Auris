import 'dart:math';

import 'package:auris/core/audiometry/audiometry.dart';
import 'package:auris/core/audiometry/hughson_westlake.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drives a [HughsonWestlakeSearch] with a simulated patient who responds to
/// any tone at or above [trueThreshold] dB HL, and returns the search once it
/// completes.
///
/// [respondToSilence] models a patient who presses the button on catch trials.
HughsonWestlakeSearch runSimulation(
  HughsonWestlakeSearch search, {
  required int trueThreshold,
  bool respondToSilence = false,
}) {
  var guard = 0;
  while (!search.isComplete) {
    if (++guard > 500) fail('Search failed to terminate');
    final p = search.current;
    final responded = p.isCatchTrial
        ? respondToSilence
        : p.levelDbHl >= trueThreshold;
    search.recordResponse(responded: responded);
  }
  return search;
}

void main() {
  group('threshold convergence', () {
    // A simulated patient responds deterministically at or above threshold, so
    // the procedure must land exactly on that level for every 5 dB step in the
    // audiometric range.
    for (final trueThreshold in [-10, -5, 0, 5, 15, 25, 40, 55, 70, 85, 90]) {
      test('converges to $trueThreshold dB HL', () {
        final search = runSimulation(
          HughsonWestlakeSearch(),
          trueThreshold: trueThreshold,
        );

        expect(search.result.noResponse, isFalse);
        expect(search.result.thresholdDbHl, trueThreshold);
      });
    }

    test('converges from a start level far below the true threshold', () {
      // Start at 30 dB HL for a patient with a 75 dB HL loss: the search has to
      // climb a long way before it ever gets a response.
      final search = runSimulation(
        HughsonWestlakeSearch(startLevelDbHl: 30),
        trueThreshold: 75,
      );
      expect(search.result.thresholdDbHl, 75);
    });
  });

  group('2-of-3 ascending criterion', () {
    test('a single ascending response is not enough to set threshold', () {
      final search = HughsonWestlakeSearch(startLevelDbHl: 30);

      // 30 heard -> down to 20
      search.recordResponse(responded: true);
      expect(search.current.levelDbHl, 20);
      expect(search.current.isAscending, isFalse);

      // 20 missed -> up to 25 (this is now an ascending presentation)
      search.recordResponse(responded: false);
      expect(search.current.levelDbHl, 25);
      expect(search.current.isAscending, isTrue);

      // 25 heard on the way up -> one ascending response, not two
      search.recordResponse(responded: true);
      expect(search.ascendingResponses[25], 1);
      expect(search.isComplete, isFalse,
          reason: 'one ascending response must not settle the threshold');
    });

    test('descending responses do not count toward the criterion', () {
      final search = HughsonWestlakeSearch(startLevelDbHl: 30);

      // Every one of these is a descending presentation.
      search.recordResponse(responded: true); // 30 -> 20
      search.recordResponse(responded: true); // 20 -> 10
      search.recordResponse(responded: true); // 10 -> 0

      expect(search.ascendingResponses, isEmpty);
      expect(search.isComplete, isFalse);
    });

    test('threshold is the lowest level reaching two ascending responses', () {
      final search = runSimulation(
        HughsonWestlakeSearch(),
        trueThreshold: 20,
      );
      final threshold = search.result.thresholdDbHl!;

      expect(search.ascendingResponses[threshold], greaterThanOrEqualTo(2));
      // No level below the reported threshold may have met the criterion.
      for (final entry in search.ascendingResponses.entries) {
        if (entry.key < threshold) {
          expect(entry.value, lessThan(2),
              reason: '${entry.key} dB met the criterion but was not reported');
        }
      }
    });
  });

  group('half-of-ascending-trials criterion', () {
    test('every reported threshold meets the criterion', () {
      // A patient who hears near threshold only some of the time. Whatever
      // the search reports must have at least two ascending responses, on at
      // least half of the ascending presentations at that level.
      for (var seed = 0; seed < 300; seed++) {
        final rng = Random(seed);
        final search = HughsonWestlakeSearch(random: Random(seed));
        var guard = 0;
        while (!search.isComplete) {
          if (++guard > 500) fail('did not terminate (seed $seed)');
          final level = search.current.levelDbHl;
          // Always hears 30 and above, never below 15, 50/50 in between.
          final hears = level >= 30 || (level >= 15 && rng.nextBool());
          search.recordResponse(responded: hears);
        }
        final r = search.result;
        if (r.notEstablished || r.noResponse || r.atFloor) continue;
        final t = r.thresholdDbHl!;
        final hits = search.ascendingResponses[t] ?? 0;
        final tries = search.ascendingPresentations[t] ?? 0;
        expect(hits, greaterThanOrEqualTo(2), reason: 'seed $seed');
        expect(hits * 2, greaterThanOrEqualTo(tries), reason: 'seed $seed');
      }
    });
  });

  group('floor', () {
    test('a single response at the floor does not end the search', () {
      final search = HughsonWestlakeSearch(startLevelDbHl: 30);
      // Heard at 30, 20, 10 and 0 dB HL on the way down.
      for (var i = 0; i < 4; i++) {
        search.recordResponse(responded: true);
      }
      expect(search.current.levelDbHl, kMinLevelDbHl);
      search.recordResponse(responded: true); // first response at the floor
      expect(search.isComplete, isFalse);
      expect(search.current.levelDbHl, kMinLevelDbHl,
          reason: 'the floor is presented again');
    });

    test('two responses at the floor are reported as at or below it', () {
      final search = runSimulation(HughsonWestlakeSearch(), trueThreshold: -20);
      expect(search.result.thresholdDbHl, kMinLevelDbHl);
      expect(search.result.atFloor, isTrue);
      final atFloor =
          search.log.where((r) => r.levelDbHl == kMinLevelDbHl).length;
      expect(atFloor, greaterThanOrEqualTo(2));
    });

    test('a miss at the floor goes back to an ascending run', () {
      final search = HughsonWestlakeSearch(startLevelDbHl: 30);
      // Heard at 30, 20, 10 and 0 dB HL on the way down.
      for (var i = 0; i < 4; i++) {
        search.recordResponse(responded: true);
      }
      search.recordResponse(responded: true); // -10 heard
      search.recordResponse(responded: false); // -10 missed
      expect(search.current.levelDbHl, kMinLevelDbHl + 5);
      expect(search.current.isAscending, isTrue);
    });

    test('a threshold just above the floor is still measured normally', () {
      final search = runSimulation(HughsonWestlakeSearch(), trueThreshold: -5);
      expect(search.result.thresholdDbHl, -5);
      expect(search.result.atFloor, isFalse);
    });
  });

  group('maximum level', () {
    test('a miss at the maximum after a response there is not a no-response',
        () {
      final search = HughsonWestlakeSearch(startLevelDbHl: 80, maxLevelDbHl: 90);
      for (final r in [false, false, true, false, false, false]) {
        search.recordResponse(responded: r);
      }
      expect(search.isComplete, isFalse,
          reason: 'heard at 90 once, so the search goes on');
      // Keeps alternating: ends not established, never as no-response.
      while (!search.isComplete) {
        final level = search.current.levelDbHl;
        search.recordResponse(responded: level == 90 && search.log.length.isEven);
      }
      expect(search.result.noResponse, isFalse);
    });

    test('never heard at the maximum is a no-response', () {
      final search = HughsonWestlakeSearch(startLevelDbHl: 80, maxLevelDbHl: 90);
      while (!search.isComplete) {
        search.recordResponse(responded: false);
      }
      expect(search.result.noResponse, isTrue);
      expect(search.log.map((r) => r.levelDbHl).reduce(max), 90);
    });
  });

  group('presentation budget', () {
    test('running out of presentations gives "not established"', () {
      // 30 heard, 20 heard, 10 missed, 15 missed, 20 heard (one ascending
      // response): five tones and no level has met the criterion.
      final search = runSimulation(
        HughsonWestlakeSearch(maxPresentations: 5),
        trueThreshold: 20,
      );
      expect(search.result.notEstablished, isTrue);
      expect(search.result.thresholdDbHl, isNull);
      expect(search.result.noResponse, isFalse);
    });
  });

  group('step sizes', () {
    test('drops 10 dB after a response and rises 5 dB after a miss', () {
      final search = HughsonWestlakeSearch(startLevelDbHl: 50);

      search.recordResponse(responded: true);
      expect(search.current.levelDbHl, 40, reason: 'down 10 after a response');

      search.recordResponse(responded: false);
      expect(search.current.levelDbHl, 45, reason: 'up 5 after a miss');

      search.recordResponse(responded: false);
      expect(search.current.levelDbHl, 50);
    });
  });

  group('boundaries', () {
    test('reports no response when the patient never hears the tone', () {
      final search = runSimulation(
        HughsonWestlakeSearch(),
        trueThreshold: 10000, // profoundly deaf at this frequency
      );

      expect(search.result.noResponse, isTrue);
      expect(search.result.thresholdDbHl, isNull);
      expect(search.log.last.levelDbHl, kMaxLevelDbHl,
          reason: 'must exhaust the maximum output before giving up');
    });

    test('never presents above the configured maximum', () {
      final search = runSimulation(
        HughsonWestlakeSearch(),
        trueThreshold: 10000,
      );
      for (final record in search.log) {
        expect(record.levelDbHl, lessThanOrEqualTo(kMaxLevelDbHl));
      }
    });

    test('never presents below the configured minimum', () {
      final search = runSimulation(
        HughsonWestlakeSearch(),
        trueThreshold: -100, // hears everything
      );
      for (final record in search.log) {
        expect(record.levelDbHl, greaterThanOrEqualTo(kMinLevelDbHl));
      }
      expect(search.result.thresholdDbHl, kMinLevelDbHl);
    });

    test('terminates within the presentation budget', () {
      // A patient who answers at random is the pathological case: it must stop.
      final rng = Random(1234);
      final search = HughsonWestlakeSearch(maxPresentations: 40);
      var guard = 0;
      while (!search.isComplete) {
        if (++guard > 500) fail('did not terminate');
        search.recordResponse(responded: rng.nextBool());
      }
      expect(search.toneCount, lessThanOrEqualTo(40));
    });
  });

  group('catch trials', () {
    test('silent trials do not move the search level', () {
      final search = HughsonWestlakeSearch(
        startLevelDbHl: 40,
        catchTrialProbability: 1.0, // every trial after the first is silent
        random: Random(7),
      );

      search.recordResponse(responded: true); // real tone at 40 -> down to 30
      expect(search.current.levelDbHl, 30);
      expect(search.current.isCatchTrial, isTrue);

      search.recordResponse(responded: false); // answered the silent trial
      expect(search.current.levelDbHl, 30,
          reason: 'a catch trial must not change the level');
    });

    test('counts responses to silence as false positives', () {
      final search = HughsonWestlakeSearch(
        catchTrialProbability: 0.5,
        random: Random(42),
      );
      runSimulation(search, trueThreshold: 20, respondToSilence: true);

      expect(search.result.catchTrials, greaterThan(0));
      expect(search.result.falsePositives, search.result.catchTrials,
          reason: 'this patient responds to every silent trial');
      expect(search.result.isReliable, isFalse);
    });

    test('an honest patient scores as reliable', () {
      final search = HughsonWestlakeSearch(
        catchTrialProbability: 0.5,
        random: Random(42),
      );
      runSimulation(search, trueThreshold: 20, respondToSilence: false);

      expect(search.result.falsePositives, 0);
      expect(search.result.isReliable, isTrue);
    });
  });

  group('API contract', () {
    test('reading the result before completion throws', () {
      final search = HughsonWestlakeSearch();
      expect(() => search.result, throwsStateError);
    });

    test('responding after completion throws', () {
      final search = runSimulation(HughsonWestlakeSearch(), trueThreshold: 30);
      expect(() => search.recordResponse(responded: true), throwsStateError);
    });

    test('the log records every presentation in order', () {
      final search = runSimulation(HughsonWestlakeSearch(), trueThreshold: 25);
      expect(search.log.length, greaterThanOrEqualTo(search.toneCount));
      expect(search.log.first.levelDbHl, kStartLevelDbHl);
    });
  });
}
