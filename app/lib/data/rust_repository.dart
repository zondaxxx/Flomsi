import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' show Color;
import 'package:path_provider/path_provider.dart';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

import '../src/rust/api/mail.dart' as rust;
import '../src/rust/frb_generated.dart';
import 'models.dart';
import 'repository.dart';

/// MailRepository backed by the Rust core through flutter_rust_bridge.
class RustRepository implements MailRepository {
  RustRepository._();

  final _events = StreamController<RepoEvent>.broadcast();
  StreamSubscription<rust.SyncEventDto>? _sub;
  final _idleLoops = <int, bool>{}; // account id → keep running
  Timer? _periodic;
  bool _disposed = false;
  Future<void> _syncLock = Future.value();

  /// One sync at a time: the IDLE loops, the timer and the user share the same IMAP quota.
  Future<T> _serial<T>(Future<T> Function() body) {
    final previous = _syncLock;
    final completer = Completer<void>();
    _syncLock = completer.future;
    return previous.then((_) => body()).whenComplete(completer.complete);
  }

  /// Desktop: `~/.mail_` (shared with the `mailctl` CLI). Mobile: app support dir.
  static Future<String> defaultDataDir() async {
    if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
      final home =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home != null) return '$home${Platform.pathSeparator}.mail_';
    }
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}${Platform.pathSeparator}mail_';
  }

  /// macOS: the Xcode run-script phase drops libmail_bridge.dylib into Contents/Frameworks.
  /// Elsewhere flutter_rust_bridge's default lookup applies (rust/target/release for dev).
  static ExternalLibrary? _bundledLibrary() {
    // iOS: the bridge is a static library linked into the executable (scripts/build_bridge_ios.sh).
    if (Platform.isIOS) return ExternalLibrary.process(iKnowHowToUseIt: true);
    if (!Platform.isMacOS) return null;
    final exe = File(Platform.resolvedExecutable);
    final path = '${exe.parent.parent.path}/Frameworks/libmail_bridge.dylib';
    return File(path).existsSync() ? ExternalLibrary.open(path) : null;
  }

  static Future<RustRepository> open({String? dataDir}) async {
    await RustLib.init(externalLibrary: _bundledLibrary());
    final dir = dataDir ?? await defaultDataDir();
    await rust.openCore(dataDir: dir);
    final repo = RustRepository._();
    repo._sub = rust.syncEvents().listen((e) {
      switch (e.kind) {
        case 'started':
          break;
        case 'folder':
          if (e.fetched > 0 || e.removed > 0) {
            repo._events.add(const ThreadsChanged());
          }
        case 'finished':
          repo._events.add(const ThreadsChanged());
        case 'error':
          repo._events.add(SyncFinished(fetched: 0, errors: [e.message]));
      }
    });
    return repo;
  }

  /// Keeps mail fresh without the user asking: a sync on start, an IMAP IDLE loop per account
  /// (the server pushes, we fetch), and a periodic fallback for servers where IDLE misbehaves.
  Future<void> startBackgroundSync() async {
    await sync();
    _periodic?.cancel();
    _periodic = Timer.periodic(const Duration(minutes: 10), (_) => sync());
    await _refreshIdleLoops();
  }

  Future<void> _refreshIdleLoops() async {
    final ids = (await rust.listAccounts()).map((a) => a.id.toInt()).toSet();
    for (final id in ids) {
      if (_idleLoops.containsKey(id)) continue;
      _idleLoops[id] = true;
      unawaited(_idleLoop(id));
    }
    for (final id in _idleLoops.keys.toList()) {
      if (!ids.contains(id)) _idleLoops[id] = false;
    }
  }

  Future<void> _idleLoop(int accountId) async {
    var backoff = const Duration(seconds: 30);
    while (!_disposed && (_idleLoops[accountId] ?? false)) {
      try {
        // Servers drop IDLE after ~29 minutes; re-enter well before that.
        final changed = await rust.waitForChange(
          accountId: accountId,
          timeoutSecs: 25 * 60,
        );
        backoff = const Duration(seconds: 30);
        if (changed) {
          _events.add(const SyncStarted());
          final s = await _serial(
            () => rust.syncAccount(accountId: accountId, inboxOnly: true),
          );
          _events.add(SyncFinished(fetched: s.fetched, errors: s.errors));
          _events.add(const ThreadsChanged());
        }
      } catch (e) {
        // No network, auth failure, server hiccup: wait and try again, up to every 5 minutes.
        await Future<void>.delayed(backoff);
        backoff = backoff * 2 > const Duration(minutes: 5)
            ? const Duration(minutes: 5)
            : backoff * 2;
      }
    }
    _idleLoops.remove(accountId);
  }

  static Color _accountColor(String kind, int i) => switch (kind) {
    'gmail' => Swatch.green,
    'outlook' => Swatch.blue,
    'jmap' => Swatch.purple,
    _ => const [Swatch.teal, Swatch.pink, Swatch.orange, Swatch.purple][i % 4],
  };

  @override
  Stream<RepoEvent> get events => _events.stream;

  @override
  Future<List<Account>> accounts() async {
    final list = await rust.listAccounts();
    return [
      for (final (i, a) in list.indexed)
        Account(
          id: a.id.toInt(),
          email: a.email,
          kind: a.kind,
          color: _accountColor(a.kind, i),
          unread: a.unread,
        ),
    ];
  }

  @override
  Future<List<Folder>> folders() async {
    final unread = await rust.unreadCount();
    return [
      Folder(
        id: 1,
        accountId: 0,
        name: 'inbox',
        role: FolderRole.inbox,
        unread: unread,
      ),
      const Folder(
        id: 2,
        accountId: 0,
        name: 'starred',
        role: FolderRole.starred,
      ),
      const Folder(id: 3, accountId: 0, name: 'sent', role: FolderRole.sent),
      const Folder(
        id: 4,
        accountId: 0,
        name: 'archive',
        role: FolderRole.archive,
      ),
      const Folder(id: 5, accountId: 0, name: 'spam', role: FolderRole.junk),
      const Folder(id: 6, accountId: 0, name: 'trash', role: FolderRole.trash),
    ];
  }

  @override
  Future<List<Label>> labels() async => const [];

  Thread _thread(rust.ThreadDto t) => Thread(
    id: t.id.toInt(),
    accountId: t.accountId.toInt(),
    subject: t.subject.isEmpty ? '(no subject)' : t.subject,
    participants: t.participants,
    lastDate: DateTime.fromMillisecondsSinceEpoch(
      t.lastDate.toInt() * 1000,
      isUtc: true,
    ),
    msgCount: t.msgCount,
    unreadCount: t.unreadCount,
    snippet: t.snippet,
    hasAttachment: t.hasAttachment,
    starred: t.starred,
  );

  @override
  Future<List<Thread>> threads(String query, {int limit = 100}) async =>
      (await rust.listThreads(
        query: query,
        limit: limit,
      )).map(_thread).toList();

  @override
  Future<Thread?> thread(int id) async {
    // No single-thread call yet: look it up in the current inbox page, then the wider cache.
    for (final q in const ['', 'in:archive', 'in:sent']) {
      final hit = (await rust.listThreads(
        query: q,
        limit: 500,
      )).where((t) => t.id.toInt() == id).firstOrNull;
      if (hit != null) return _thread(hit);
    }
    return null;
  }

  @override
  Future<List<Message>> messages(int threadId) async {
    final list = await rust.threadMessages(threadId: threadId);
    return [
      for (final m in list)
        Message(
          id: m.id.toInt(),
          threadId: m.threadId.toInt(),
          fromName: m.fromName,
          fromAddr: m.fromAddr,
          to: m.to,
          date: DateTime.fromMillisecondsSinceEpoch(
            m.date.toInt() * 1000,
            isUtc: true,
          ),
          text: m.text ?? m.snippet,
          html: m.html,
          blockedImages: m.blockedImages,
          attachments: m.hasAttachment
              ? const [Attachment('attachment', '', kind: 'file')]
              : const [],
        ),
    ];
  }

  @override
  Future<String?> messageHtml(int messageId, {bool remoteImages = false}) =>
      rust.messageHtml(messageId: messageId, loadRemoteImages: remoteImages);

  Timer? _pushTimer;

  /// Local-first actions land in the outbox; push them to the servers shortly after, debounced,
  /// so a message read here shows as read on the phone in seconds rather than at the next timer.
  void _pushSoon() {
    _pushTimer?.cancel();
    _pushTimer = Timer(const Duration(seconds: 2), () async {
      if (_disposed) return;
      try {
        for (final a in await rust.listAccounts()) {
          await _serial(
            () => rust.syncAccount(accountId: a.id.toInt(), inboxOnly: true),
          );
        }
        _events.add(const ThreadsChanged());
      } catch (_) {
        // Offline: the outbox keeps the ops; the next sync replays them.
      }
    });
  }

  Future<void> _after(Future<void> f) async {
    await f;
    _events.add(const ThreadsChanged());
    _pushSoon();
  }

  @override
  Future<void> archive(int threadId) =>
      _after(rust.archiveThread(threadId: threadId));
  @override
  Future<void> trash(int threadId) =>
      _after(rust.trashThread(threadId: threadId));
  @override
  Future<void> markRead(int threadId, bool read) =>
      _after(rust.markRead(threadId: threadId, read: read));
  @override
  Future<void> star(int threadId, bool on) =>
      _after(rust.starThread(threadId: threadId, on_: on));

  Draft _draft(rust.DraftDto d, DraftKind kind) => Draft(
    accountId: d.accountId.toInt(),
    from: d.from,
    to: d.to,
    cc: d.cc,
    bcc: d.bcc,
    subject: d.subject,
    text: d.text,
    inReplyTo: d.inReplyTo,
    references: d.references,
    kind: kind,
  );

  @override
  Future<Draft> newDraft() async =>
      _draft(await rust.newDraft(), DraftKind.fresh);

  @override
  Future<Draft> replyDraft(int threadId, {bool all = false}) async => _draft(
    await rust.replyDraft(threadId: threadId, replyAll: all),
    DraftKind.reply,
  );

  @override
  Future<Draft> forwardDraft(int threadId) async =>
      _draft(await rust.forwardDraft(threadId: threadId), DraftKind.forward);

  @override
  Future<void> send(Draft d) async {
    await rust.sendDraft(
      draft: rust.DraftDto(
        accountId: d.accountId,
        from: d.from,
        to: d.to,
        cc: d.cc,
        bcc: d.bcc,
        subject: d.subject,
        text: d.text,
        inReplyTo: d.inReplyTo,
        references: d.references,
      ),
    );
    _events.add(const ThreadsChanged());
  }

  @override
  Future<void> testImapLogin({
    required String email,
    required String host,
    required int port,
    required String password,
  }) => rust.testImapLogin(
    email: email,
    host: host,
    port: port,
    password: password,
  );

  @override
  Future<Account> addImapAccount({
    required String email,
    required String host,
    required int port,
    required String password,
    String displayName = '',
  }) async {
    final a = await rust.addImapAccount(
      email: email,
      host: host,
      port: port,
      password: password,
      displayName: displayName,
    );
    _events.add(const ThreadsChanged());
    unawaited(_refreshIdleLoops());
    return Account(
      id: a.id.toInt(),
      email: a.email,
      kind: a.kind,
      color: _accountColor(a.kind, 0),
    );
  }

  @override
  Future<void> removeAccount(int id) async {
    await rust.removeAccount(id: id);
    _idleLoops[id] = false;
    _events.add(const ThreadsChanged());
  }

  @override
  Future<void> sync() async {
    _events.add(const SyncStarted());
    try {
      final s = await _serial(() => rust.syncAll(inboxOnly: false));
      _events.add(SyncFinished(fetched: s.fetched, errors: s.errors));
    } catch (e) {
      _events.add(SyncFinished(fetched: 0, errors: ['$e']));
    }
    _events.add(const ThreadsChanged());
  }

  void dispose() {
    _disposed = true;
    _pushTimer?.cancel();
    _periodic?.cancel();
    _sub?.cancel();
    _events.close();
  }
}
