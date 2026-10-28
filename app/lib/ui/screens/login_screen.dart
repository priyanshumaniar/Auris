import 'package:flutter/material.dart';

import '../../data/auth_service.dart';
import '../../utils/route_constants.dart';
import '../app_scope.dart';
import '../theme.dart';
import '../widgets/auris_button.dart';
import '../widgets/auris_input_field.dart';
import '../widgets/google_sign_in_button.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await AppScope.of(context).auth.signIn(
            username: _usernameController.text,
            password: _passwordController.text,
          );
      if (!mounted) return;
      Navigator.pushNamedAndRemoveUntil(context, dashboardRoute, (_) => false);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not sign in. $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cloud = AppScope.of(context).cloudSyncEnabled;
    final identifierLabel = cloud ? 'Email' : 'Username';

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const SizedBox(height: 90),
                Image.asset('assets/images/Logo.png', height: 62.0, width: 54.0),
                const SizedBox(height: 30),
                const Text(
                  'Log In',
                  style: TextStyle(
                    color: Color(0xFF000000),
                    fontWeight: FontWeight.w500,
                    fontSize: 22.0,
                  ),
                ),
                const SizedBox(height: 28),
                AurisInputField(
                  controller: _usernameController,
                  textHint: identifierLabel,
                  icon: cloud ? Icons.mail_outline : Icons.person_outline,
                  keyboardType:
                      cloud ? TextInputType.emailAddress : TextInputType.text,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (value) {
                    final v = value?.trim() ?? '';
                    if (v.isEmpty) return 'Enter your $identifierLabel';
                    if (cloud && !v.contains('@')) {
                      return 'Enter a valid email address';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                AurisInputField(
                  controller: _passwordController,
                  textHint: 'Password',
                  icon: Icons.lock_outline,
                  obscureText: true,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (value) => (value == null || value.isEmpty)
                      ? 'Enter your password'
                      : null,
                  onSubmitted: (_) => _submit(),
                ),
                Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 20, top: 4),
                      child: TextButton(
                        onPressed: () => Navigator.pushNamed(
                          context,
                          forgotPasswordRoute,
                          arguments: _usernameController.text.trim(),
                        ),
                        child: const Text('Forgot password?'),
                      ),
                    ),
                  ),
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
                const SizedBox(height: 26),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 85),
                  child: AurisButton(
                    buttonName: 'Log In',
                    busy: _busy,
                    onTap: _submit,
                  ),
                ),
                const SizedBox(height: 34),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                        height: 1.0,
                        width: 88.74,
                        color: const Color(0xff2e2499).withValues(alpha: 0.6)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18.0),
                      child: Text(
                        'Or',
                        style: TextStyle(
                          color:
                              const Color(0xff2e2499).withValues(alpha: 0.6),
                          fontWeight: FontWeight.w400,
                          fontSize: 12.0,
                        ),
                      ),
                    ),
                    Container(
                        height: 1.0,
                        width: 88.74,
                        color: const Color(0xff2e2499).withValues(alpha: 0.6)),
                  ],
                ),
                const SizedBox(height: 26),
                if (cloud) ...[
                  const GoogleSignInButton(),
                  const SizedBox(height: 8),
                  // A first Google sign-in creates an account, so it carries
                  // the same notice the sign-up screen asks users to accept.
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 30),
                    child: Text(
                      'By continuing with Google you confirm that you '
                      'understand Auris is not a certified medical device.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 11.5, height: 1.4, color: AurisTheme.muted),
                    ),
                  ),
                  const SizedBox(height: 18),
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      "Don't have an account? ",
                      style: TextStyle(
                        color: Colors.black.withValues(alpha: 0.5),
                        fontSize: 14.0,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    GestureDetector(
                      onTap: () =>
                          Navigator.pushNamed(context, signUpRoute),
                      child: const Text(
                        'Sign Up',
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
