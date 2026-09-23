import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' show AppLifecycleListener, Color;
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show AnyhowException, ExternalLibrary;

import '../src/rust/api/mail.dart' as rust;
import '../src/rust/api/signin.dart' as rust;
import '../src/rust/frb_generated.dart';
import 'models.dart';
import 'repository.dart';

/// MailRepository backed by the Rust core through flutter_rust_bridge.
class RustRepository implements MailRepository {
  RustRepository._();

  final _events = StreamController<RepoEvent>.broadcast();
  StreamSubscription<rust.SyncEventDto>? _sub;
  final _idleLoops = <int, bool>{}; // account id → keep running

  /// Accounts whose server refused the stored password. They wait for a new one: no IDLE,
  /// no timer, no outbox pushes, since every retry counts toward a lockout.
  final _problems = <int, Problem>{};
  Timer? _periodic;
  bool _disposed = false;
  final _locks = <int, Future<void>>{};
  AppLifecycleListener? _lifecycle;
  DateTime? _lastSync;

  /// One sync per account at a time: its IDLE loop, the timer, outbox pushes and the user
  /// share that account's connection quota. Different accounts run side by side. The core
  /// gives up on a silent server within a minute; the deadline here is the last resort, so
  /// one call that never returns cannot hold the account forever.
  Future<T> _serial<T>(
    int accountId,
    Future<T> Function() body, {
    Duration deadline = const Duration(minutes: 10),
  }) {
    final previous = _locks[accountId] ?? Future<void>.value();
    final done = Completer<void>();
    _locks[accountId] = done.future;
    final run = previous.then((_) => body());
    // The lock is held until the core call really ends, so two syncs of one account never
    // overlap; the deadline only stops the caller from waiting on it.
    run.then((_) {}, onError: (Object _) {}).whenComplete(() {
      done.complete();
      if (identical(_locks[accountId], done.future)) _locks.remove(accountId);
    });
    return run.timeout(deadline);
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
  /// Windows: CMake puts mail_bridge.dll next to the executable. Elsewhere
  /// flutter_rust_bridge's default lookup applies (rust/target/release for dev).
  static ExternalLibrary? _bundledLibrary() {
    // iOS: the bridge is a static library linked into the executable (scripts/build_bridge_ios.sh).
    if (Platform.isIOS) return ExternalLibrary.process(iKnowHowToUseIt: true);
    if (Platform.isWindows) {
      final dll = File(
        '${File(Platform.resolvedExecutable).parent.path}\\mail_bridge.dll',
      );
      return dll.existsSync() ? ExternalLibrary.open(dll.path) : null;
    }
    if (!Platform.isMacOS) return null;
    final exe = File(Platform.resolvedExecutable);
    final path = '${exe.parent.parent.path}/Frameworks/libmail_bridge.dylib';
    return File(path).existsSync() ? ExternalLibrary.open(path) : null;
  }

  static Future<RustRepository> open({String? dataDir}) async {
    // Retry after a failed start: the library is already loaded.
    if (!RustLib.instance.initialized) {
      await RustLib.init(externalLibrary: _bundledLibrary());
    }
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
        // Folder errors come back in the sync summary, where they are put in words.
      }
    });
    return repo;
  }

  /// Keeps mail fresh without the user asking: a sync on start, an IMAP IDLE loop per account
  /// (the server pushes, we fetch), and a periodic fallback for servers where IDLE misbehaves.
  Future<void> startBackgroundSync() async {
    await _scheduleWake();
    await sync();
    _periodic?.cancel();
    _periodic = Timer.periodic(const Duration(minutes: 10), (_) {
      sync();
      _scheduleWake();
    });
    // Back from the background (a phone unlocked, a window restored): sockets may have
    // died and snoozes come due while nothing ran. Catch up at once.
    _lifecycle ??= AppLifecycleListener(
      onHide: () => _hiddenAt ??= DateTime.now(),
      onShow: _shown,
    );
    await _refreshIdleLoops();
  }

  DateTime? _hiddenAt;
  Future<void>? _fullSync;

  /// Only a real absence counts: on the desktop, focus moving between windows fires
  /// resume events all the time, and each would start a full sync.
  void _shown() {
    final hidden = _hiddenAt;
    _hiddenAt = null;
    if (_disposed || hidden == null) return;
    if (DateTime.now().difference(hidden) < const Duration(seconds: 30)) return;
    final last = _lastSync;
    if (_fullSync == null &&
        (last == null ||
            DateTime.now().difference(last) > const Duration(seconds: 30))) {
      unawaited(sync());
    }
    unawaited(_scheduleWake());
    unawaited(_refreshIdleLoops());
  }

  Future<void> _refreshIdleLoops() async {
    final ids = {
      for (final a in await rust.listAccounts())
        if (!(_problems[a.id.toInt()]?.isAuth ?? false)) a.id.toInt(),
    };
    for (final id in ids) {
      final running = _idleLoops.containsKey(id);
      // A loop told to stop may still sit in IDLE; telling it to go on is enough.
      _idleLoops[id] = true;
      if (!running) unawaited(_idleLoop(id));
    }
    for (final id in _idleLoops.keys.toList()) {
      if (!ids.contains(id)) _idleLoops[id] = false;
    }
  }

  Future<void> _idleLoop(int accountId) async {
    var backoff = const Duration(seconds: 30);
    while (!_disposed && (_idleLoops[accountId] ?? false)) {
      try {
        // Re-enter every 10 minutes: servers drop IDLE after ~29, home routers forget a
        // quiet connection much sooner, and each entry checks for mail that slipped by.
        final changed = await rust.waitForChange(
          accountId: accountId,
          timeoutSecs: 10 * 60,
        );
        if (changed &&
            (_idleLoops[accountId] ?? false) &&
            !_parked(accountId)) {
          _events.add(const SyncStarted());
          final errors = <String>[];
          rust.SyncSummaryDto? s;
          try {
            s = await _serial(
              accountId,
              () async => _parked(accountId)
                  ? null
                  : await rust.syncAccount(
                      accountId: accountId,
                      inboxOnly: true,
                    ),
            );
            if (s != null) await _absorb(accountId, s, errors);
          } catch (e) {
            final host = (await _account(accountId))?.imapHost ?? '';
            errors.add(problemFrom(e, host).title);
            rethrow;
          } finally {
            // Every SyncStarted gets its SyncFinished, or the status line spins forever.
            _events.add(SyncFinished(fetched: s?.fetched ?? 0, errors: errors));
            _events.add(const ThreadsChanged());
          }
          // A sync that failed leaves the mail unseen, so the next wait reports it again
          // at once: back off as after any failure instead of spinning at one pace.
          if (errors.isNotEmpty) {
            await Future<void>.delayed(backoff);
            backoff = backoff * 2 > const Duration(minutes: 5)
                ? const Duration(minutes: 5)
                : backoff * 2;
            continue;
          }
        }
        backoff = const Duration(seconds: 30);
      } catch (e) {
        final host = (await _account(accountId))?.imapHost ?? '';
        final p = problemFrom(e, host);
        if (p.isAuth) {
          await _stop(accountId, p);
          break;
        }
        // No network, auth failure, server hiccup: wait and try again, up to every 5 minutes.
        await Future<void>.delayed(backoff);
        backoff = backoff * 2 > const Duration(minutes: 5)
            ? const Duration(minutes: 5)
            : backoff * 2;
      }
    }
    _idleLoops.remove(accountId);
  }

  /// The core's error text put in words.
  static Problem problemFrom(Object e, String host, {String? stage}) {
    if (e is Problem) return e;
    final raw = e is AnyhowException ? e.message : '$e';
    // The bridge sends anyhow's Debug text: the message, then "Caused by:" and a stack
    // backtrace after a blank line. Only the message is about the server.
    final cut = raw.indexOf('\n\n');
    final message = (cut < 0 ? raw : raw.substring(0, cut)).trim();
    final d = rust.diagnoseError(message: message, host: host);
    return Problem(
      kind: d.kind,
      title: d.title,
      hint: d.hint,
      detail: message,
      stage: stage,
    );
  }

  Future<rust.AccountDto?> _account(int id) async {
    for (final a in await rust.listAccounts()) {
      if (a.id.toInt() == id) return a;
    }
    return null;
  }

  /// Park an account on a sign-in problem until the user acts.
  Future<void> _stop(int accountId, Problem p) async {
    _problems[accountId] = p;
    if (_idleLoops.containsKey(accountId)) _idleLoops[accountId] = false;
    _events.add(const ThreadsChanged());
  }

  bool _parked(int accountId) => _problems[accountId]?.isAuth ?? false;

  /// Read one account's sync summary into [errors] (worded, prefixed with the address);
  /// a refused password parks the account.
  Future<void> _absorb(
    int accountId,
    rust.SyncSummaryDto s,
    List<String> errors,
  ) async {
    if (s.errors.isEmpty && s.folderErrors.isEmpty) return;
    final a = await _account(accountId);
    final email = a?.email ?? '#$accountId';
    final host = a?.imapHost ?? '';
    for (final e in s.errors) {
      final p = problemFrom(e, host);
      if (p.isAuth) {
        // Shown on the account itself (sidebar, settings) until a new password.
        await _stop(accountId, p);
      } else {
        errors.add('$email: ${p.title}');
      }
    }
    for (final e in s.folderErrors) {
      final cut = e.indexOf(': ');
      final folder = cut < 0 ? '' : e.substring(0, cut);
      final p = problemFrom(cut < 0 ? e : e.substring(cut + 2), host);
      errors.add('$email · $folder: ${p.title}');
    }
  }

  static rust.ServerDto _server(ServerSetup s) =>
      rust.ServerDto(host: s.host.trim(), port: s.port, security: s.security);

  static ServerSetup _setup(String host, int port, String security) =>
      ServerSetup(host: host, port: port, startTls: security == 'starttls');

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
          displayName: a.displayName,
          signature: a.signature,
          server: '${a.imapHost}:${a.imapPort}',
          imap: _setup(a.imapHost, a.imapPort, a.imapSecurity),
          smtp: a.smtpHost.isEmpty
              ? null
              : _setup(a.smtpHost, a.smtpPort, a.smtpSecurity),
          localBridge: a.localBridge,
          problem: _problems[a.id.toInt()],
          auth: a.auth,
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
      Folder(
        id: 7,
        accountId: 0,
        name: 'drafts',
        role: FolderRole.drafts,
        unread: (await rust.listLocalDrafts()).length,
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
    snoozedUntil: t.snoozedUntil == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            t.snoozedUntil!.toInt() * 1000,
            isUtc: true,
          ),
  );

  @override
  Future<List<Folder>> accountFolders(int accountId) async => [
    for (final f in await rust.listFolders(accountId: accountId))
      Folder(
        id: f.id.toInt(),
        accountId: f.accountId.toInt(),
        name: f.name,
        role: FolderRole.values.asNameMap()[f.role] ?? FolderRole.other,
      ),
  ];

  @override
  Future<void> moveThread(int threadId, int folderId) =>
      _after(rust.moveThread(threadId: threadId, folderId: folderId));

  @override
  Future<void> snooze(int threadId, DateTime until) async {
    await rust.snoozeThread(
      threadId: threadId,
      until: until.toUtc().millisecondsSinceEpoch ~/ 1000,
    );
    _events.add(const ThreadsChanged());
    _scheduleWake();
  }

  @override
  Future<void> unsnooze(int threadId) async {
    await rust.unsnoozeThread(threadId: threadId);
    _events.add(const ThreadsChanged());
    _scheduleWake();
  }

  Timer? _wakeTimer;

  /// One timer for the next snooze that ends; waking marks threads unread, which then
  /// goes to the server like any local action.
  Future<void> _scheduleWake() async {
    _wakeTimer?.cancel();
    if (_disposed) return;
    try {
      if (await rust.wakeSnoozed() > 0) {
        _events.add(const ThreadsChanged());
        _pushSoon();
      }
      final next = await rust.nextSnoozeWake();
      if (next == null) return;
      final at = DateTime.fromMillisecondsSinceEpoch(next.toInt() * 1000);
      final wait = at.difference(DateTime.now());
      _wakeTimer = Timer(
        wait.isNegative ? Duration.zero : wait + const Duration(seconds: 1),
        _scheduleWake,
      );
    } catch (_) {
      // The periodic sync retries.
    }
  }

  @override
  Future<List<Thread>> threads(String query, {int limit = 100}) async =>
      (await rust.listThreads(
        query: query,
        limit: limit,
      )).map(_thread).toList();

  @override
  Future<Thread?> thread(int id) async {
    final t = await rust.getThread(threadId: id);
    return t == null ? null : _thread(t);
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
          styled: m.styled,
          isMine: m.isMine,
          attachments: [
            for (final a in m.attachments)
              Attachment(
                messageId: a.messageId.toInt(),
                idx: a.idx,
                name: a.name,
                mime: a.mime,
                size: a.size.toInt(),
              ),
          ],
        ),
    ];
  }

  @override
  Future<String?> messageHtml(int messageId, {bool remoteImages = false}) =>
      rust.messageHtml(messageId: messageId, loadImages: remoteImages);

  @override
  Future<String> openAttachment(Attachment a) =>
      rust.openAttachment(messageId: a.messageId, idx: a.idx);

  @override
  Future<String> saveAttachment(Attachment a, String dir) =>
      rust.saveAttachment(messageId: a.messageId, idx: a.idx, dir: dir);

  @override
  String displayFileName(String name) => rust.safeFileName(name: name);

  @override
  String? riskyExtension(String name) => rust.riskyExtension(name: name);

  @override
  Future<DraftAttachment> describeFile(String path) async =>
      _draftAttachment(await rust.describeFile(path: path));

  static DraftAttachment _draftAttachment(rust.DraftAttachmentDto a) =>
      DraftAttachment(
        name: a.name,
        mime: a.mime,
        size: a.size.toInt(),
        path: a.path,
        messageId: a.messageId?.toInt(),
        idx: a.idx,
      );

  Timer? _pushTimer;

  /// Local-first actions land in the outbox; push them to the servers shortly after, debounced,
  /// so a message read here shows as read on the phone in seconds rather than at the next timer.
  void _pushSoon() {
    _pushTimer?.cancel();
    _pushTimer = Timer(const Duration(seconds: 2), () async {
      if (_disposed) return;
      try {
        final errors = <String>[];
        var fetched = 0;
        await Future.wait([
          for (final a in await rust.listAccounts())
            () async {
              final id = a.id.toInt();
              // Checked again inside the lock: the account may have been parked meanwhile.
              final s = await _serial(
                id,
                () async => _parked(id)
                    ? null
                    : await rust.syncAccount(accountId: id, inboxOnly: true),
              );
              if (s != null) {
                fetched += s.fetched;
                await _absorb(id, s, errors);
              }
            }(),
        ]);
        // Mail that came with this sync is new mail like any other (notifications).
        if (errors.isNotEmpty || fetched > 0) {
          _events.add(SyncFinished(fetched: fetched, errors: errors));
        }
        _events.add(const ThreadsChanged());
      } catch (_) {
        // Offline: the outbox keeps the ops; the next sync replays them.
      }
    });
  }

  Future<T> _after<T>(Future<T> f) async {
    final r = await f;
    _events.add(const ThreadsChanged());
    _pushSoon();
    return r;
  }

  static int _filed(rust.FiledDto r) {
    final m = r.missing;
    if (m != null) {
      throw MissingFolder(
        accountId: m.accountId.toInt(),
        role: m.role,
        gmail: m.gmail,
        message: m.message,
      );
    }
    return r.moved;
  }

  @override
  Future<int> archive(int threadId) =>
      _after(rust.archiveThread(threadId: threadId)).then(_filed);
  @override
  Future<int> trash(int threadId) =>
      _after(rust.trashThread(threadId: threadId)).then(_filed);

  /// The accounts a query covers: the one `account:` names, or all.
  Future<List<Account>> _accountsFor(String query) async {
    final named = RegExp(r'(?:^|\s)account:(\S+)').firstMatch(query)?.group(1);
    return [
      for (final a in await accounts())
        if (named == null ||
            a.email.toLowerCase().contains(named.toLowerCase()))
          a,
    ];
  }

  /// Run [call] for each account the query covers, each in its own queue; one account
  /// that fails does not stop the others. Throws (worded) only when all of them failed.
  Future<List<T>> _perAccount<T>(
    String query,
    Future<T> Function(int accountId) call,
  ) async {
    final out = <T>[];
    Problem? first;
    var tried = 0;
    try {
      for (final a in await _accountsFor(query)) {
        if (_parked(a.id)) continue;
        tried++;
        try {
          final r = await _serial<T?>(
            a.id,
            () async => _parked(a.id) ? null : await call(a.id),
          );
          if (r != null) out.add(r);
        } catch (e) {
          final p = problemFrom(e, (await _account(a.id))?.imapHost ?? '');
          if (p.isAuth) await _stop(a.id, p);
          first ??= p;
        }
      }
    } finally {
      _events.add(const MailImported());
      _events.add(const ThreadsChanged());
    }
    if (first != null && out.isEmpty && tried > 0) throw first;
    return out;
  }

  @override
  Future<({int fetched, bool more})> loadOlder(String query) async {
    final rs = await _perAccount(
      query,
      (id) => rust.loadOlder(accountId: id, query: query),
    );
    return (
      fetched: rs.fold<int>(0, (n, r) => n + r.fetched),
      more: rs.any((r) => r.more),
    );
  }

  @override
  Future<int> searchServer(String query) async {
    final rs = await _perAccount(
      query,
      (id) => rust.searchServer(accountId: id, query: query),
    );
    return rs.fold<int>(0, (n, r) => n + r);
  }

  @override
  Future<String> createRoleFolder(int accountId, String role) async {
    try {
      final name = await rust.createRoleFolder(
        accountId: accountId,
        role: role,
      );
      _events.add(const ThreadsChanged());
      return name;
    } catch (e) {
      throw problemFrom(e, (await _account(accountId))?.imapHost ?? '');
    }
  }

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
    attachments: [for (final a in d.attachments) _draftAttachment(a)],
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
  Future<void> updateAccount(
    int id, {
    required String displayName,
    required String signature,
  }) async {
    await rust.updateAccount(
      id: id,
      displayName: displayName,
      signature: signature,
    );
    _events.add(const ThreadsChanged());
  }

  @override
  Future<String?> setting(String key) => rust.getSetting(key: key);

  @override
  Future<void> setSetting(String key, String value) =>
      rust.setSetting(key: key, value: value);

  @override
  Future<int> saveDraft(Draft d) async => (await rust.saveLocalDraft(
    id: d.localId,
    kind: d.kind.name,
    draft: _dto(d),
  )).toInt();

  @override
  Future<List<Draft>> drafts() async => [
    for (final s in await rust.listLocalDrafts())
      _draft(
        s.draft,
        DraftKind.values.asNameMap()[s.kind] ?? DraftKind.fresh,
      ).copyWith(
        localId: s.id.toInt(),
        savedAt: DateTime.fromMillisecondsSinceEpoch(
          s.updatedAt.toInt() * 1000,
          isUtc: true,
        ),
      ),
  ];

  @override
  Future<void> deleteDraft(int localId) => rust.deleteLocalDraft(id: localId);

  static rust.DraftDto _dto(Draft d) => rust.DraftDto(
    accountId: d.accountId,
    from: d.from,
    to: d.to,
    cc: d.cc,
    bcc: d.bcc,
    subject: d.subject,
    text: d.text,
    inReplyTo: d.inReplyTo,
    references: d.references,
    attachments: [
      for (final a in d.attachments)
        rust.DraftAttachmentDto(
          name: a.name,
          mime: a.mime,
          size: a.size,
          path: a.path,
          messageId: a.messageId,
          idx: a.idx,
        ),
    ],
  );

  @override
  Future<String?> send(Draft d) async {
    final String? warning;
    try {
      warning = await rust.sendDraft(draft: _dto(d));
    } catch (e) {
      final a = await _account(d.accountId);
      throw problemFrom(e, a?.smtpHost ?? '', stage: 'smtp');
    }
    _events.add(const ThreadsChanged());
    // Bring the Sent copy (and the answered flag) in now rather than at the next timer.
    unawaited(_syncAccounts([d.accountId]).catchError((Object _) {}));
    return warning;
  }

  @override
  Future<void> checkAccount(AccountSetup setup, String password) async {
    try {
      await rust.testImapLogin(
        email: setup.email,
        imap: _server(setup.imap),
        localBridge: setup.localBridge,
        password: password,
      );
    } catch (e) {
      throw problemFrom(e, setup.imap.host, stage: 'imap');
    }
    try {
      await rust.testSmtpLogin(
        email: setup.email,
        smtp: _server(setup.smtp),
        localBridge: setup.localBridge,
        password: password,
      );
    } catch (e) {
      throw problemFrom(e, setup.smtp.host, stage: 'smtp');
    }
  }

  static bool get _phone => Platform.isIOS || Platform.isAndroid;

  @override
  List<String> signInProviders() {
    try {
      return rust.oauthProviders(mobile: _phone);
    } catch (_) {
      return const [];
    }
  }

  /// The sign-in waiting on a browser page (computers), for [cancelSignIn].
  String? _signInSession;

  @override
  void cancelSignIn() {
    final s = _signInSession;
    if (s != null) rust.oauthCancel(session: s);
  }

  @override
  Future<Account> signIn(
    String provider, {
    String? loginHint,
    void Function()? onReturned,
  }) async {
    final host = provider == 'google'
        ? 'imap.gmail.com'
        : 'outlook.office365.com';
    final hint = (loginHint?.trim().isEmpty ?? true) ? null : loginHint!.trim();
    final rust.AccountDto a;
    try {
      a = _phone
          ? await _signInOnPhone(provider, hint, onReturned)
          : await _signInInBrowser(provider, hint);
    } on Problem {
      rethrow;
    } catch (e) {
      throw problemFrom(e, host);
    } finally {
      _signInSession = null;
    }
    // Signed in again: the account that was waiting for it goes on.
    final id = a.id.toInt();
    if (_problems.containsKey(id)) {
      await retryAccount(id);
    } else {
      _events.add(const ThreadsChanged());
      unawaited(_refreshIdleLoops());
    }
    return Account(
      id: id,
      email: a.email,
      kind: a.kind,
      color: _accountColor(a.kind, 0),
      auth: a.auth,
    );
  }

  /// A computer: the default browser, back to a loopback address the core listens on.
  Future<rust.AccountDto> _signInInBrowser(
    String provider,
    String? hint,
  ) async {
    final s = await rust.oauthBegin(
      provider: provider,
      mobile: false,
      expectEmail: hint,
    );
    _signInSession = s.session;
    final opened = await launchUrl(
      Uri.parse(s.url),
      mode: LaunchMode.externalApplication,
    );
    if (!opened) {
      rust.oauthCancel(session: s.session);
      throw const Problem(kind: 'local', title: 'No browser opened');
    }
    return rust.oauthFinish(session: s.session);
  }

  /// A phone: the system's sign-in sheet (AppAuth); the core trades the code it returns.
  Future<rust.AccountDto> _signInOnPhone(
    String provider,
    String? hint,
    void Function()? onReturned,
  ) async {
    final r = await rust.oauthMobileRequest(provider: provider);
    final params = <String, String>{};
    final prompt = <String>[];
    for (final p in r.parameters) {
      final i = p.indexOf('=');
      if (i < 0) continue;
      final (k, v) = (p.substring(0, i), p.substring(i + 1));
      if (k == 'prompt') {
        prompt.add(v);
      } else {
        params[k] = v;
      }
    }
    final AuthorizationResponse res;
    try {
      res = await const FlutterAppAuth().authorize(
        AuthorizationRequest(
          r.clientId,
          r.redirectUri,
          serviceConfiguration: AuthorizationServiceConfiguration(
            authorizationEndpoint: r.authorizationEndpoint,
            tokenEndpoint: r.tokenEndpoint,
          ),
          scopes: r.scopes,
          loginHint: hint,
          additionalParameters: params,
          promptValues: prompt,
        ),
      );
    } on FlutterAppAuthUserCancelledException {
      throw const Problem(kind: 'cancelled', title: 'Sign-in cancelled');
    } on FlutterAppAuthPlatformException catch (e) {
      // The provider's own answer on its page (said no, or an admin rule).
      final text =
          '${e.platformErrorDetails.error} ${e.platformErrorDetails.errorDescription}';
      final kind = text.contains('access_denied')
          ? 'denied'
          : RegExp(r'admin_policy_enforced|AADSTS65001|AADSTS90094')
                .hasMatch(text)
          ? 'admin'
          : 'failed';
      throw problemFrom('sign-in: $kind: $text', '');
    }
    onReturned?.call();
    final code = res.authorizationCode;
    final verifier = res.codeVerifier;
    if (code == null || verifier == null) {
      throw const Problem(
        kind: 'auth',
        title: 'The sign-in page gave nothing back',
      );
    }
    return rust.oauthComplete(
      provider: provider,
      code: code,
      verifier: verifier,
      redirectUri: r.redirectUri,
      expectEmail: hint,
    );
  }

  @override
  Future<Account> addAccount(AccountSetup setup, String password) async {
    final rust.AccountDto a;
    try {
      a = await rust.addImapAccount(
        email: setup.email,
        displayName: setup.displayName,
        imap: _server(setup.imap),
        smtp: _server(setup.smtp),
        localBridge: setup.localBridge,
        password: password,
      );
    } catch (e) {
      throw problemFrom(e, setup.imap.host);
    }
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
  ServerSetup? suggestSmtp(String imapHost) {
    final s = rust.suggestSmtp(imapHost: imapHost);
    return s == null ? null : _setup(s.host, s.port, s.security);
  }

  @override
  Future<void> updatePassword(int accountId, String password) async {
    final a = await _account(accountId);
    if (a == null) {
      throw const Problem(kind: 'local', title: 'The account is gone');
    }
    try {
      await rust.testImapLogin(
        email: a.email,
        imap: rust.ServerDto(
          host: a.imapHost,
          port: a.imapPort,
          security: a.imapSecurity,
        ),
        localBridge: a.localBridge,
        password: password,
      );
      await rust.updateAccountPassword(id: accountId, password: password);
    } catch (e) {
      throw problemFrom(e, a.imapHost, stage: 'imap');
    }
    await retryAccount(accountId);
  }

  /// Unpark and start syncing in the background; the caller does not wait for the sync
  /// (which may queue behind others), only for the account to be let go.
  @override
  Future<void> retryAccount(int accountId) async {
    _problems.remove(accountId);
    _events.add(const ThreadsChanged());
    unawaited(
      _syncAccounts([accountId])
          .then((_) => _refreshIdleLoops())
          .catchError((Object _) {
            // The status line shows sync errors; nothing else to do here.
          }),
    );
  }

  @override
  Future<void> removeAccount(int id) async {
    await rust.removeAccount(id: id);
    // SQLite may give the next account this id: forget everything about this one.
    _problems.remove(id);
    if (_idleLoops.containsKey(id)) _idleLoops[id] = false;
    _events.add(const ThreadsChanged());
  }

  /// A full sync; one already running is joined instead of started twice.
  @override
  Future<void> sync() =>
      _fullSync ??= _syncAccounts(null).whenComplete(() => _fullSync = null);

  /// Sync [ids] (every account when null), skipping accounts parked on a sign-in
  /// problem; they still show in the status line.
  Future<void> _syncAccounts(List<int>? ids) async {
    final list = await rust.listAccounts();
    if (list.isEmpty) return;
    if (ids == null) _lastSync = DateTime.now();
    _events.add(const SyncStarted());
    var fetched = 0;
    final errors = <String>[];
    // Accounts sync side by side: a slow server does not hold up the others.
    await Future.wait([
      for (final a in list)
        if (ids == null || ids.contains(a.id.toInt()))
          () async {
            final id = a.id.toInt();
            try {
              final s = await _serial(
                id,
                () async => _parked(id)
                    ? null
                    : await rust.syncAccount(accountId: id, inboxOnly: false),
              );
              if (s == null) return;
              fetched += s.fetched;
              await _absorb(id, s, errors);
            } catch (e) {
              errors.add('${a.email}: ${problemFrom(e, a.imapHost).title}');
            }
          }(),
    ]);
    _events.add(SyncFinished(fetched: fetched, errors: errors));
    _events.add(const ThreadsChanged());
  }

  void dispose() {
    _disposed = true;
    _lifecycle?.dispose();
    _pushTimer?.cancel();
    _periodic?.cancel();
    _wakeTimer?.cancel();
    _sub?.cancel();
    _events.close();
  }
}
