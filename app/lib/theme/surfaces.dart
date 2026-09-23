import 'package:flutter/material.dart';

import '../platform.dart';
import 'app_icons.dart';
import 'motion.dart';
import 'tokens.dart';

/// 1px separator, across the whole width (or height) it is given.
class Hairline extends StatelessWidget {
  const Hairline({super.key, this.vertical = false});
  final bool vertical;
  @override
  Widget build(BuildContext context) => vertical
      ? SizedBox(
          width: 1,
          height: double.infinity,
          child: ColoredBox(color: context.s.border),
        )
      : SizedBox(
          height: 1,
          width: double.infinity,
          child: ColoredBox(color: context.s.border),
        );
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

  /// A finger on it: touch screens show the same highlight while pressed.
  bool _pressed = false;

  void _press(bool on) {
    if (!kTouch || widget.onTap == null || _pressed == on) return;
    setState(() => _pressed = on);
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.cursor,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onTapDown: (_) => _press(true),
      onTapUp: (_) => _press(false),
      onTapCancel: () => _press(false),
      onDoubleTap: widget.onDoubleTap,
      child: widget.builder(context, _hover || _pressed),
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
    // Fingers need 48: the same glyph, a larger place to press.
    final touch = kTouch;
    return Tooltip(
      message: label,
      child: HoverRegion(
        onTap: onTap,
        builder: (context, hovered) => Container(
          width: touch ? Touch.target : 28,
          height: touch ? Touch.target : 26,
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
        height: kTouch && height < 44 ? 44 : height,
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
          mainAxisAlignment: MainAxisAlignment.center,
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

/// Text field in a hairline box. On touch screens it is at least 48 tall, and it tells the
/// keyboard what it is for (type, return key, autofill).
class QuietField extends StatefulWidget {
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
    this.keyboardType,
    this.textInputAction,
    this.autofillHints,
    this.onEditingComplete,
    this.textCapitalization = TextCapitalization.none,
    this.autocorrect = false,
    this.enableSuggestions = false,
    this.reveal = false,
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
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final VoidCallback? onEditingComplete;
  final TextCapitalization textCapitalization;
  final bool autocorrect;
  final bool enableSuggestions;

  /// With [obscure]: an eye to show what was typed.
  final bool reveal;

  @override
  State<QuietField> createState() => _QuietFieldState();
}

class _QuietFieldState extends State<QuietField> {
  bool _shown = false;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final w = widget;
    final touch = kTouch;
    final size = touch && w.fontSize < 16 ? 16.0 : w.fontSize;
    final trailing = w.obscure && w.reveal
        ? IconBtn(
            icon: _shown ? AppIcons.hide : AppIcons.reveal,
            label: _shown ? 'Hide password' : 'Show password',
            size: 18,
            onTap: () => setState(() => _shown = !_shown),
          )
        : w.trailing;
    return Container(
      constraints: BoxConstraints(
        minHeight: touch ? Touch.target : w.height,
        maxHeight: touch ? double.infinity : w.height,
      ),
      padding: EdgeInsets.symmetric(horizontal: touch ? 12 : 8),
      decoration: BoxDecoration(
        color: s.raised,
        borderRadius: BorderRadius.circular(touch ? Touch.radius : 6),
        border: Border.all(color: s.border),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Row(
          children: [
            if (w.leading != null) ...[w.leading!, const SizedBox(width: 6)],
            Expanded(
              child: TextField(
                controller: w.controller,
                focusNode: w.focusNode,
                autofocus: w.autofocus,
                obscureText: w.obscure && !_shown,
                keyboardType: w.keyboardType,
                textInputAction: w.textInputAction,
                autofillHints: w.autofillHints,
                onEditingComplete: w.onEditingComplete,
                textCapitalization: w.textCapitalization,
                autocorrect: w.autocorrect,
                enableSuggestions: w.enableSuggestions,
                style: ui(context, size: size),
                cursorColor: s.fg,
                cursorWidth: 1.5,
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(
                    vertical: touch ? 12 : 0,
                  ),
                  hintText: w.hint,
                  hintStyle: ui(context, size: size, color: s.fg3),
                ),
                onChanged: w.onChanged,
                onSubmitted: w.onSubmitted,
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 6), trailing],
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

/// Segmented choice in the editor style: mono labels, the chosen one raised.
class Segmented<T> extends StatelessWidget {
  const Segmented({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.height = 26,
  });
  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;
  final double height;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    // Fingers: 40 to see, 48 to press, and the words in reading type.
    final touch = kTouch;
    final h = touch && height < 40 ? 40.0 : height;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: EdgeInsets.all(touch ? 4 : 2),
        decoration: BoxDecoration(
          border: Border.all(color: s.border),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (v, label) in options)
              HoverRegion(
                onTap: () => onChanged(v),
                builder: (context, hovered) => AnimatedContainer(
                  duration: Motion.of(context, Motion.fast),
                  curve: Motion.curve,
                  height: h,
                  padding: EdgeInsets.symmetric(horizontal: touch ? 16 : 12),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: v == value
                        ? s.raised
                        : (hovered ? s.hover : Colors.transparent),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Semantics(
                    selected: v == value,
                    button: true,
                    child: Text(
                      label,
                      style: touch
                          ? ui(
                              context,
                              size: 15,
                              weight: v == value
                                  ? FontWeight.w500
                                  : FontWeight.w400,
                              color: v == value ? s.fg : s.fg2,
                            )
                          : mono(
                              context,
                              size: 12,
                              color: v == value ? s.fg : s.fg2,
                            ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Scrolls its child into view when it becomes selected: the row j/k or the arrow keys
/// move to never sits outside the list.
class RevealOnSelect extends StatefulWidget {
  const RevealOnSelect({
    super.key,
    required this.selected,
    required this.child,
  });
  final bool selected;
  final Widget child;

  @override
  State<RevealOnSelect> createState() => _RevealOnSelectState();
}

class _RevealOnSelectState extends State<RevealOnSelect> {
  // Only a change of selection scrolls: a row that is built while already selected
  // (the list grew above it) stays where the reader left it.
  @override
  void didUpdateWidget(RevealOnSelect old) {
    super.didUpdateWidget(old);
    if (widget.selected && !old.selected) _reveal();
  }

  void _reveal() => WidgetsBinding.instance.addPostFrameCallback((_) async {
    if (!mounted) return;
    final duration = Motion.of(context, Motion.fast);
    // Below the fold: bring it up to the bottom edge; above: down to the top edge.
    await Scrollable.ensureVisible(
      context,
      duration: duration,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    );
    if (!mounted) return;
    await Scrollable.ensureVisible(
      context,
      duration: duration,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
    );
  });

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A small question in the editor style: a title, a line of explanation, Cancel and one
/// action. Returns true when the action was chosen. Esc and a click outside cancel.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
  bool danger = false,
  bool cancel = true,
  String cancelLabel = 'Cancel',
}) async {
  final touch = kTouch;
  final chosen = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: cancelLabel,
    barrierColor: Colors.black.withValues(alpha: 0.25),
    transitionDuration: Motion.of(context, Motion.fast),
    transitionBuilder: (context, a, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: a, curve: Motion.curve),
      child: ScaleTransition(
        scale: Tween(
          begin: 0.98,
          end: 1.0,
        ).animate(CurvedAnimation(parent: a, curve: Motion.curve)),
        child: child,
      ),
    ),
    pageBuilder: (context, _, _) {
      final s = context.s;
      final width = MediaQuery.sizeOf(context).width;
      return Center(
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            width: (width - 32).clamp(260.0, 420.0),
            padding: touch
                ? const EdgeInsets.fromLTRB(20, 20, 12, 8)
                : const EdgeInsets.fromLTRB(18, 16, 18, 14),
            decoration: BoxDecoration(
              color: s.bg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: s.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: s.isDark ? 0.5 : 0.18),
                  blurRadius: 30,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.only(right: touch ? 8 : 0),
                  child: Text(
                    title,
                    style: ui(
                      context,
                      size: touch ? 17 : 14,
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
                SizedBox(height: touch ? 8 : 6),
                Padding(
                  padding: EdgeInsets.only(right: touch ? 8 : 0),
                  child: Text(
                    body,
                    style: ui(
                      context,
                      size: touch ? 15 : 12.5,
                      color: s.fg2,
                      height: 1.45,
                    ),
                  ),
                ),
                SizedBox(height: touch ? 12 : 16),
                // Fingers get the phone's own buttons, 48 tall.
                if (touch)
                  Wrap(
                    alignment: WrapAlignment.end,
                    children: [
                      if (cancel)
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: Text(cancelLabel),
                        ),
                      TextButton(
                        style: danger
                            ? TextButton.styleFrom(foregroundColor: s.red)
                            : null,
                        onPressed: () => Navigator.of(context).pop(true),
                        child: Text(action),
                      ),
                    ],
                  )
                else
                  Row(
                    children: [
                      const Spacer(),
                      if (cancel) ...[
                        SmallButton(
                          label: cancelLabel,
                          onPressed: () => Navigator.of(context).pop(false),
                        ),
                        const SizedBox(width: 8),
                      ],
                      SmallButton(
                        label: action,
                        primary: !danger,
                        danger: danger,
                        onPressed: () => Navigator.of(context).pop(true),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
  return chosen ?? false;
}
