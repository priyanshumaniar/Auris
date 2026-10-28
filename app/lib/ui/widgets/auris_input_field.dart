import 'package:flutter/material.dart';

import '../theme.dart';

/// The app's standard text field: rounded, filled white, with a coloured
/// prefix block. Geometry matches the original login and sign-up screens.
///
/// A password field ([obscureText] true) gets an eye button that shows or
/// hides what was typed, so a long password can be checked before submitting.
class AurisInputField extends StatefulWidget {
  const AurisInputField({
    super.key,
    required this.textHint,
    this.controller,
    this.autovalidateMode,
    this.validator,
    this.obscureText = false,
    this.keyboardType,
    this.icon,
    this.textCapitalization = TextCapitalization.none,
    this.onSubmitted,
    this.horizontalPadding = 20.0,
  });

  final String textHint;
  final TextEditingController? controller;
  final AutovalidateMode? autovalidateMode;
  final String? Function(String?)? validator;
  final bool obscureText;
  final TextInputType? keyboardType;
  final IconData? icon;
  final TextCapitalization textCapitalization;
  final ValueChanged<String>? onSubmitted;
  final double horizontalPadding;

  @override
  State<AurisInputField> createState() => _AurisInputFieldState();
}

class _AurisInputFieldState extends State<AurisInputField> {
  /// Starts hidden; only meaningful when the field is a password field.
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final isPassword = widget.obscureText;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.horizontalPadding),
      child: TextFormField(
        controller: widget.controller,
        autovalidateMode: widget.autovalidateMode,
        validator: widget.validator,
        obscureText: isPassword && !_revealed,
        // Never let the platform keep a copy of a password in its
        // suggestions, even while it is shown in plain text.
        enableSuggestions: !isPassword,
        autocorrect: !isPassword,
        keyboardType: widget.keyboardType,
        textCapitalization: widget.textCapitalization,
        onFieldSubmitted: widget.onSubmitted,
        decoration: InputDecoration(
          fillColor: AurisTheme.surface,
          filled: true,
          border: OutlineInputBorder(
            borderSide: BorderSide.none,
            borderRadius: BorderRadius.circular(AurisTheme.fieldRadius),
          ),
          prefixIcon: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
            child: Container(
              height: 45.0,
              width: 48.0,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AurisTheme.fieldRadius),
                color: AurisTheme.primary,
              ),
              child: widget.icon == null
                  ? null
                  : Icon(widget.icon, color: Colors.white, size: 20),
            ),
          ),
          suffixIcon: isPassword
              ? IconButton(
                  tooltip: _revealed ? 'Hide password' : 'Show password',
                  icon: Icon(
                    _revealed
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    color: AurisTheme.muted,
                  ),
                  onPressed: () => setState(() => _revealed = !_revealed),
                )
              : null,
          hintText: widget.textHint,
        ),
      ),
    );
  }
}
