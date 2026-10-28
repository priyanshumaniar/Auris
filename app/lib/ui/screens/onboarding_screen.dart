import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_scope.dart';
import '../theme.dart';
import '../widgets/auris_button.dart';
import 'landing_screen.dart';

class _Slide {
  const _Slide({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;
}

/// First-run introduction.
///
/// The last slide is the calibration warning on purpose - a clinician should
/// meet that caveat before their first test, not after it.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _index = 0;

  static const _slides = [
    _Slide(
      icon: Icons.graphic_eq_rounded,
      title: 'Pure-tone audiometry',
      body:
          'Auris presents pure tones at 250 Hz to 8 kHz, one ear at a time, and '
          'finds each threshold using the modified Hughson-Westlake procedure '
          'that clinical audiometry uses.',
    ),
    _Slide(
      icon: Icons.show_chart_rounded,
      title: 'Audiogram and report',
      body:
          'Results plot on a standard audiogram - O for the right ear, X for '
          'the left - and generate a printable PDF with per-frequency '
          'thresholds and the degree of hearing loss.',
    ),
    _Slide(
      icon: Icons.headphones_rounded,
      title: 'Calibrate before you rely on it',
      body:
          'Auris is not a certified medical device. Without calibrating your '
          'headphones against a reference, the shape of the audiogram is '
          'meaningful but the absolute dB HL values are not.',
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final services = AppScope.of(context);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(Landing.seenOnboardingKey, true);
    final next = await Landing.signedOutRoute(services);
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, next);
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _index == _slides.length - 1;

    return Scaffold(
      backgroundColor: AurisTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _finish,
                child: const Text('Skip',
                    style: TextStyle(color: AurisTheme.muted)),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _slides.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) {
                  final slide = _slides[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          height: 108,
                          width: 108,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AurisTheme.primary.withValues(alpha: 0.10),
                          ),
                          child: Icon(slide.icon,
                              size: 50, color: AurisTheme.primary),
                        ),
                        const SizedBox(height: 34),
                        Text(
                          slide.title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 23,
                            fontWeight: FontWeight.w600,
                            color: AurisTheme.ink,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          slide.body,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 14.5,
                            height: 1.6,
                            color: AurisTheme.muted,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < _slides.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    height: 7,
                    width: i == _index ? 22 : 7,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      color: i == _index
                          ? AurisTheme.primary
                          : AurisTheme.primary.withValues(alpha: 0.25),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 28),
            AurisButton(
              buttonName: isLast ? 'Get started' : 'Next',
              onTap: () {
                if (isLast) {
                  _finish();
                } else {
                  _controller.nextPage(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOut,
                  );
                }
              },
            ),
            const SizedBox(height: 34),
          ],
        ),
      ),
    );
  }
}
