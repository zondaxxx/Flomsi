import 'package:flutter/semantics.dart';
import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../theme/app_icons.dart';
import '../../theme/motion.dart';
import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';
import '../thread/snooze.dart';
import 'phone_bars.dart';

/// A conversation in the phone list: who, what, the first words, and when. Three lines,
/// at least 76 tall; unread in bold with a dot.
class PhoneThreadRow extends StatelessWidget {
  const PhoneThreadRow({
    super.key,
    required this.thread,
    this.selected = false,
    this.accountColor,
    this.onTap,
    this.onLongPress,
    this.actions = const {},
  });
  final Thread thread;
  final bool selected;

  /// What a screen reader offers besides opening it (Archive, Delete, Reply, More actions),
  /// since it cannot swipe.
  final Map<CustomSemanticsAction, VoidCallback> actions;

  /// The account's colour, when several accounts share the list.
  final Color? accountColor;
  final VoidCallback? onTap;
  final void Function(Offset position)? onLongPress;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = thread;
    final unread = t.unread;
    final time = t.snoozed
        ? snoozeLabel(t.snoozedUntil!, DateTime.now())
        : formatWhen(t.lastDate);
    void menuAtCentre() {
      final box = context.findRenderObject() as RenderBox?;
      if (box != null) {
        onLongPress?.call(box.localToGlobal(box.size.center(Offset.zero)));
      }
    }

    return Semantics(
      button: true,
      onTap: onTap,
      onLongPress: onLongPress == null ? null : menuAtCentre,
      customSemanticsActions: {
        ...actions,
        if (onLongPress != null)
          const CustomSemanticsAction(label: 'More actions'): menuAtCentre,
      },
      label: [
        if (unread) 'Unread',
        t.sender,
        t.subject,
        t.snippet,
        time,
      ].join('. '),
      excludeSemantics: true,
      child: HoverRegion(
        onTap: onTap,
        builder: (context, pressed) => GestureDetector(
          onLongPressStart: onLongPress == null
              ? null
              : (d) => onLongPress!(d.globalPosition),
          child: AnimatedContainer(
            duration: Motion.of(context, Motion.fast),
            constraints: const BoxConstraints(minHeight: Touch.threadRow),
            color: selected
                ? s.selected
                : pressed
                ? s.hover
                : Colors.transparent,
            padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 16,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: AnimatedScale(
                      scale: unread ? 1 : 0,
                      duration: Motion.of(context, Motion.fast),
                      child: const Dot(size: 8),
                    ),
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) {
                      final width = c.maxWidth;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  t.sender.isEmpty ? '(no sender)' : t.sender,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: ui(
                                    context,
                                    size: 16,
                                    weight: unread
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    height: 1.3,
                                  ),
                                ),
                              ),
                              if (accountColor != null) ...[
                                const SizedBox(width: 6),
                                Dot(color: accountColor, size: 6),
                              ],
                              if (t.starred) ...[
                                const SizedBox(width: 6),
                                Icon(
                                  AppIcons.starOn,
                                  size: 12,
                                  color: s.yellow,
                                ),
                              ],
                              if (t.hasAttachment) ...[
                                const SizedBox(width: 6),
                                Icon(AppIcons.attach, size: 13, color: s.fg2),
                              ],
                              if (t.msgCount > 1) ...[
                                const SizedBox(width: 6),
                                Text(
                                  '${t.msgCount}',
                                  style: mono(
                                    context,
                                    size: 12.5,
                                    color: s.fg2,
                                  ),
                                ),
                              ],
                              const SizedBox(width: 8),
                              if (t.snoozed) ...[
                                Icon(
                                  AppIcons.snooze,
                                  size: 12,
                                  color: s.yellow,
                                ),
                                const SizedBox(width: 3),
                              ],
                              // Large text: the time gives way before the sender does.
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: width * 0.45,
                                ),
                                child: Text(
                                  time,
                                  maxLines: 1,
                                  softWrap: false,
                                  overflow: TextOverflow.ellipsis,
                                  style: mono(
                                    context,
                                    size: 12.5,
                                    color: t.snoozed
                                        ? s.yellow
                                        : unread
                                        ? s.fg
                                        : s.fg2,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            t.subject.isEmpty ? '(no subject)' : t.subject,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ui(
                              context,
                              size: 15,
                              weight: unread
                                  ? FontWeight.w500
                                  : FontWeight.w400,
                              height: 1.3,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            t.snippet,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ui(
                              context,
                              size: 14,
                              color: s.fg2,
                              height: 1.3,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A draft kept on this phone, at the list's sizes: "Draft", who it is to, the subject
/// and its first words. Its trash opens a menu, so one stray tap deletes nothing.
class PhoneDraftRow extends StatelessWidget {
  const PhoneDraftRow({
    super.key,
    required this.draft,
    required this.onTap,
    required this.onDelete,
  });
  final Draft draft;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final d = draft;
    final to = d.to.isEmpty ? 'No recipients' : d.to.join(', ');
    final body = d.text.trim().split('\n').first;
    return HoverRegion(
      onTap: onTap,
      builder: (context, pressed) => Container(
        constraints: const BoxConstraints(minHeight: Touch.threadRow),
        color: pressed ? s.hover : Colors.transparent,
        padding: const EdgeInsets.fromLTRB(28, 12, 4, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text(
                        'Draft',
                        style: ui(context, size: 13, color: s.red, height: 1.3),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          to,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ui(
                            context,
                            size: 16,
                            color: d.to.isEmpty ? s.fg2 : s.fg,
                            height: 1.3,
                          ),
                        ),
                      ),
                      if (d.attachments.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Icon(AppIcons.attach, size: 13, color: s.fg2),
                      ],
                      if (d.savedAt != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          formatWhen(d.savedAt!.toLocal()),
                          style: mono(context, size: 12.5, color: s.fg2),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    d.subject.isEmpty ? '(no subject)' : d.subject,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ui(
                      context,
                      size: 15,
                      color: d.subject.isEmpty ? s.fg2 : s.fg,
                      height: 1.3,
                    ),
                  ),
                  if (body.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      body,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ui(context, size: 14, color: s.fg2, height: 1.3),
                    ),
                  ],
                ],
              ),
            ),
            MenuAnchor(
              consumeOutsideTap: true,
              menuChildren: [
                PhoneMenuItem(
                  title: 'Delete draft',
                  danger: true,
                  leading: Icon(AppIcons.delete, size: 20, color: s.red),
                  onPressed: onDelete,
                ),
              ],
              builder: (context, controller, _) => IconButton(
                tooltip: 'Draft actions',
                icon: Icon(AppIcons.delete, size: 20, color: s.fg2),
                onPressed: () =>
                    controller.isOpen ? controller.close() : controller.open(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
