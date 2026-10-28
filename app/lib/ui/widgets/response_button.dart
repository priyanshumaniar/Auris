import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// The button the patient presses and holds while they hear a tone.
///
/// ASHA (2005) asks the patient to respond when the tone starts and again when
/// it stops. Press-and-hold does both: [onPressed] fires when the finger (or
/// mouse button) goes down, [onReleased] when it comes up. The release is
/// always reported, even while the button is disabled, so the test never
/// believes the button is still held.
///
/// ## What it may and may not show
///
/// It must give strong, immediate feedback that a press *registered* - the
/// previous version gave none, so a patient could not tell whether their press
/// had counted, and an unsure patient presses again, or stops trusting the
/// task.
///
/// It must **not** reveal anything about the stimulus. No indication that a
/// tone is playing, no level, no timing cue. A patient who can see when a tone
/// is presented will press every time and the whole audiogram becomes a record
/// of their eyesight.
///
/// The ambient animation therefore runs on its own fixed rhythm, deliberately
/// unrelated to stimulus timing, so it can never be read as a hint.
class ResponseButton extends StatefulWidget {
  const ResponseButton({
    super.key,
    required this.onPressed,
    required this.onReleased,
    this.enabled = true,
    this.size = 220,
  });

  final VoidCallback onPressed;
  final VoidCallback onReleased;
  final bool enabled;
  final double size;

  @override
  State<ResponseButton> createState() => _ResponseButtonState();
}

class _ResponseButtonState extends State<ResponseButton>
    with TickerProviderStateMixin {
  /// Slow, continuous "the app is listening" motion. Fixed period, never
  /// synchronised with tone presentation.
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat(reverse: true);

  /// Fires on every press: a ripple that expands and fades.
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  );

  /// Quick squash on touch-down so the button feels physical.
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 110),
    lowerBound: 0.0,
    upperBound: 0.06,
  );

  @override
  void dispose() {
    _ambient.dispose();
    _ripple.dispose();
    _press.dispose();
    super.dispose();
  }

  bool _down = false;

  void _handleDown() {
    if (!widget.enabled || _down) return;
    _down = true;
    _press.forward();
    _ripple.forward(from: 0);
    widget.onPressed();
  }

  void _handleUp() {
    _press.reverse();
    if (!_down) return;
    _down = false;
    widget.onReleased();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final outer = widget.size * 1.6;

    // The face of the button never changes while it is shown, so it is built
    // once here and only scaled below. The ambient halo and the ripple each
    // animate on their own, inside a repaint boundary, rather than rebuilding
    // the whole button (gradient and shadow included) on every frame of the
    // test.
    final face = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: enabled
              ? [
                  AurisTheme.primary,
                  Color.lerp(AurisTheme.primary, AurisTheme.accent, 0.55)!,
                ]
              : [
                  AurisTheme.primary.withValues(alpha: 0.32),
                  AurisTheme.accent.withValues(alpha: 0.32),
                ],
        ),
        boxShadow: enabled
            ? [
                BoxShadow(
                  color: AurisTheme.primary.withValues(alpha: 0.27),
                  blurRadius: 34,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.hearing_rounded,
            size: widget.size * 0.26,
            color: Colors.white,
          ),
          const SizedBox(height: 10),
          Text(
            'Hold while\nyou hear it',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: widget.size * 0.10,
              fontWeight: FontWeight.w600,
              color: Colors.white,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );

    return Semantics(
      button: true,
      label: 'I hear a tone',
      // Screen readers activate with a tap: treat it as a short press.
      onTap: enabled
          ? () {
              _handleDown();
              _handleUp();
            }
          : null,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _handleDown(),
        onPointerUp: (_) => _handleUp(),
        onPointerCancel: (_) => _handleUp(),
        child: SizedBox(
          width: outer,
          height: outer,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Press ripple: expands outwards and fades.
              RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _ripple,
                  builder: (context, _) => _ripple.isAnimating
                      ? CustomPaint(
                          size: Size.square(outer),
                          painter: _RipplePainter(
                            progress: Curves.easeOut.transform(_ripple.value),
                            color: AurisTheme.primary,
                            innerRadius: widget.size / 2,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),

              // Ambient halo. Fixed 3 s period, no relation to the tones.
              RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _ambient,
                  builder: (context, _) {
                    final ambient = Curves.easeInOut.transform(_ambient.value);
                    return Container(
                      width: widget.size + 34 + ambient * 12,
                      height: widget.size + 34 + ambient * 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AurisTheme.primary.withValues(
                            alpha: enabled ? 0.06 + ambient * 0.04 : 0.03),
                      ),
                    );
                  },
                ),
              ),

              AnimatedBuilder(
                animation: _press,
                child: face,
                builder: (context, child) =>
                    Transform.scale(scale: 1.0 - _press.value, child: child),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RipplePainter extends CustomPainter {
  _RipplePainter({
    required this.progress,
    required this.color,
    required this.innerRadius,
  });

  final double progress;
  final Color color;
  final double innerRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final maxRadius = math.min(size.width, size.height) / 2;
    final radius = innerRadius + (maxRadius - innerRadius) * progress;

    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..color = color.withValues(alpha: (1 - progress) * 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5 * (1 - progress) + 1,
    );
  }

  @override
  bool shouldRepaint(_RipplePainter old) => old.progress != progress;
}

/// Brief "got it" confirmation shown after each press.
///
/// Confirms the press was received without saying whether a tone was actually
/// presented - a patient pressing at random gets exactly the same confirmation
/// as one responding correctly.
class ResponseAcknowledgement extends StatelessWidget {
  const ResponseAcknowledgement({super.key, required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_rounded,
                size: 17, color: AurisTheme.success),
            const SizedBox(width: 7),
            Text(
              'Got it',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AurisTheme.success.withValues(alpha: 0.95),
              ),
            ),
          ],
        ),
      );
}
