import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/mock_repository.dart';
import '../data/models.dart';
import '../data/repository.dart';
import '../keymap/keymap.dart';
import '../platform.dart';

final repositoryProvider = Provider<MailRepository>((ref) => MockRepository());

/// Key presets shipped in assets/keymaps. The choice is a stored setting (`keymap`).
const keymapPresets = ['vim', 'gmail'];

final keymapProvider = FutureProvider<Keymap>((ref) async {
  String? preset;
  try {
    preset = await ref.watch(repositoryProvider).setting('keymap');
  } catch (_) {
    // No database yet: the default preset.
  }
  return Keymap.loadAsset(keymapPresets.contains(preset) ? preset! : 'vim');
});

/// Bumps whenever the repository reports a change, so list/thread providers refetch.
final repoTickProvider = StreamProvider<int>((ref) {
  final repo = ref.watch(repositoryProvider);
  var n = 0;
  return repo.events.map((_) => ++n);
});

final queryProvider = NotifierProvider<QueryController, String>(
  QueryController.new,
);

class QueryController extends Notifier<String> {
  @override
  String build() => '';
  void set(String q) => state = q;
}

/// How many conversations the list asks for: a page to begin with, more as the user
/// reaches the end (or as older mail comes in); back to one page for every new query.
final listLimitProvider = NotifierProvider<ListLimit, int>(ListLimit.new);

class ListLimit extends Notifier<int> {
  static const page = 100;
  @override
  int build() {
    ref.watch(queryProvider);
    return page;
  }

  void grow([int by = page]) => state = state + by;
}

/// The conversations the query finds in the database on this device.
final storedThreadsProvider = FutureProvider<List<Thread>>((ref) async {
  ref.watch(repoTickProvider);
  final q = ref.watch(queryProvider);
  final limit = ref.watch(listLimitProvider);
  return ref.watch(repositoryProvider).threads(q, limit: limit);
});

/// What the list shows: the stored conversations, less those a phone has filed and is
/// holding for Undo (or has just filed, until the database stops listing them).
/// Filtered in step with the stored list, so a hidden row never comes back for a frame.
final threadsProvider = Provider<AsyncValue<List<Thread>>>((ref) {
  final hidden = ref.watch(hiddenThreadsProvider);
  final stored = ref.watch(storedThreadsProvider);
  if (hidden.isEmpty) return stored;
  return stored.whenData(
    (list) => [
      for (final t in list)
        if (!hidden.contains(t.id)) t,
    ],
  );
});

/// Conversations off the list while their filing waits for Undo. Always empty on a
/// computer, where filing happens at once.
final hiddenThreadsProvider = NotifierProvider<HiddenThreads, Set<int>>(
  HiddenThreads.new,
);

class HiddenThreads extends Notifier<Set<int>> {
  @override
  Set<int> build() => const {};
  void hide(int id) => state = {...state, id};
  void show(int id) {
    if (state.contains(id)) state = {...state}..remove(id);
  }
}

final accountsProvider = FutureProvider<List<Account>>((ref) async {
  ref.watch(repoTickProvider);
  return ref.watch(repositoryProvider).accounts();
});

/// Drafts kept on this device. The composer invalidates this after each autosave, which
/// is cheaper than a repository event that would refetch every list.
final draftsProvider = FutureProvider<List<Draft>>((ref) async {
  ref.watch(repoTickProvider);
  return ref.watch(repositoryProvider).drafts();
});

final foldersProvider = FutureProvider<List<Folder>>((ref) async {
  ref.watch(repoTickProvider);
  ref.watch(draftsProvider);
  return ref.watch(repositoryProvider).folders();
});

final labelsProvider = FutureProvider<List<Label>>(
  (ref) => ref.watch(repositoryProvider).labels(),
);

final selectedThreadIdProvider = NotifierProvider<SelectedThread, int?>(
  SelectedThread.new,
);

class SelectedThread extends Notifier<int?> {
  @override
  int? build() => null;
  void select(int? id) => state = id;
}

final selectedThreadProvider = FutureProvider<Thread?>((ref) async {
  ref.watch(repoTickProvider);
  final id = ref.watch(selectedThreadIdProvider);
  if (id == null) return null;
  return ref.watch(repositoryProvider).thread(id);
});

final messagesProvider = FutureProvider.family<List<Message>, int>((
  ref,
  threadId,
) {
  ref.watch(repoTickProvider);
  return ref.watch(repositoryProvider).messages(threadId);
});

/// Which keymap scope owns single-key shortcuts right now.
final scopeProvider = NotifierProvider<ScopeController, String>(
  ScopeController.new,
);

class ScopeController extends Notifier<String> {
  @override
  String build() => 'list';
  void set(String s) => state = s;
}

final paletteOpenProvider = NotifierProvider<PaletteController, bool>(
  PaletteController.new,
);

class PaletteController extends Notifier<bool> {
  @override
  bool build() => false;
  void open() => state = true;
  void close() => state = false;
  void toggle() => state = !state;
}

