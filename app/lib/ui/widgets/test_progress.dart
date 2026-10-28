import 'package:flutter/material.dart';

import '../../core/audiometry/audiometry.dart';
import '../theme.dart';

/// Header showing which ear is being tested, how far along the test is, and
/// roughly how much longer it will take.
///
/// Everything here is safe to show a patient: none of it says whether a tone is
/// sounding right now or how loud it is.
class TestProgressHeader extends StatelessWidget {
  const TestProgressHeader({
    super.key,
    required this.ear,
    required this.completed,
    required this.total,
    required this.remainingLabel,
    required this.frequencies,
    required this.currentFrequencyHz,
    required this.completedFrequencies,
  });

  final Ear? ear;
  final int completed;
  final int total;
  final String remainingLabel;

  /// Frequencies in presentation order for the current ear.
  final List<int> frequencies;
  final int? currentFrequencyHz;
  final Set<int> completedFrequencies;

  @override
  Widget build(BuildContext context) {
    final earColour =
        ear == Ear.left ? AurisTheme.leftEar : AurisTheme.rightEar;

    return Column(
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          child: Column(
            key: ValueKey(ear),
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: earColour.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.hearing_rounded, size: 16, color: earColour),
                    const SizedBox(width: 7),
                    Text(
                      ear == null ? 'Getting ready' : '${ear!.label} ear',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: earColour,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _StepDots(
          frequencies: frequencies,
          currentFrequencyHz: currentFrequencyHz,
          completedFrequencies: completedFrequencies,
          colour: earColour,
        ),
        const SizedBox(height: 12),
        Text(
          'Sound $completed of $total  ·  $remainingLabel',
          style: const TextStyle(fontSize: 13.5, color: AurisTheme.muted),
        ),
      ],
    );
  }
}

/// One dot per frequency in the current ear: filled for done, ringed and
/// enlarged for the one in progress, hollow for pending.
///
/// Shows *which step* of the test is running, not what is being played.
class _StepDots extends StatelessWidget {
  const _StepDots({
    required this.frequencies,
    required this.currentFrequencyHz,
    required this.completedFrequencies,
    required this.colour,
  });

  final List<int> frequencies;
  final int? currentFrequencyHz;
  final Set<int> completedFrequencies;
  final Color colour;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final hz in frequencies) ...[
            _dot(
              done: completedFrequencies.contains(hz),
              current: hz == currentFrequencyHz,
            ),
            if (hz != frequencies.last)
              Container(
                width: 16,
                height: 2,
                color: completedFrequencies.contains(hz)
                    ? colour.withValues(alpha: 0.45)
                    : AurisTheme.hairline,
              ),
          ],
        ],
      );

  Widget _dot({required bool done, required bool current}) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      width: current ? 16 : 11,
      height: current ? 16 : 11,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: done ? colour : (current ? Colors.white : AurisTheme.hairline),
        border: current ? Border.all(color: colour, width: 3) : null,
      ),
      child: done
          ? const Icon(Icons.check, size: 8, color: Colors.white)
          : null,
    );
  }
}

/// Shown between ears, so the patient gets a beat to reposition the headphones
/// and knows that the halfway point has been reached.
class EarChangeoverCard extends StatelessWidget {
  const EarChangeoverCard({
    super.key,
    required this.finishedEar,
    required this.nextEar,
    required this.onContinue,
  });

  final Ear finishedEar;
  final Ear nextEar;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final nextColour =
        nextEar == Ear.left ? AurisTheme.leftEar : AurisTheme.rightEar;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              height: 84,
              width: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AurisTheme.success.withValues(alpha: 0.10),
              ),
              child: const Icon(Icons.check_rounded,
                  size: 42, color: AurisTheme.success),
            ),
            const SizedBox(height: 22),
            Text(
              '${finishedEar.label} ear done',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: AurisTheme.ink,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Halfway. Take a moment if you need one - the ${nextEar.label.toLowerCase()} '
              'ear is next, and it works exactly the same way.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 14.5, height: 1.55, color: AurisTheme.muted),
            ),
            const SizedBox(height: 26),
            GestureDetector(
              onTap: onContinue,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 34, vertical: 15),
                decoration: BoxDecoration(
                  color: nextColour,
                  borderRadius: BorderRadius.circular(AurisTheme.pillRadius),
                ),
                child: Text(
                  'Start ${nextEar.label.toLowerCase()} ear',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A pause in the test that needs the clinician: re-instructing the patient,
/// or offering a break. Same layout as [EarChangeoverCard].
class TestGateCard extends StatelessWidget {
  const TestGateCard({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    required this.buttonLabel,
    required this.onContinue,
  });

  final IconData icon;
  final String title;
  final String message;
  final String buttonLabel;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                height: 84,
                width: 84,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AurisTheme.warning.withValues(alpha: 0.14),
                ),
                child: Icon(icon, size: 40, color: AurisTheme.warning),
              ),
              const SizedBox(height: 22),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                  color: AurisTheme.ink,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 14.5, height: 1.55, color: AurisTheme.muted),
              ),
              const SizedBox(height: 26),
              FilledButton(
                onPressed: onContinue,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  child: Text(buttonLabel),
                ),
              ),
            ],
          ),
        ),
      );
}
