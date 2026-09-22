import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../theme/motion.dart';
import '../../theme/tokens.dart';

/// Shows the transient notice ("Archived", "Saved to Downloads/…") above every route, just
/// over the status line, so it is visible on phones inside a pushed thread too.
class NoticeHost extends ConsumerWidget {
  const NoticeHost({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notice = ref.watch(noticeProvider);
    final bottom = MediaQuery.paddingOf(context).bottom + 34;
    return Stack(
      children: [
        child,
        Positioned(
          left: 16,
          right: 16,
          bottom: bottom,
          child: IgnorePointer(
            child: Center(
              child: AnimatedSwitcher(
                duration: Motion.of(context, Motion.base),
                switchInCurve: Motion.curve,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                    position: Tween(
                      begin: const Offset(0, 0.25),
                      end: Offset.zero,
                    ).animate(a),
                    child: child,
                  ),
                ),
                child: notice == null
                    ? const SizedBox.shrink(key: ValueKey('none'))
                    : _Pill(key: ValueKey(notice), text: notice),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: s.raised,
          border: Border.all(color: s.border),
          borderRadius: BorderRadius.circular(6),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Text(
          text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: mono(context, size: 12, color: s.fg),
        ),
      ),
    );
  }
}
