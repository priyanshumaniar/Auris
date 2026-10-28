import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/auth_service.dart';
import '../../services.dart';
import '../../utils/route_constants.dart';
import '../app_scope.dart';
import '../theme.dart';

/// Splash screen. Decides where a returning user lands: onboarding on first
/// run, the dashboard if already signed in, otherwise login (or sign-up, on a
/// device in local-only mode that has no account yet).
class Landing extends StatefulWidget {
  const Landing({super.key});

  static const seenOnboardingKey = 'auris.seen_onboarding.v1';

  /// Where someone who is not signed in starts: sign-up when this device is
  /// local-only and has no account (a login form could not be passed),
  /// otherwise login.
  static Future<String> signedOutRoute(AppServices services) async {
    final auth = services.auth;
    if (auth is LocalAuthService && !await auth.hasAnyClinician()) {
      return signUpRoute;
    }
    return loginRoute;
  }

  @override
  State<Landing> createState() => _LandingState();
}

class _LandingState extends State<Landing> {
  @override
  void initState() {
    super.initState();
    // Deferred so AppScope is available and the logo gets a frame on screen.
    WidgetsBinding.instance.addPostFrameCallback((_) => _decideNextScreen());
  }

  Future<void> _decideNextScreen() async {
    final services = AppScope.of(context);
    final prefs = await SharedPreferences.getInstance();
    final seenOnboarding = prefs.getBool(Landing.seenOnboardingKey) ?? false;

    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;

    final next = !seenOnboarding
        ? onboardingRoute
        : services.auth.isSignedIn
            ? dashboardRoute
            : await Landing.signedOutRoute(services);
    if (!mounted) return;

    Navigator.pushReplacementNamed(context, next);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurisTheme.background,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset('assets/images/Logo.png', width: 104, height: 120),
            const SizedBox(height: 20),
            const Text(
              'Auris',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
                color: AurisTheme.ink,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Digital audiometry',
              style: TextStyle(fontSize: 13, color: AurisTheme.muted),
            ),
          ],
        ),
      ),
    );
  }
}
