import 'package:flutter/material.dart';

/// Motion tokens. Short, eased, and gone when the OS asks for reduced motion.
abstract final class Motion {
  static const fast = Duration(milliseconds: 120);
  static const base = Duration(milliseconds: 180);
  static const slow = Duration(milliseconds: 260);
  static const curve = Curves.easeOutCubic;

  static Duration of(BuildContext context, Duration d) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : d;
}

/// Fade + 6px rise, used for content that appears in place (reading pane, palette, rows).
class Appear extends StatelessWidget {
  const Appear({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = Motion.base,
    this.dy = 6,
  });
  final Widget child;
  final Duration delay;
  final Duration duration;
  final double dy;

  @override
  Widget build(BuildContext context) {
    final total = Motion.of(context, duration + delay);
    if (total == Duration.zero) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      curve: Interval(
        delay.inMilliseconds / total.inMilliseconds,
        1,
        curve: Motion.curve,
      ),
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * dy),
          child: child,
        ),
      ),
    );
  }
}
