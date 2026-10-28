import 'package:flutter/material.dart';

import '../../data/auth_service.dart';
import '../../utils/route_constants.dart';
import '../app_scope.dart';
import '../theme.dart';
import '../widgets/auris_button.dart';
import '../widgets/auris_input_field.dart';
import '../widgets/google_sign_in_button.dart';

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  final _joinCodeController = TextEditingController();

  bool _acceptedTerms = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    _joinCodeController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (!_acceptedTerms) {
      setState(() => _error = 'Please accept the terms to continue.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await AppScope.of(context).auth.signUp(
            username: _usernameController.text,
            displayName: _nameController.text,
            password: _passwordController.text,
            joinCode: _joinCodeController.text,
          );
      if (!mounted) return;
      Navigator.pushNamedAndRemoveUntil(context, dashboardRoute, (_) => false);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not create the account. $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cloud = AppScope.of(context).cloudSyncEnabled;
    final identifierLabel = cloud ? 'Email' : 'Username';

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.black),
      ),
      body: Form(
        key: _formKey,
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Image.asset('assets/images/Logo.png', height: 62.0, width: 54.0),
                const SizedBox(height: 26),
                const Text(
                  'Sign Up',
                  style: TextStyle(
                    color: Color(0xFF000000),
                    fontWeight: FontWeight.w500,
                    fontSize: 22.0,
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    cloud
                        // Roles are assigned server-side; a new account cannot
                        // grant itself access, so say so before they sign up
                        // rather than leaving them puzzled at the dashboard.
                        ? 'Your name appears on every report you sign off. '
                            'Every new account starts with no access until a '
                            'clinic admin or a super admin approves it.'
                        : 'Your name appears on every report you sign off. The '
                            'first account on this device becomes its '
                            'administrator; later accounts wait until an '
                            'administrator gives them a role.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 12.5, height: 1.4, color: AurisTheme.muted),
                  ),
                ),
                const SizedBox(height: 22),
                AurisInputField(
                  controller: _nameController,
                  textHint: 'Full name',
                  icon: Icons.badge_outlined,
                  textCapitalization: TextCapitalization.words,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (value) => (value?.trim().isEmpty ?? true)
                      ? 'Enter your name'
                      : null,
                ),
                const SizedBox(height: 12),
                AurisInputField(
                  controller: _usernameController,
                  textHint: identifierLabel,
                  icon: cloud ? Icons.mail_outline : Icons.person_outline,
                  keyboardType:
                      cloud ? TextInputType.emailAddress : TextInputType.text,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (value) {
                    final v = value?.trim() ?? '';
                    if (v.isEmpty) return 'Enter a $identifierLabel';
                    if (cloud && !v.contains('@')) {
                      return 'Enter a valid email address';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                AurisInputField(
                  controller: _passwordController,
                  textHint: 'Password',
                  icon: Icons.lock_outline,
                  obscureText: true,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (value) => (value == null || value.length < 8)
                      ? 'Use at least 8 characters'
                      : null,
                ),
                const SizedBox(height: 12),
                AurisInputField(
                  controller: _confirmController,
                  textHint: 'Password again',
                  icon: Icons.lock_outline,
                  obscureText: true,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (value) => value != _passwordController.text
                      ? 'The passwords do not match'
                      : null,
                ),
                if (cloud) ...[
                  const SizedBox(height: 12),
                  AurisInputField(
                    controller: _joinCodeController,
                    textHint: 'Clinic join code (optional), e.g. AUR-7K2PQ',
                    icon: Icons.local_hospital_outlined,
                    textCapitalization: TextCapitalization.characters,
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 6, 24, 0),
                    child: Text(
                      'Your clinic\'s administrator can give you this code. '
                      'Your account sees no records until they approve it.',
                      style: TextStyle(
                          fontSize: 11.5, height: 1.4, color: AurisTheme.muted),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      Checkbox(
                        value: _acceptedTerms,
                        activeColor: AurisTheme.primary,
                        onChanged: (value) =>
                            setState(() => _acceptedTerms = value ?? false),
                      ),
                      Expanded(
                        child: Text(
                          'I understand Auris is not a certified medical device '
                          'and results require a calibrated device.',
                          style: TextStyle(
                            color: Colors.black.withValues(alpha: 0.6),
                            fontWeight: FontWeight.w400,
                            fontSize: 12.0,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
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
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 85),
                  child: AurisButton(
                    buttonName: 'Sign Up',
                    busy: _busy,
                    onTap: _submit,
                  ),
                ),
                const SizedBox(height: 22),
                // Renders nothing in local-only mode.
                GoogleSignInButton(
                  label: 'Sign up with Google',
                  enabled: _acceptedTerms,
                  joinCode: () => _joinCodeController.text,
                ),
                const SizedBox(height: 28),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Already have an account? ',
                      style: TextStyle(
                        color: Colors.black.withValues(alpha: 0.5),
                        fontSize: 14.0,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    GestureDetector(
                      // Sign-up may be the first screen on a new device, with
                      // nothing underneath to go back to.
                      onTap: () => Navigator.canPop(context)
                          ? Navigator.pop(context)
                          : Navigator.pushReplacementNamed(context, loginRoute),
                      child: const Text(
                        'Log In',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AurisTheme.primary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