class SyncStatus {
  const SyncStatus({this.syncing = false, this.lastOk, this.lastError});
  final bool syncing;
  final DateTime? lastOk;
  final String? lastError;
}

final syncStatusProvider = NotifierProvider<SyncStatusController, SyncStatus>(
  SyncStatusController.new,
);

class SyncStatusController extends Notifier<SyncStatus> {
  StreamSubscription<RepoEvent>? _sub;

  @override
  SyncStatus build() {
    final repo = ref.watch(repositoryProvider);
    _sub?.cancel();
    _sub = repo.events.listen((e) {
      switch (e) {
        case SyncStarted():
          state = SyncStatus(syncing: true, lastOk: state.lastOk);
        case SyncFinished(:final errors):
          state = errors.isEmpty
              ? SyncStatus(syncing: false, lastOk: DateTime.now())
              : SyncStatus(
                  syncing: false,
                  lastOk: state.lastOk,
                  lastError: errors.join(' · '),
                );
        case ThreadsChanged():
        case MailImported():
          break;
      }
    });
    ref.onDispose(() => _sub?.cancel());
    // Nothing synced yet: the status line says so instead of showing a made-up time.
    return const SyncStatus();
  }
}

/// True when running on a platform whose primary modifier is ⌘.
final isMac =
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// The key for [action] in the active keymap as this platform writes it (`e`, `⌘K`,
/// `ctrl+K`), or null while the keymap loads, when nothing is bound, and on touch
/// screens, where there is no keyboard to press it on.
String? keyHintFor(WidgetRef ref, String action) =>
    kTouch ? null : ref.watch(keymapProvider).value?.hint(action, mac: isMac);

/// The account the phone's mail screen is narrowed to (its address), or null for all.
final accountScopeProvider = NotifierProvider<AccountScope, String?>(
  AccountScope.new,
);

class AccountScope extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? email) => state = email;
}

/// All mail, only unread, or only starred: narrows whatever mailbox is shown. Back to
/// all when another mailbox is chosen.
final listFilterProvider = NotifierProvider<ListFilter, String>(ListFilter.new);

class ListFilter extends Notifier<String> {
  @override
  String build() => 'all';
  void set(String f) => state = f;
  void toggleUnread() => state = state == 'unread' ? 'all' : 'unread';
}

/// A conversation to open, asked for from outside the list (a tapped notification). The
/// shell selects it and, on a phone, opens its page.
final openThreadProvider = NotifierProvider<OpenThread, int?>(OpenThread.new);

class OpenThread extends Notifier<int?> {
  @override
  int? build() => null;
  void open(int threadId) => state = threadId;
  void done() => state = null;
}

/// A built-in shortcut that is not in the keymap: `⌘⇧A` on Apple platforms, `ctrl+shift+A`
/// elsewhere.
String modKey(String key, {bool shift = false}) =>
    isMac ? '⌘${shift ? '⇧' : ''}$key' : 'ctrl+${shift ? 'shift+' : ''}$key';

/// The draft being written, or null when no composer is open.
final composeProvider = NotifierProvider<ComposeController, Draft?>(
  ComposeController.new,
);

class ComposeController extends Notifier<Draft?> {
  @override
  Draft? build() => null;
  void open(Draft d) => state = d;
  void update(Draft d) => state = d;
  void close() => state = null;
}

/// Transient line for the status bar ("Sent", "Archived"), cleared after a moment.
final noticeProvider = NotifierProvider<NoticeController, String?>(
  NoticeController.new,
);

/// A notice with what it offers: an action (Undo), and whether it reports a failure.
class Notice {
  const Notice(
    this.text, {
    this.action,
    this.onAction,
    this.error = false,
    this.ttl,
  });
  final String text;
  final String? action;
  final void Function()? onAction;
  final bool error;
  final Duration? ttl;
}

class NoticeController extends Notifier<String?> {
  Timer? _t;

  /// The notice on screen, with its action; [state] is its text.
  Notice? current;

  @override
  String? build() {
    ref.onDispose(() => _t?.cancel());
    return null;
  }

  /// Show [text] for [ttl]: 2.5 s, 5 s with an action, 8 s for an error, unless given.
  void show(
    String text, {
    Duration? ttl,
    String? action,
    void Function()? onAction,
    bool error = false,
  }) {
    final time =
        ttl ??
        (error
            ? const Duration(seconds: 8)
            : action != null
            ? const Duration(seconds: 5)
            : const Duration(milliseconds: 2500));
    current = Notice(
      text,
      action: action,
      onAction: onAction,
      error: error,
      ttl: time,
    );
    // The same words again still count as a new notice.
    state = null;
    state = text;
    _t?.cancel();
    _t = Timer(time, hide);
  }

  /// Take the notice down now (its Undo no longer applies).
  void hide() {
    _t?.cancel();
    current = null;
    state = null;
  }
}
