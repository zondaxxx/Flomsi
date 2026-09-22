import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../keymap/key_scope.dart';
import '../../state/appearance.dart';
import '../../state/providers.dart';
import '../accounts/add_account_sheet.dart';
import '../list/thread_list.dart';
import '../palette/command_palette.dart';

/// Keyboard actions and palette commands shared by every shell.
class ShellActions {
  ShellActions({
    required this.ref,
    required this.context,
    this.listKey,
    this.onOpen,
  });
  final WidgetRef ref;
  final BuildContext context;
  final GlobalKey<ThreadListBodyState>? listKey;
  final VoidCallback? onOpen;

  Future<void> move(int delta) async {
    final threads = ref.read(threadsProvider).asData?.value;
    if (threads == null || threads.isEmpty) return;
    final cur = ref.read(selectedThreadIdProvider);
    final i = threads.indexWhere((t) => t.id == cur);
    final next = (i < 0
        ? (delta > 0 ? 0 : threads.length - 1)
        : (i + delta).clamp(0, threads.length - 1));
    ref.read(selectedThreadIdProvider.notifier).select(threads[next].id);
  }

  Future<void> withSelected(
    Future<void> Function(int id) f, {
    bool advance = false,
  }) async {
    final id = ref.read(selectedThreadIdProvider);
    if (id == null) return;
    if (advance) await move(1);
    await f(id);
  }

  Future<void> toggleStar() => withSelected((id) async {
    final repo = ref.read(repositoryProvider);
    final t = await repo.thread(id);
    if (t != null) await repo.star(id, !t.starred);
  });

  Future<void> openReply({bool all = false}) => withSelected((id) async {
    final d = await ref.read(repositoryProvider).replyDraft(id, all: all);
    ref.read(composeProvider.notifier).open(d);
    onOpen?.call();
  });

  Future<void> openForward() => withSelected((id) async {
    final d = await ref.read(repositoryProvider).forwardDraft(id);
    ref.read(composeProvider.notifier).open(d);
    onOpen?.call();
  });

  Future<void> openNew() async {
    try {
      final d = await ref.read(repositoryProvider).newDraft();
      ref.read(composeProvider.notifier).open(d);
      onOpen?.call();
    } catch (e) {
      ref.read(noticeProvider.notifier).show('Add an account first');
    }
  }

  Future<void> archiveSelected() async {
    await withSelected(ref.read(repositoryProvider).archive, advance: true);
    ref.read(noticeProvider.notifier).show('Archived');
  }

  Future<void> trashSelected() async {
    await withSelected(ref.read(repositoryProvider).trash, advance: true);
    ref.read(noticeProvider.notifier).show('Deleted');
  }

  Map<String, ActionHandler> keymap() {
    return {
      'nav.next': () => move(1),
      'nav.prev': () => move(-1),
      'nav.open': () {
        ref.read(scopeProvider.notifier).set('thread');
        onOpen?.call();
      },
      'nav.back': () {
        blurTextInput();
        ref.read(paletteOpenProvider.notifier).close();
        ref.read(composeProvider.notifier).close();
        ref.read(scopeProvider.notifier).set('list');
      },
      'nav.goInbox': () => ref.read(queryProvider.notifier).set(''),
      'nav.goStarred': () => ref.read(queryProvider.notifier).set('is:starred'),
      'nav.goArchive': () => ref.read(queryProvider.notifier).set('in:archive'),
      'thread.archive': archiveSelected,
      'thread.delete': trashSelected,
      'thread.star': toggleStar,
      'thread.reply': () => openReply(),
      'thread.replyAll': () => openReply(all: true),
      'thread.forward': openForward,
      'thread.snooze': () {},
      'thread.label': () {},
      'search.focus': () => listKey?.currentState?.focusSearch(),
      'palette.open': () => ref.read(paletteOpenProvider.notifier).toggle(),
      'compose.new': openNew,
      'help.cheatsheet': () => ref.read(paletteOpenProvider.notifier).open(),
    };
  }

  List<Command> commands() {
    final repo = ref.read(repositoryProvider);
    final labels = ref.read(labelsProvider).asData?.value ?? const <Label>[];
    final mode = ref.read(appearanceProvider);
    final modeLabel = switch (mode) {
      ThemeMode.system => 'System',
      ThemeMode.dark => 'Dark',
      ThemeMode.light => 'Light',
    };
    return [
      Command(
        id: 'archive',
        title: 'Archive',
        group: 'Message',
        hint: 'e',
        run: () => withSelected(repo.archive, advance: true),
      ),
      Command(
        id: 'trash',
        title: 'Delete',
        group: 'Message',
        hint: '#',
        run: () => withSelected(repo.trash, advance: true),
      ),
      Command(
        id: 'star',
        title: 'Star / Unstar',
        group: 'Message',
        hint: '*',
        run: toggleStar,
      ),
      Command(
        id: 'read',
        title: 'Mark as Read',
        group: 'Message',
        run: () => withSelected((id) => repo.markRead(id, true)),
      ),
      Command(
        id: 'unread',
        title: 'Mark as Unread',
        group: 'Message',
        run: () => withSelected((id) => repo.markRead(id, false)),
      ),
      Command(
        id: 'inbox',
        title: 'Go to Inbox',
        group: 'Go',
        hint: 'g i',
        run: () => ref.read(queryProvider.notifier).set(''),
      ),
      Command(
        id: 'starred',
        title: 'Go to Starred',
        group: 'Go',
        hint: 'g s',
        run: () => ref.read(queryProvider.notifier).set('is:starred'),
      ),
      Command(
        id: 'unreadf',
        title: 'Show Unread Only',
        group: 'Go',
        run: () => ref.read(queryProvider.notifier).set('is:unread'),
      ),
      for (final l in labels)
        Command(
          id: 'label-${l.name}',
          title: 'Show ${l.name}',
          group: 'Go',
          run: () => ref.read(queryProvider.notifier).set('#${l.name}'),
        ),
      Command(
        id: 'sync',
        title: 'Sync Now',
        group: 'Accounts',
        detail: 'All accounts',
        run: repo.sync,
      ),
      Command(
        id: 'add-account',
        title: 'Add Account…',
        group: 'Accounts',
        run: () => showAddAccountSheet(context),
      ),
      Command(
        id: 'appearance',
        title: 'Appearance: $modeLabel',
        group: 'View',
        detail: 'Click to cycle',
        run: ref.read(appearanceProvider.notifier).cycle,
      ),
    ];
  }
}
