import 'package:flutter/material.dart';

import 'tokens.dart';

/// 1px separator.
class Hairline extends StatelessWidget {
  const Hairline({super.key, this.vertical = false});
  final bool vertical;
  @override
  Widget build(BuildContext context) => vertical
      ? SizedBox(width: 1, child: ColoredBox(color: context.s.border))
      : SizedBox(height: 1, child: ColoredBox(color: context.s.border));
}

/// Hover + tap without Material ink. Works under MacosApp and MaterialApp alike.
class HoverRegion extends StatefulWidget {
  const HoverRegion({
    super.key,
    required this.builder,
    this.onTap,
    this.onDoubleTap,
    this.cursor = SystemMouseCursors.basic,
  });
  final Widget Function(BuildContext context, bool hovered) builder;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final MouseCursor cursor;
  @override
  State<HoverRegion> createState() => _HoverRegionState();
}

class _HoverRegionState extends State<HoverRegion> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.cursor,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onDoubleTap: widget.onDoubleTap,
      child: widget.builder(context, _hover),
    ),
  );
}

/// Section label: mono, uppercase, letter-spaced (Editor style).
class SectionLabel extends StatelessWidget {
  const SectionLabel(
    this.text, {
    super.key,
    this.padding = const EdgeInsets.fromLTRB(8, 14, 8, 4),
  });
  final String text;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Text(
      text.toUpperCase(),
      style: mono(
        context,
        size: 10.5,
        color: context.s.fg3,
        letterSpacing: 1.0,
      ),
    ),
  );
}

/// Mono tag chip with a hairline: `work`, `ci`.
class TagChip extends StatelessWidget {
  const TagChip(this.name, {super.key});
  final String name;
  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Container(
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        border: Border.all(color: s.border),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        name,
        style: mono(context, size: 10.5, color: s.tagColor(name), height: 1.0),
      ),
    );
  }
}

/// Key hint next to an action label.
class KeyHint extends StatelessWidget {
  const KeyHint(this.label, {super.key, this.color});
  final String label;
  final Color? color;
  @override
  Widget build(BuildContext context) => Text(
    label,
    style: mono(context, size: 10.5, color: color ?? context.s.fg3),
  );
}

/// Quiet icon button: 26px, hover fill only.
class IconBtn extends StatelessWidget {
  const IconBtn({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.size = 15,
    this.color,
    this.active = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final double size;
  final Color? color;
  final bool active;
  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Tooltip(
      message: label,
      child: HoverRegion(
        onTap: onTap,
        builder: (context, hovered) => Container(
          width: 28,
          height: 26,
          alignment: Alignment.center,
          decoration: (active || hovered)
              ? BoxDecoration(
                  color: active ? s.raised : s.hover,
                  borderRadius: BorderRadius.circular(5),
                )
              : null,
          child: Icon(
            icon,
            size: size,
            color: color ?? (active || hovered ? s.fg : s.fg2),
          ),
        ),
      ),
    );
  }
}

/// Text button; `primary` fills with the accent.
class SmallButton extends StatelessWidget {
  const SmallButton({
    super.key,
    required this.label,
    this.onPressed,
    this.primary = false,
    this.danger = false,
    this.hint,
    this.height = 24,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool primary;

  /// Filled red: the confirming step of something destructive.
  final bool danger;
  final String? hint;
  final double height;
  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final enabled = onPressed != null;
    return HoverRegion(
      onTap: onPressed,
      builder: (context, hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: primary || danger
              ? (danger ? s.red : s.blue).withValues(
                  alpha: enabled ? (hovered ? 0.9 : 1) : 0.5,
                )
              : (hovered ? s.hover : s.raised),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: primary || danger ? Colors.transparent : s.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: ui(
                context,
                size: 12.5,
                weight: FontWeight.w500,
                color: primary || danger ? s.bg : s.fg,
              ),
            ),
            if (hint != null) ...[
              const SizedBox(width: 8),
              KeyHint(
                hint!,
                color: primary || danger ? s.bg.withValues(alpha: 0.7) : s.fg3,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Text field in a hairline box.
class QuietField extends StatelessWidget {
  const QuietField({
    super.key,
    this.controller,
    this.focusNode,
    this.hint,
    this.leading,
    this.trailing,
    this.height = 28,
    this.autofocus = false,
    this.obscure = false,
    this.onChanged,
    this.onSubmitted,
    this.fontSize = 13,
  });
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? hint;
  final Widget? leading;
  final Widget? trailing;
  final double height;
  final bool autofocus;
  final bool obscure;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final double fontSize;
  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: s.raised,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: s.border),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 6)],
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                autofocus: autofocus,
                obscureText: obscure,
                autocorrect: false,
                enableSuggestions: false,
                style: ui(context, size: fontSize),
                cursorColor: s.fg,
                cursorWidth: 1.5,
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: hint,
                  hintStyle: ui(context, size: fontSize, color: s.fg3),
                ),
                onChanged: onChanged,
                onSubmitted: onSubmitted,
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 6), trailing!],
          ],
        ),
      ),
    );
  }
}

/// Neutral round avatar with initials.
class Avatar extends StatelessWidget {
  const Avatar(this.initials, {super.key, this.size = 28});
  final String initials;
  final double size;
  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: s.raised,
        shape: BoxShape.circle,
        border: Border.all(color: s.border),
      ),
      child: Text(
        initials,
        style: ui(
          context,
          size: size * 0.38,
          weight: FontWeight.w600,
          color: s.fg2,
        ),
      ),
    );
  }
}

/// Small filled circle: unread marker, label color.
class Dot extends StatelessWidget {
  const Dot({super.key, this.color, this.size = 8});
  final Color? color;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color ?? context.s.blue,
      shape: BoxShape.circle,
    ),
  );
}

/// Centered quiet text for empty panes.
class EmptyNote extends StatelessWidget {
  const EmptyNote(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Center(
    child: Text(text, style: ui(context, size: 15, color: context.s.fg3)),
  );
}
