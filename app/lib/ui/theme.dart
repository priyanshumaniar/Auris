import 'package:flutter/material.dart';

/// The app's visual language.
///
/// These tokens are lifted from the original screens rather than invented - the
/// off-white background, the blue pill buttons, the rounded white input fields
/// with a coloured prefix block, and the cyan stepper accent were already the
/// look of the app. Centralising them here lets the new screens match the old
/// ones instead of drifting.
class AurisTheme {
  AurisTheme._();

  static const background = Color(0xFFFBFBFD);
  static const surface = Colors.white;

  /// Primary action colour - the existing pill buttons and input prefixes.
  static const primary = Color(0xFF2196F3);

  /// Stepper / accent colour from the original audiometer controls.
  static const accent = Color(0xFF34C2DB);

  static const ink = Color(0xFF1B2A32);
  static const muted = Color(0xFF5A6B75);
  static const hairline = Color(0xFFE3E8EC);

  /// Clinical audiogram colours - red right, blue left.
  static const rightEar = Color(0xFFD32F2F);
  static const leftEar = Color(0xFF1976D2);

  static const warning = Color(0xFFE0A458);
  static const warningSurface = Color(0xFFFFF4E5);
  static const success = Color(0xFF2E7D5B);

  static const cardRadius = 14.0;
  static const fieldRadius = 10.0;
  static const pillRadius = 133.0;

  static ThemeData light() {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primary,
        primary: primary,
        surface: surface,
      ),
    );

    return base.copyWith(
      scaffoldBackgroundColor: background,
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: ink),
        titleTextStyle: TextStyle(
          color: ink,
          fontSize: 19,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          side: const BorderSide(color: hairline),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(
          borderSide: BorderSide.none,
          borderRadius: BorderRadius.circular(fieldRadius),
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: hairline),
          borderRadius: BorderRadius.circular(fieldRadius),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: primary, width: 1.6),
          borderRadius: BorderRadius.circular(fieldRadius),
        ),
      ),
      dividerTheme: const DividerThemeData(color: hairline, thickness: 1),
      textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
    );
  }
}

/// Section label used across the new screens.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          letterSpacing: 0.9,
          fontWeight: FontWeight.w700,
          color: AurisTheme.muted,
        ),
      );
}

/// A bordered white panel - the standard container for content on the
/// off-white background.
class AurisCard extends StatelessWidget {
  const AurisCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
  });

  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AurisTheme.surface,
        borderRadius: BorderRadius.circular(AurisTheme.cardRadius),
        border: Border.all(color: AurisTheme.hairline),
      ),
      child: child,
    );

    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AurisTheme.cardRadius),
      child: content,
    );
  }
}

/// The amber banner shown wherever an uncalibrated result could be mistaken for
/// a clinical measurement.
class CalibrationWarning extends StatelessWidget {
  const CalibrationWarning({
    super.key,
    this.message =
        'This device is not calibrated. The shape of the audiogram is '
            'meaningful, but absolute dB HL values are not - treat results as '
            'screening only.',
    this.onOpenSettings,
  });

  final String message;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AurisTheme.warningSurface,
          borderRadius: BorderRadius.circular(AurisTheme.cardRadius),
          border: Border.all(color: AurisTheme.warning),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber_rounded,
                color: AurisTheme.warning, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(message,
                      style: const TextStyle(
                          fontSize: 12.5, height: 1.4, color: AurisTheme.ink)),
                  if (onOpenSettings != null) ...[
                    const SizedBox(height: 6),
                    GestureDetector(
                      onTap: onOpenSettings,
                      child: const Text(
                        'Calibrate this device →',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: AurisTheme.warning,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
}
