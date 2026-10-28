import 'package:flutter/material.dart';

import '../theme.dart';

/// The app's pill-shaped primary button.
///
/// Same geometry and colour as the original screens; extended with disabled and
/// busy states so the auth and test flows can block double submissions.
class AurisButton extends StatelessWidget {
  const AurisButton({
    super.key,
    this.height = 59,
    this.width = 205,
    required this.buttonName,
    required this.onTap,
    this.busy = false,
    this.color,
  });

  final String buttonName;
  final double height;
  final double width;
  final VoidCallback? onTap;
  final bool busy;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !busy;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: height,
        width: width,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AurisTheme.pillRadius),
          color: enabled
              ? (color ?? AurisTheme.primary)
              : (color ?? AurisTheme.primary).withValues(alpha: 0.4),
        ),
        child: Center(
          child: busy
              ? const SizedBox(
                  height: 22,
                  width: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    valueColor: AlwaysStoppedAnimation(Colors.white),
                  ),
                )
              : Text(
                  buttonName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                    fontSize: 16.0,
                  ),
                ),
        ),
      ),
    );
  }
}

/// Secondary, outlined variant for non-destructive alternatives.
class AurisOutlineButton extends StatelessWidget {
  const AurisOutlineButton({
    super.key,
    required this.buttonName,
    required this.onTap,
    this.height = 52,
    this.width = 205,
    this.icon,
  });

  final String buttonName;
  final VoidCallback? onTap;
  final double height;
  final double width;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          height: height,
          width: width,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AurisTheme.pillRadius),
            border: Border.all(color: AurisTheme.primary, width: 1.4),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: AurisTheme.primary),
                const SizedBox(width: 8),
              ],
              Text(
                buttonName,
                style: const TextStyle(
                  color: AurisTheme.primary,
                  fontWeight: FontWeight.w600,
                  fontSize: 15.0,
                ),
              ),
            ],
          ),
        ),
      );
}
