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

final threadsProvider = FutureProvider<List<Thread>>((ref) async {
  ref.watch(repoTickProvider);
  final q = ref.watch(queryProvider);
  final limit = ref.watch(listLimitProvider);
  return ref.watch(repositoryProvider).threads(q, limit: limit);
});

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

class NoticeController extends Notifier<String?> {
  Timer? _t;
  @override
  String? build() {
    ref.onDispose(() => _t?.cancel());
    return null;
  }

  void show(String text, {Duration ttl = const Duration(milliseconds: 2500)}) {
    state = text;
    _t?.cancel();
    _t = Timer(ttl, () => state = null);
  }
}
