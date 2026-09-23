import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../theme/app_icons.dart';
import '../../theme/motion.dart';
import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';
import '../thread/snooze.dart';

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
  });
  final Thread thread;
  final bool selected;

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
    return Semantics(
      button: true,
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
                  child: Column(
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
                            Icon(AppIcons.starOn, size: 12, color: s.yellow),
                          ],
                          if (t.hasAttachment) ...[
                            const SizedBox(width: 6),
                            Icon(AppIcons.attach, size: 13, color: s.fg2),
                          ],
                          if (t.msgCount > 1) ...[
                            const SizedBox(width: 6),
                            Text(
                              '${t.msgCount}',
                              style: mono(context, size: 12.5, color: s.fg2),
                            ),
                          ],
                          const SizedBox(width: 8),
                          if (t.snoozed) ...[
                            Icon(AppIcons.snooze, size: 12, color: s.yellow),
                            const SizedBox(width: 3),
                          ],
                          Text(
                            time,
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
                          weight: unread ? FontWeight.w500 : FontWeight.w400,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        t.snippet,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ui(context, size: 14, color: s.fg2, height: 1.3),
                      ),
                    ],
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
