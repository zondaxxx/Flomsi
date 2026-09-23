import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../state/providers.dart';
import '../../theme/app_icons.dart';
import '../../theme/motion.dart';
import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';
import '../shell/shell_actions.dart';
import '../sidebar/sidebar_model.dart';
import '../thread/thread_view.dart';
import 'phone_bars.dart';
import 'phone_list_parts.dart';

/// The conversation a page shows, by its own id rather than the selection: a page opened
/// on top of it (a tapped notification) selects another one.
final _threadProvider = FutureProvider.autoDispose.family<Thread?, int>((
  ref,
  id,
) {
  ref.watch(repoTickProvider);
  return ref.watch(repositoryProvider).thread(id);
});

/// Views where Archive has nothing to take out of the Inbox: the bar offers Move instead.
const _moveViews = {
  FolderRole.archive,
  FolderRole.sent,
  FolderRole.junk,
  FolderRole.trash,
};

/// A conversation on its own page: back and star on top, the messages with a reply row
/// at the end, and a bar of Archive (or Move), Delete, Reply, Forward and More.
class PhoneThreadScreen extends ConsumerStatefulWidget {
  const PhoneThreadScreen({super.key, required this.threadId});
  final int threadId;

  @override
  ConsumerState<PhoneThreadScreen> createState() => _PhoneThreadScreenState();
}

class _PhoneThreadScreenState extends ConsumerState<PhoneThreadScreen> {
  final _more = MenuController();

  /// The messages are scrolled: a hairline sets the top bar off from them.
  bool _scrolled = false;

  /// Actions on this page's conversation, selected first since a page on top may have
  /// selected another. Filing, Mark as unread, Move and Snooze close the page before
  /// they run, so the list shows the row going and its Undo.
  ShellActions _actions() {
    ref.read(selectedThreadIdProvider.notifier).select(widget.threadId);
    return ShellActions(ref: ref, context: context, onLeave: _leave);
  }

  void _leave() {
    if (!mounted) return;
    if (ModalRoute.of(context)?.isCurrent ?? false) Navigator.of(context).pop();
  }

  void _retry() {
    ref.invalidate(_threadProvider(widget.threadId));
    ref.invalidate(messagesProvider(widget.threadId));
  }

