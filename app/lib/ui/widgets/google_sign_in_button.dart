import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../data/auth_service.dart';
import '../../utils/route_constants.dart';
import '../app_scope.dart';
import '../theme.dart';

/// "Continue with Google". Shown only when cloud sync is on (local accounts
/// live on the device and have no identity provider), and not on Windows or
/// Linux, where the app cannot receive the browser's hand-back.
///
/// Google sign-in happens in the browser. This widget opens it, then waits for
/// the browser to hand the user back to the app, and moves on to the
/// dashboard once the session and profile are in.
class GoogleSignInButton extends StatefulWidget {
  const GoogleSignInButton({
    super.key,
    this.label = 'Continue with Google',
    this.enabled = true,
    this.joinCode,
  });

  final String label;

  /// False keeps the button greyed out, e.g. until the sign-up disclaimer is
  /// accepted.
  final bool enabled;

  /// A clinic join code typed on the same screen. Google sign-up has no field
  /// for it, so it is sent as a request to join once the account exists.
  final String Function()? joinCode;

  /// Whether this platform can complete Google sign-in.
  static bool get supported =>
      kIsWeb || !(Platform.isWindows || Platform.isLinux);

  @override
  State<GoogleSignInButton> createState() => _GoogleSignInButtonState();
}

class _GoogleSignInButtonState extends State<GoogleSignInButton> {
  StreamSubscription<void>? _signedInSub;

  /// True between opening the browser and the session arriving.
  bool _waiting = false;

  /// The user pressed Cancel while waiting. If they finish in the browser
  /// anyway, the session still arrives and is still used.
  bool _cancelled = false;

  bool _finishing = false;
  String? _error;

  SupabaseAuthService? get _cloudAuth {
    final auth = AppScope.of(context).auth;
    return auth is SupabaseAuthService ? auth : null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = _cloudAuth;
    if (auth != null && _signedInSub == null) {
      _signedInSub = auth.signedIn.listen((_) => _onSignedIn(auth));
    }
  }

  /// A session arrived. Only the Google flow this button started is acted on
  /// here (a password sign-in navigates by itself), and only by the screen
  /// on top, so a sign-up screen above the login screen moves on once.
  Future<void> _onSignedIn(SupabaseAuthService auth) async {
    if (!mounted || (!_waiting && !_cancelled) || _finishing) return;
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) return;
    _finishing = true;
    final account = AppScope.of(context).account;
    await auth.refreshProfile();
    final code = widget.joinCode?.call().trim() ?? '';
    final profile = auth.profile;
    if (code.isNotEmpty &&
        profile != null &&
        profile.isPending &&
        profile.requestedClinicId == null) {
      try {
        await account.requestClinic(code);
      } catch (_) {
        // A wrong code is not a reason to stop: the waiting screen and the
        // profile both let them enter it again.
      }
    }
    if (!mounted) return;
    _waiting = false;
    _cancelled = false;
    Navigator.pushNamedAndRemoveUntil(context, dashboardRoute, (_) => false);
  }

  @override
  void dispose() {
    _signedInSub?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final auth = _cloudAuth;
    if (auth == null) return;
    setState(() {
      _waiting = true;
      _cancelled = false;
      _error = null;
    });
    try {
      await auth.startGoogleSignIn();
    } on AuthException catch (e) {
      if (mounted) {
        setState(() {
          _waiting = false;
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _waiting = false;
          _error = 'Could not start Google sign-in. $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cloudAuth == null || !GoogleSignInButton.supported) {
      return const SizedBox.shrink();
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 60),
          child: SizedBox(
            height: 50,
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: (_waiting || !widget.enabled) ? null : _start,
              icon: _waiting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.account_circle_outlined),
              label: Text(_waiting ? 'Waiting for Google…' : widget.label),
              style: OutlinedButton.styleFrom(
                foregroundColor: AurisTheme.ink,
                side: const BorderSide(color: AurisTheme.hairline),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AurisTheme.pillRadius),
                ),
              ),
            ),
          ),
        ),
        if (_waiting) ...[
          const SizedBox(height: 10),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'Finish signing in in your browser. Auris continues on its own '
              'when you are done.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AurisTheme.muted, fontSize: 12.5),
            ),
          ),
          TextButton(
            onPressed: () => setState(() {
              _waiting = false;
              _cancelled = true;
            }),
            child: const Text('Cancel'),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AurisTheme.rightEar, fontSize: 13),
            ),
          ),
        ],
      ],
    );
  }
}
