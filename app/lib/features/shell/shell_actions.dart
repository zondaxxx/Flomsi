import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../keymap/key_scope.dart';
import '../../platform.dart';
import '../../state/appearance.dart';
import '../../state/providers.dart';
import '../../theme/surfaces.dart';
import '../accounts/add_account_sheet.dart';
import '../list/thread_list.dart';
import '../palette/command_palette.dart';
import '../phone/sheets.dart';
import '../phone/undo.dart';
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
    this.onLeave,
  }) : phone = isPhone(context);
  final WidgetRef ref;
  final BuildContext context;
  final GlobalKey<ThreadListBodyState>? listKey;
  final VoidCallback? onOpen;

  /// A phone's thread page closes itself before its conversation is filed away.
  final VoidCallback? onLeave;

  /// Phones file with Undo and choose in sheets; computers go on to the next thread.
  final bool phone;

  /// A one-off choice: a sheet from the bottom on a phone, the palette's popover
  /// elsewhere.
  void presentPicker(Picker p) => phone
      ? showPickerSheet(context, p)
      : ref.read(pickerProvider.notifier).open(p);

  PendingFilings get _filings => ref.read(pendingFilingProvider.notifier);

  /// The folder role the list shows, or null for a label, Snoozed or a search.
  FolderRole? get _shownRole {
    final m = parseMailbox(
      withoutFilter(ref.read(queryProvider), ref.read(listFilterProvider)),
    );
    return m == null || m.label != null || m.snoozed ? null : m.role;
  }

  /// Trash or Junk when the list shows one of them (one account's or all), else null.
  FolderRole? get shownBin {
    final r = _shownRole;
    return r == FolderRole.trash || r == FolderRole.junk ? r : null;
  }

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

  /// A new message, from [accountId] when the list is narrowed to one account.
  Future<void> openNew({int? accountId}) async {
    try {
      final d = await ref
          .read(repositoryProvider)
          .newDraft(accountId: accountId);
      ref.read(composeProvider.notifier).open(d);
    } catch (e) {
      ref.read(noticeProvider.notifier).show('Add an account first');
    }
  }

  /// Mark the selected conversation unread; a phone goes back to the list, where it
  /// shows as new again.
  Future<void> markUnread() => withSelected((id) async {
    await ref.read(repositoryProvider).markRead(id, false);
    if (phone) {
      onLeave?.call();
      ref.read(noticeProvider.notifier).show('Marked as unread');
    }
  });

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
      // Already there: the mailbox on screen (one account's or all of them, Unread
      // or not).
      ?_shownRole,
    };
    presentPicker(
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
                  final name = f.role == FolderRole.other
                      ? f.name
                      : labelForRole(f.role);
                  if (phone) {
                    onLeave?.call();
                    await _filings.start(
                      id,
                      FilingKind.move,
                      folderId: f.id,
                      folderName: name,
                    );
                    return;
                  }
                  await move(1);
                  final n = await repo.moveThread(id, f.id);
                  ref
                      .read(noticeProvider.notifier)
                      .show(n > 0 ? 'Moved to $name' : 'Already in $name');
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
    presentPicker(
      Picker(
        hint: 'Snooze until…',
        items: [
          if (thread?.snoozed ?? false)
            Command(
              id: 'unsnooze',
              title: 'Unsnooze',
              group: 'Snoozed until ${snoozeLabel(thread!.snoozedUntil!, now)}',
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
                final notice = ref.read(noticeProvider.notifier);
                if (phone) {
                  // Snoozing is local and quick to take back: it happens now.
                  onLeave?.call();
                  await repo.snooze(id, at);
                  notice.show(
                    'Snoozed until ${snoozeLabel(at, now)}',
                    action: 'Undo',
                    onAction: () => repo.unsnooze(id),
                  );
                  return;
                }
                await move(1);
                await repo.snooze(id, at);
                notice.show('Snoozed until ${snoozeLabel(at, now)}');
              },
            ),
        ],
      ),
    );
  });

  Future<void> archiveSelected() => _fileSelected(archive: true);

  /// Delete: to Trash, or out of Trash for good (there is nowhere further to put it).
  Future<void> trashSelected() => shownBin == FolderRole.trash
      ? deleteForeverSelected()
      : _fileSelected(archive: false);

  /// Delete forever, after asking: the selected conversation's messages in Trash and
  /// Junk, as they were when asked about, leave the server. No Undo, so no waiting either.
  Future<void> deleteForeverSelected() async {
    final id = ref.read(selectedThreadIdProvider);
    if (id == null) return;
    final notice = ref.read(noticeProvider.notifier);
    final repo = ref.read(repositoryProvider);
    final ForeverCheck check;
    try {
      check = await repo.checkDeleteForever(id);
    } catch (e) {
      notice.show(e is Problem ? e.title : e.toString(), error: true);
      return;
    }
    if (check.count == 0) {
      notice.show('Only mail in Trash or Junk can be deleted forever');
      return;
    }
    if (!context.mounted) return;
    final sure = await confirmDialog(
      context,
      title: 'Delete forever?',
      body: check.count == 1
          ? 'This conversation’s message in Trash or Junk is deleted from the server '
                'for good. This can’t be undone.'
          : 'This conversation’s ${check.count} messages in Trash and Junk are deleted '
                'from the server for good. This can’t be undone.',
      action: 'Delete Forever',
      danger: true,
    );
    if (!sure || !context.mounted) return;
    final next = phone ? null : _neighbour(id);
    if (phone) onLeave?.call();
    try {
      final n = await repo.deleteForever(check);
      if (next != null && ref.read(selectedThreadIdProvider) == id) {
        ref.read(selectedThreadIdProvider.notifier).select(next);
      }
      notice.show(
        n > 0 ? 'Deleted forever' : 'Already gone from Trash and Junk',
      );
    } catch (e) {
      notice.show(e is Problem ? e.title : e.toString(), error: true);
    }
  }

  /// One Empty at a time: a second tap while the first is under way does nothing.
  static bool _emptying = false;

  /// Empty Trash or Junk of the accounts [scope] names (part of an address, as `account:`
  /// matches it), or of every account when it is null; each entry point passes the scope
  /// of the mailbox it belongs to. First the phone's filing still waiting for Undo goes,
  /// then each account's folder is read from the server again, its queued changes first,
  /// while nothing can be touched; then the question, with whatever that turned up. Only
  /// on yes is anything deleted, and only what the question was about.
  Future<void> emptyBin(FolderRole role, {required String? scope}) async {
    if (_emptying) return;
    _emptying = true;
    try {
      await _emptyBin(role, scope?.toLowerCase());
    } finally {
      _emptying = false;
    }
  }

  /// The mailbox's own scope for [emptyBin] from where the list is (the palette).
  String? get shownScope => parseMailbox(
    withoutFilter(ref.read(queryProvider), ref.read(listFilterProvider)),
  )?.scope;

  Future<void> _emptyBin(FolderRole role, String? scope) async {
    final notice = ref.read(noticeProvider.notifier);
    final repo = ref.read(repositoryProvider);
    final filings = ref.read(pendingFilingProvider.notifier);
    final name = labelForRole(role);
    // A restore or "not spam" held for Undo reaches the queue first, so the emptying
    // leaves its message.
    await filings.commit();
    final accounts = [
      for (final a in await repo.accounts())
        if (scope == null || a.email.toLowerCase().contains(scope)) a,
    ];
    if (accounts.isEmpty) {
      notice.show('No account matches $scope');
      return;
    }
    if (!context.mounted) return;
    final results = await waitDialog(
      context,
      text: 'Checking $name with the server…',
      work: Future.wait([
        for (final a in accounts)
          repo
              .refreshBin(role, a.id)
              .then<Object?>((c) => c, onError: (Object e) => e),
      ]),
    );
    final checks = <BinCheck>[];
    final notes = <String>[];
    final failed = <String>[];
    for (final (i, r) in results.indexed) {
      final email = accounts[i].email;
      if (r is BinCheck) {
        checks.add(r);
        notes.addAll(r.notes.map((n) => '$email: $n'));
      } else if (r != null) {
        failed.add('$email: ${r is Problem ? r.title : r}');
      }
    }
    String emails(Iterable<BinCheck> cs) => cs
        .map((c) => accounts.firstWhere((a) => a.id == c.accountId).email)
        .join(', ');
    if (!context.mounted) return;
    if (checks.isEmpty) {
      notice.show(
        failed.isEmpty
            ? 'No $name to empty'
            : 'Could not check $name. ${failed.join('; ')}',
        error: failed.isNotEmpty,
      );
      return;
    }
    final sure = await confirmDialog(
      context,
      title: 'Empty $name?',
      body: [
        'Everything in $name on ${emails(checks)} is deleted from the server for good, '
            'including mail older than this device shows. This can’t be undone.',
        if (notes.isNotEmpty) 'Checking $name turned up: ${notes.join('; ')}.',
        if (failed.isNotEmpty) 'Not emptied: ${failed.join('; ')}.',
      ].join('\n\n'),
      action: 'Empty $name',
      danger: true,
    );
    if (!sure) return;
    // Anything filed meanwhile reaches the queue before the emptying, and is kept.
    await filings.commit();
    final emptied = <BinCheck>[];
    final errors = <String>[];
    for (final c in checks) {
      try {
        await repo.emptyFolder(c);
        emptied.add(c);
      } catch (e) {
        errors.add('${emails([c])}: ${e is Problem ? e.title : e}');
      }
    }
    ref.read(selectedThreadIdProvider.notifier).select(null);
    notice.show(
      errors.isEmpty
          ? '$name emptied'
          : [
              if (emptied.isNotEmpty) '$name emptied on ${emails(emptied)}.',
              'Not emptied: ${errors.join('; ')}',
            ].join(' '),
      error: errors.isNotEmpty,
    );
  }

  /// The conversation to select once [id] leaves the list: the next one, or the one
  /// before at the end.
  int? _neighbour(int id) {
    final threads = ref.read(threadsProvider).value ?? const <Thread>[];
    final i = threads.indexWhere((t) => t.id == id);
    return i < 0
        ? null
        : i + 1 < threads.length
        ? threads[i + 1].id
        : i > 0
        ? threads[i - 1].id
        : null;
  }

  /// Archive or delete the selected thread, go on to the next one, and say what really
  /// happened: from a view outside the inbox there may be nothing to archive. When the
  /// thread could not be filed (no folder for it), the selection stays put.
  Future<void> _fileSelected({required bool archive}) async {
    final id = ref.read(selectedThreadIdProvider);
    if (id == null) return;
    if (phone) {
      onLeave?.call();
      await _filings.start(id, archive ? FilingKind.archive : FilingKind.trash);
      return;
    }
    final notice = ref.read(noticeProvider.notifier);
    final next = _neighbour(id);
    final n = await fileAway(
      context,
      ref.read(repositoryProvider),
      notice,
      id,
      archive: archive,
    );
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
        id: 'delete-forever',
        title: 'Delete Forever',
        group: 'Message',
        detail: 'From Trash or Junk',
        run: deleteForeverSelected,
      ),
      for (final role in const [FolderRole.trash, FolderRole.junk])
        Command(
          id: 'empty-${role.name}',
          title: 'Empty ${labelForRole(role)}',
          group: 'Mailbox',
          detail: 'Deletes it all for good',
          run: () => emptyBin(role, scope: shownScope),
        ),
      Command(
        id: 'reply-all',
        title: 'Reply All',
        group: 'Message',
        hint: key('thread.replyAll'),
        run: () => openReply(all: true),
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