  Future<void> _unsnooze() async {
    // Taken now: the page may be closed before the repository answers.
    final notice = ref.read(noticeProvider.notifier);
    await ref.read(repositoryProvider).unsnooze(widget.threadId);
    notice.show('Back in the inbox');
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final id = widget.threadId;
    final threadAsync = ref.watch(_threadProvider(id));
    final messagesAsync = ref.watch(messagesProvider(id));
    final thread = threadAsync.value;
    final messages = messagesAsync.value;
    final ready = thread != null && messages != null;

    final Widget body;
    if (ready) {
      body = ThreadContent(
        key: const ValueKey('content'),
        thread: thread,
        phone: true,
        onReply: () => _actions().openReply(),
      );
    } else if (threadAsync.hasValue &&
        thread == null &&
        !threadAsync.hasError) {
      // Loaded, and not there: filed or deleted on another device meanwhile.
      body = const PhoneEmpty(
        key: ValueKey('gone'),
        title: 'This conversation is no longer here',
        detail: 'It was moved or deleted',
      );
    } else if (threadAsync.hasError || messagesAsync.hasError) {
      body = PhoneEmpty(
        key: const ValueKey('error'),
        title: 'Couldn’t open this message',
        action: 'Try again',
        onAction: _retry,
      );
    } else {
      body = const DelayedSpinner(key: ValueKey('loading'));
    }

    // The mailbox the page was opened from decides Archive or Move, and Delete in Trash.
    final base = withoutFilter(
      ref.watch(queryProvider),
      ref.watch(listFilterProvider),
    );
    final role = parseMailbox(base)?.role;
    final backTitle = mailboxTitle(base);
    final allowed = ref.watch(remoteImagesProvider(id));
    final blocked = [
      for (final m in messages ?? const <Message>[])
        if (m.blockedImages > 0 && !allowed.contains(m.id)) m.id,
    ];
    // Reply all only where the last message went to several people.
    final replyAll = (messages?.lastOrNull?.to.length ?? 0) > 1;

    // Back closes the More menu before it leaves the conversation.
    return PopScope(
      canPop: !_more.isOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _more.close();
      },
      child: Scaffold(
        backgroundColor: s.bg,
        appBar: _TopBar(
          scrolled: _scrolled && ready,
          backTitle: backTitle,
          starred: thread?.starred ?? false,
          onStar: ready ? () => _actions().toggleStar() : null,
        ),
        body: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.depth == 0 && n.metrics.axis == Axis.vertical) {
              final scrolled = n.metrics.pixels > 0;
              if (scrolled != _scrolled) setState(() => _scrolled = scrolled);
            }
            return false;
          },
          child: SafeArea(
            top: false,
            bottom: false,
            child: AnimatedSwitcher(
              duration: Motion.of(context, Motion.base),
              child: body,
            ),
          ),
        ),
        bottomNavigationBar: PhoneBottomBar(
          items: [
            if (_moveViews.contains(role))
              BarItem(
                icon: AppIcons.move,
                label: 'Move',
                onTap: ready ? () => _actions().moveSelected() : null,
              )
            else
              BarItem(
                icon: AppIcons.archive,
                label: 'Archive',
                onTap: ready ? () => _actions().archiveSelected() : null,
              ),
            BarItem(
              icon: AppIcons.delete,
              label: 'Delete',
              // Already in Trash: there is nowhere further to put it.
              onTap: ready && role != FolderRole.trash
                  ? () => _actions().trashSelected()
                  : null,
            ),
            BarItem(
              icon: AppIcons.reply,
              label: 'Reply',
              onTap: ready ? () => _actions().openReply() : null,
            ),
            BarItem(
              icon: AppIcons.forward,
              label: 'Forward',
              onTap: ready ? () => _actions().openForward() : null,
            ),
            BarItem(
              icon: AppIcons.moreBar,
              label: 'More',
              menuController: _more,
              onMenuChanged: () {
                if (mounted) setState(() {});
              },
              menu: !ready
                  ? const []
                  : [
                      if (replyAll)
                        PhoneMenuItem(
                          title: 'Reply all',
                          leading: Icon(AppIcons.replyAll, size: 20),
                          onPressed: () => _actions().openReply(all: true),
                        ),
                      PhoneMenuItem(
                        title: 'Mark as unread',
                        leading: Icon(AppIcons.unread, size: 20),
                        onPressed: () => _actions().markUnread(),
                      ),
                      PhoneMenuItem(
                        title: 'Move to…',
                        leading: Icon(AppIcons.move, size: 20),
                        onPressed: () => _actions().moveSelected(),
                      ),
                      if (thread.snoozed)
                        PhoneMenuItem(
                          title: 'Unsnooze',
                          leading: Icon(AppIcons.snooze, size: 20),
                          onPressed: _unsnooze,
                        )
                      else
                        PhoneMenuItem(
                          title: 'Snooze…',
                          leading: Icon(AppIcons.snooze, size: 20),
                          onPressed: () => _actions().snoozeSelected(),
                        ),
                      if (blocked.isNotEmpty)
                        PhoneMenuItem(
                          title: 'Load images',
                          leading: Icon(AppIcons.images, size: 20),
                          onPressed: () => ref
                              .read(remoteImagesProvider(id).notifier)
                              .allow(blocked),
                        ),
                    ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Back on the left, the star on the right; a hairline under it once the messages
/// scroll. On iOS the back chevron carries the name of the screen underneath, as the
/// system's own back button does.
class _TopBar extends StatelessWidget implements PreferredSizeWidget {
  const _TopBar({
    required this.scrolled,
    required this.backTitle,
    required this.starred,
    required this.onStar,
  });
  final bool scrolled;

  /// The mailbox the page was opened from: Inbox, Archive, a label, Search.
  final String backTitle;
  final bool starred;
  final VoidCallback? onStar;

  @override
  Size get preferredSize => const Size.fromHeight(Touch.appBar);

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final ink = s.isDark ? Brightness.light : Brightness.dark;
    final ios = defaultTargetPlatform == TargetPlatform.iOS;
    void back() => Navigator.of(context).maybePop();
    return AppBar(
      backgroundColor: s.bg,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      toolbarHeight: Touch.appBar,
      automaticallyImplyLeading: false,
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: ink,
        statusBarBrightness: s.brightness,
        systemNavigationBarColor: s.bg2,
        systemNavigationBarIconBrightness: ink,
      ),
      shape: scrolled ? Border(bottom: BorderSide(color: s.border)) : null,
      leading: ios
          ? null
          : IconButton(
              tooltip: 'Back',
              icon: Icon(AppIcons.back, color: s.fg),
              onPressed: back,
            ),
      // The back button is not a heading, and sits at the start on iOS too.
      title: ios ? _IosBack(title: backTitle, onTap: back) : null,
      titleSpacing: 4,
      centerTitle: false,
      excludeHeaderSemantics: true,
      actions: [
        IconButton(
          tooltip: starred ? 'Remove star' : 'Star',
          onPressed: onStar,
          icon: AnimatedSwitcher(
            duration: Motion.of(context, Motion.fast),
            child: Icon(
              starred ? AppIcons.starOn : AppIcons.star,
              key: ValueKey(starred),
              color: starred ? s.yellow : s.fg,
            ),
          ),
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}

/// iOS's back button: the chevron and the previous screen's name, dimmed while pressed.
/// A long name gives way before the star does.
class _IosBack extends StatelessWidget {
  const _IosBack({required this.title, required this.onTap});
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Semantics(
      button: true,
      label: 'Back to $title',
      onTap: onTap,
      excludeSemantics: true,
      child: HoverRegion(
        onTap: onTap,
        builder: (context, pressed) => AnimatedOpacity(
          opacity: pressed ? 0.5 : 1,
          duration: Motion.of(context, Motion.fast),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: Touch.target,
              minHeight: Touch.target,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(AppIcons.back, color: s.fg),
                ),
                Flexible(
                  child: MediaQuery.withClampedTextScaling(
                    maxScaleFactor: 1.3,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ui(context, size: 17),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
