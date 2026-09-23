import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../keymap/key_scope.dart';
import '../../state/appearance.dart';
import '../../state/providers.dart';
import '../accounts/add_account_sheet.dart';
import '../list/thread_list.dart';
import '../palette/command_palette.dart';
import '../settings/settings_sheet.dart';
import '../sidebar/sidebar_model.dart';
import '../thread/snooze.dart';
import 'file_away.dart';

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
    final threads = ref.read(threadsProvider).value;
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
  });

  Future<void> openForward() => withSelected((id) async {
    final d = await ref.read(repositoryProvider).forwardDraft(id);
    ref.read(composeProvider.notifier).open(d);
  });

  Future<void> openNew() async {
    try {
      final d = await ref.read(repositoryProvider).newDraft();
      ref.read(composeProvider.notifier).open(d);
    } catch (e) {
      ref.read(noticeProvider.notifier).show('Add an account first');
    }
  }

  /// "Move to…": a picker over the account's folders (Gmail labels are folders over IMAP).
  Future<void> moveSelected() => withSelected((id) async {
    final repo = ref.read(repositoryProvider);
    final thread = await repo.thread(id);
    if (thread == null) return;
    final folders = await repo.accountFolders(thread.accountId);
    final skip = {
      FolderRole.sent,
      FolderRole.drafts,
      FolderRole.all,
      // Already there.
      if (ref.read(queryProvider).trim().isEmpty) FolderRole.inbox,
    };
    ref
        .read(pickerProvider.notifier)
        .open(
          Picker(
            hint: 'Move to…',
            items: [
              for (final f in folders)
                if (!skip.contains(f.role))
                  Command(
                    id: 'move-${f.id}',
                    title: f.role == FolderRole.other
                        ? f.name
                        : labelForRole(f.role),
                    group: f.role == FolderRole.other ? 'Folders' : 'Mailboxes',
                    detail: f.role == FolderRole.other ? null : f.name,
                    run: () async {
                      await move(1);
                      await repo.moveThread(id, f.id);
                      ref
                          .read(noticeProvider.notifier)
                          .show(
                            'Moved to ${f.role == FolderRole.other ? f.name : labelForRole(f.role)}',
                          );
                    },
                  ),
            ],
          ),
        );
  });

  /// Snooze presets, or bringing a snoozed thread back now.
  Future<void> snoozeSelected() => withSelected((id) async {
    final repo = ref.read(repositoryProvider);
    final thread = await repo.thread(id);
    final now = DateTime.now();
    ref
        .read(pickerProvider.notifier)
        .open(
          Picker(
            hint: 'Snooze until…',
            items: [
              if (thread?.snoozed ?? false)
                Command(
                  id: 'unsnooze',
                  title: 'Unsnooze',
                  group:
                      'Snoozed until ${snoozeLabel(thread!.snoozedUntil!, now)}',
                  run: () async {
                    await repo.unsnooze(id);
                    ref.read(noticeProvider.notifier).show('Back in the inbox');
                  },
                ),
              for (final (label, at) in snoozeChoices(now))
                Command(
                  id: 'snooze-$label',
                  title: label,
                  group: 'Snooze',
                  detail: snoozeLabel(at, now),
                  run: () async {
                    await move(1);
                    await repo.snooze(id, at);
                    ref
                        .read(noticeProvider.notifier)
                        .show('Snoozed until ${snoozeLabel(at, now)}');
                  },
                ),
            ],
          ),
        );
  });

  Future<void> archiveSelected() => _fileSelected(archive: true);
  Future<void> trashSelected() => _fileSelected(archive: false);

  /// Archive or delete the selected thread, go on to the next one, and say what really
  /// happened: from a view outside the inbox there may be nothing to archive. When the
  /// thread could not be filed (no folder for it), the selection stays put.
  Future<void> _fileSelected({required bool archive}) async {
    final id = ref.read(selectedThreadIdProvider);
    if (id == null) return;
    final notice = ref.read(noticeProvider.notifier);
    final threads = ref.read(threadsProvider).value ?? const <Thread>[];
    final i = threads.indexWhere((t) => t.id == id);
    final next = i < 0
        ? null
        : i + 1 < threads.length
        ? threads[i + 1].id
        : i > 0
        ? threads[i - 1].id
        : null;
    final n = await fileAway(context, ref, id, archive: archive);
    if (n == null || !context.mounted) return;
    if (next != null && ref.read(selectedThreadIdProvider) == id) {
      ref.read(selectedThreadIdProvider.notifier).select(next);
    }
    notice.show(
      archive
          ? (n > 0 ? 'Archived' : 'Not in the inbox')
          : (n > 0 ? 'Deleted' : 'Nothing to delete'),
    );
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
        ref.read(pickerProvider.notifier).close();
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
      'thread.snooze': snoozeSelected,
      'thread.label': moveSelected,
      'search.focus': () => listKey?.currentState?.focusSearch(),
      'palette.open': () => ref.read(paletteOpenProvider.notifier).toggle(),
      'compose.new': openNew,
      'app.settings': () => showSettingsSheet(context),
      'help.cheatsheet': () => ref.read(paletteOpenProvider.notifier).open(),
    };
  }

  List<Command> commands() {
    final repo = ref.read(repositoryProvider);
    // Hints come from the active keymap, so they match what the keys do (⌘ on macOS only).
    final keymap = ref.read(keymapProvider).value;
    String? key(String action) => keymap?.hint(action, mac: isMac);
    final labels = ref.read(labelsProvider).value ?? const <Label>[];
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
        hint: key('thread.archive'),
        run: archiveSelected,
      ),
      Command(
        id: 'trash',
        title: 'Delete',
        group: 'Message',
        hint: key('thread.delete'),
        run: trashSelected,
      ),
      Command(
        id: 'star',
        title: 'Star / Unstar',
        group: 'Message',
        hint: key('thread.star'),
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
        hint: key('nav.goInbox'),
        run: () => ref.read(queryProvider.notifier).set(''),
      ),
      Command(
        id: 'starred',
        title: 'Go to Starred',
        group: 'Go',
        hint: key('nav.goStarred'),
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
        id: 'settings',
        title: 'Settings…',
        group: 'App',
        detail: 'Accounts, signatures, keys, appearance',
        hint: key('app.settings'),
        run: () => showSettingsSheet(context),
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
