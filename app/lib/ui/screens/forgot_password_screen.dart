import 'package:flutter/material.dart';

import '../../data/auth_service.dart';
import '../../utils/route_constants.dart';
import '../app_scope.dart';
import '../theme.dart';
import '../widgets/auris_button.dart';
import '../widgets/auris_input_field.dart';

/// Password reset for cloud accounts, done entirely inside the app.
///
/// Step 1 emails a one-time code. Step 2 takes the code and a new password.
/// A code is used instead of the usual reset link because a link needs a web
/// page to land on, and Auris is a desktop and mobile app.
///
/// Local (offline) accounts have no email address: an administrator on the
/// device sets a new password from Settings, Team. The login screen offers
/// this screen in local mode too, to say so.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key, this.initialEmail});

  /// Pre-filled from the login screen when the user already typed it.
  final String? initialEmail;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _emailForm = GlobalKey<FormState>();
  final _resetForm = GlobalKey<FormState>();
  late final TextEditingController _email =
      TextEditingController(text: widget.initialEmail ?? '');
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  bool _codeSent = false;
  bool _busy = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  SupabaseAuthService? get _cloudAuth {
    final auth = AppScope.of(context).auth;
    return auth is SupabaseAuthService ? auth : null;
  }

  Future<void> _sendCode() async {
    final auth = _cloudAuth;
    if (auth == null) return;
    if (!(_emailForm.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      await auth.sendPasswordResetCode(_email.text);
      if (!mounted) return;
      setState(() {
        _codeSent = true;
        _info = 'If an account exists for ${_email.text.trim()}, a code is on '
            'its way. Check your inbox and spam folder.';
      });
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not send the code. $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset() async {
    final auth = _cloudAuth;
    if (auth == null) return;
    if (!(_resetForm.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await auth.resetPasswordWithCode(
        email: _email.text,
        code: _code.text,
        newPassword: _password.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password changed. You are signed in.')),
      );
      Navigator.pushNamedAndRemoveUntil(context, dashboardRoute, (_) => false);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not reset the password. $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cloud = _cloudAuth != null;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: AurisTheme.ink,
      ),
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              children: [
                Image.asset('assets/images/Logo.png', height: 62.0, width: 54.0),
                const SizedBox(height: 24),
                const Text(
                  'Reset password',
                  style: TextStyle(fontWeight: FontWeight.w500, fontSize: 22.0),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Text(
                    !cloud
                        ? 'Accounts on this device have no email address to '
                            'send a code to. Ask an administrator on this '
                            'device to set a new password for you in Settings, '
                            'Team (the key button next to your name).'
                        : _codeSent
                            ? 'Enter the code from the email and choose a new '
                                'password.'
                            : 'Enter the email you signed up with and we will '
                                'send you a one-time code.',
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(color: AurisTheme.muted, height: 1.4),
                  ),
                ),
                const SizedBox(height: 24),
                if (cloud) ...[
                  Form(
                    key: _emailForm,
                    child: AurisInputField(
                      controller: _email,
                      textHint: 'Email',
                      icon: Icons.mail_outline,
                      keyboardType: TextInputType.emailAddress,
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      validator: (v) {
                        final value = v?.trim() ?? '';
                        if (value.isEmpty) return 'Enter your email';
                        if (!value.contains('@')) {
                          return 'Enter a valid email address';
                        }
                        return null;
                      },
                      onSubmitted: (_) => _codeSent ? null : _sendCode(),
                    ),
                  ),
                  if (_codeSent)
                    Form(
                      key: _resetForm,
                      child: Column(
                        children: [
                          const SizedBox(height: 16),
                          AurisInputField(
                            controller: _code,
                            textHint: 'Code from the email',
                            icon: Icons.pin_outlined,
                            keyboardType: TextInputType.number,
                            autovalidateMode:
                                AutovalidateMode.onUserInteraction,
                            validator: (v) {
                              final value = v?.trim() ?? '';
                              if (!RegExp(r'^\d{6,10}$').hasMatch(value)) {
                                return 'Enter the code from the email';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 16),
                          AurisInputField(
                            controller: _password,
                            textHint: 'New password',
                            icon: Icons.lock_outline,
                            obscureText: true,
                            autovalidateMode:
                                AutovalidateMode.onUserInteraction,
                            validator: (v) => (v == null || v.length < 8)
                                ? 'Use at least 8 characters'
                                : null,
                          ),
                          const SizedBox(height: 16),
                          AurisInputField(
                            controller: _confirm,
                            textHint: 'Confirm new password',
                            icon: Icons.lock_outline,
                            obscureText: true,
                            autovalidateMode:
                                AutovalidateMode.onUserInteraction,
                            validator: (v) => v != _password.text
                                ? 'The passwords do not match'
                                : null,
                            onSubmitted: (_) => _reset(),
                          ),
                        ],
                      ),
                    ),
                  if (_info != null) ...[
                    const SizedBox(height: 14),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        _info!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: AurisTheme.success, fontSize: 13),
                      ),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: AurisTheme.rightEar, fontSize: 13),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  AurisButton(
                    buttonName: _codeSent ? 'Set new password' : 'Send code',
                    busy: _busy,
                    onTap: _codeSent ? _reset : _sendCode,
                  ),
                  if (_codeSent)
                    TextButton(
                      onPressed: _busy ? null : _sendCode,
                      child: const Text('Send a new code'),
                    ),
                ],
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
