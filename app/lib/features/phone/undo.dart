import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_keys.dart';
import '../../state/providers.dart';
import '../shell/file_away.dart';

enum FilingKind { archive, trash, move }

/// A conversation a phone has archived, deleted or moved, held back for [PendingFilings.window]
/// so Undo can take it back: filing removes the local rows at once, so it cannot be
/// undone after it runs.
class PendingFiling {
  const PendingFiling(
    this.threadId,
    this.kind, {
    this.folderId,
    this.folderName,
  });
  final int threadId;
  final FilingKind kind;
  final int? folderId;
  final String? folderName;

  /// What the notice says.
  String get done => switch (kind) {
    FilingKind.archive => 'Archived',
    FilingKind.trash => 'Deleted',
    FilingKind.move => 'Moved to $folderName',
  };
}

final pendingFilingProvider = NotifierProvider<PendingFilings, PendingFiling?>(
  PendingFilings.new,
);

/// One filing at a time waits for Undo; it runs when its time is up, when the app goes to
/// the background, or when another one starts. If the app is killed meanwhile, the
/// conversation simply stays where it was.
class PendingFilings extends Notifier<PendingFiling?> {
  static const window = Duration(seconds: 5);

  /// How long a filed conversation stays hidden at most while the list catches up.
  static const settleAtMost = Duration(seconds: 10);

  Timer? _timer;
  final _settling = <int, Timer>{};
  AppLifecycleListener? _life;

  @override
  PendingFiling? build() {
    _life = AppLifecycleListener(onPause: () => unawaited(commit()));
    // A filed conversation is back in view once the stored list no longer has it.
    ref.listen(storedThreadsProvider, (_, next) {
      final list = next.value;
      if (next.isLoading || list == null || _settling.isEmpty) return;
      for (final id in _settling.keys.toList()) {
        if (!list.any((t) => t.id == id)) _settled(id);
      }
    });
    ref.onDispose(() {
      _timer?.cancel();
      for (final t in _settling.values) {
        t.cancel();
      }
      _life?.dispose();
    });
    return null;
  }

  HiddenThreads get _hidden => ref.read(hiddenThreadsProvider.notifier);
  NoticeController get _notices => ref.read(noticeProvider.notifier);

  /// The notice with this filing's Undo, while it is the one on screen.
  Notice? _shown;

  /// Take [threadId] off the list now and file it in [window], with Undo on the notice.
  /// A filing still waiting runs first; the slot changes hands at once, so a third one
  /// started meanwhile is never lost.
  Future<void> start(
    int threadId,
    FilingKind kind, {
    int? folderId,
    String? folderName,
  }) async {
    final previous = _take();
    final p = PendingFiling(
      threadId,
      kind,
      folderId: folderId,
      folderName: folderName,
    );
    state = p;
    _hidden.hide(threadId);
    _timer = Timer(window, () => unawaited(commit()));
    _notices.show(p.done, action: 'Undo', onAction: () => undo(p), ttl: window);
    _shown = _notices.current;
    if (previous != null) await _run(previous);
  }

  /// Put [p] back where it was, if it has not run yet.
  void undo(PendingFiling p) {
    if (!identical(state, p)) return;
    _timer?.cancel();
    state = null;
    _endUndo();
    _hidden.show(p.threadId);
  }

  /// Run the waiting filing now.
  Future<void> commit() async {
    final p = _take();
    if (p != null) await _run(p);
  }

  /// The waiting filing, no longer waiting: its Undo goes, its row stays hidden until the
  /// list has caught up.
  PendingFiling? _take() {
    final p = state;
    if (p == null) return null;
    _timer?.cancel();
    state = null;
    _endUndo();
    _settling[p.threadId]?.cancel();
    _settling[p.threadId] = Timer(settleAtMost, () => _settled(p.threadId));
    return p;
  }

  /// Undo is offered only while it can still work.
  void _endUndo() {
    if (_shown != null && identical(_notices.current, _shown)) _notices.hide();
    _shown = null;
  }

  Future<void> _run(PendingFiling p) async {
    final repo = ref.read(repositoryProvider);
    final notice = _notices;
    int? n;
    if (p.kind == FilingKind.move) {
      try {
        n = await repo.moveThread(p.threadId, p.folderId!);
        if (n == 0) notice.show('Already in ${p.folderName}');
      } catch (e) {
        notice.show('Couldn’t move it: $e', error: true);
      }
    } else {
      final archive = p.kind == FilingKind.archive;
      n = await fileAway(
        rootNavigatorKey.currentState?.overlay?.context,
        repo,
        notice,
        p.threadId,
        archive: archive,
      );
      if (n == 0) {
        notice.show(archive ? 'Not in the inbox' : 'Nothing to delete');
      }
    }
    // Nothing moved: the conversation comes back.
    if (n == null || n == 0) _settled(p.threadId);
  }

  void _settled(int id) {
    _settling.remove(id)?.cancel();
    _hidden.show(id);
  }
}
