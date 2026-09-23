import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' show Color;

import 'models.dart';
import 'repository.dart';

/// In-memory data matching the design mockups. Swapped for the Rust core later.
class MockRepository implements MailRepository {
  /// With [empty], no accounts: the start screen, for tests and design work.
  MockRepository({bool empty = false}) {
    if (empty) _accountRows.clear();
    final now = DateTime.now();
    DateTime today(int h, int m) =>
        DateTime(now.year, now.month, now.day, h, m);
    DateTime daysAgo(int d, int h) =>
        DateTime(now.year, now.month, now.day - d, h);

    _threads = [
      Thread(
        id: 1,
        accountId: 1,
        subject: '[mail-client] PR #42 · feat(sync): incremental IMAP fetch',
        participants: ['GitHub'],
        lastDate: today(9, 41),
        msgCount: 1,
        unreadCount: 1,
        snippet: 'anna approved these changes · 3 files changed, +212 −48',
        labels: [_ci],
      ),
      Thread(
        id: 2,
        accountId: 1,
        subject: 'Re: Design review Thursday',
        participants: ['Anna Sokolova', 'you'],
        lastDate: today(9, 40),
        msgCount: 2,
        unreadCount: 1,
        snippet: 'Moving it to 15:00, the glass prototype needs one more pass…',
        hasAttachment: true,
        labels: [_work],
      ),
      Thread(
        id: 3,
        accountId: 1,
        subject: 'Deployment ready — mail-client-web',
        participants: ['Vercel'],
        lastDate: today(8, 57),
        msgCount: 1,
        unreadCount: 0,
        snippet: 'production · main · a3f9c1e · built in 41s',
        labels: [_ci],
      ),
      Thread(
        id: 4,
        accountId: 2,
        subject: 'Build 1.0 (12) is ready to test',
        participants: ['Apple Developer'],
        lastDate: today(8, 30),
        msgCount: 1,
        unreadCount: 1,
        snippet: 'TestFlight processing complete for Mail (iOS)',
      ),
      Thread(
        id: 5,
        accountId: 1,
        subject: '3 issues assigned to you',
        participants: ['Linear'],
        lastDate: daysAgo(1, 17),
        msgCount: 1,
        unreadCount: 0,
        snippet: 'MAIL-118 unified inbox ordering · MAIL-121 snooze on Android',
        labels: [_work],
      ),
      Thread(
        id: 6,
        accountId: 3,
        subject: 'Ключи от офиса',
        participants: ['Дмитрий Козлов'],
        lastDate: daysAgo(1, 12),
        msgCount: 1,
        unreadCount: 0,
        snippet: 'Оставил у охраны, скажи что от меня',
        labels: [_personal],
      ),
      Thread(
        id: 7,
        accountId: 1,
        subject: 'Your invoice for September',
        participants: ['Hetzner'],
        lastDate: daysAgo(1, 9),
        msgCount: 1,
        unreadCount: 0,
        snippet: 'Paid · CX22 · mail-sync-worker',
        hasAttachment: true,
        labels: [_invoices],
      ),
      Thread(
        id: 8,
        accountId: 1,
        subject: 'Top stories this week',
        participants: ['Hacker News Digest'],
        lastDate: daysAgo(2, 8),
        msgCount: 1,
        unreadCount: 0,
        snippet: 'Why every mail client eventually reimplements IMAP',
      ),
      Thread(
        id: 9,
        accountId: 1,
        subject: 'Anna left 4 comments in “Mail / Glass”',
        participants: ['Figma'],
        lastDate: daysAgo(2, 7),
        msgCount: 1,
        unreadCount: 0,
        snippet: '“sidebar blur is too strong over bright wallpapers”',
        labels: [_work],
      ),
      Thread(
        id: 10,
        accountId: 1,
        subject: 'Your OAuth consent screen is verified',
        participants: ['Google Cloud'],
        lastDate: daysAgo(3, 19),
        msgCount: 1,
        unreadCount: 0,
        snippet: 'Project mail-client-prod is now in production mode',
      ),
      Thread(
        id: 11,
        accountId: 2,
        subject: 'Lunch next week?',
        participants: ['Marina Wu'],
        lastDate: daysAgo(3, 14),
        msgCount: 1,
        unreadCount: 0,
        snippet: 'Tuesday or Wednesday works, the ramen place near…',
        starred: true,
        labels: [_personal],
      ),
    ];
    _messages = {
      // Newsletters that bring their own colours: dark text on white, white on dark.
      8: [
        Message(
          id: 801,
          threadId: 8,
          fromName: 'Hacker News Digest',
          fromAddr: 'digest@hndigest.example',
          to: ['me'],
          date: daysAgo(2, 8),
          text: 'Top stories this week: Why every mail client eventually reimplements IMAP.',
          html: '<table width="100%" bgcolor="#ffffff" cellpadding="16"><tr><td style="color: #222222"><h2 style="color: #ff6600">Top stories</h2><p style="color: #222222">Why every mail client eventually reimplements IMAP</p><p style="color: #828282; font-size: 12px">412 points · 233 comments</p></td></tr></table>',
          styled: true,
        ),
      ],
      9: [
        Message(
          id: 901,
          threadId: 9,
          fromName: 'Figma',
          fromAddr: 'comments@figma.com',
          to: ['me'],
          date: daysAgo(2, 7),
          text: 'Anna left 4 comments in Mail / Glass.',
          html: '<table width="100%" bgcolor="#1e1e1e" cellpadding="20"><tr><td style="color: #ffffff"><p style="color: #ffffff; font-size: 16px"><b>Anna</b> left 4 comments</p><p style="color: #b3b3b3">“sidebar blur is too strong over bright wallpapers”</p></td></tr></table>',
          styled: true,
          attachments: const [
            Attachment(
              messageId: 901,
              idx: 0,
              name: 'Mail-Glass-export.svg',
              mime: 'image/svg+xml',
              size: 20480,
            ),
          ],
        ),
      ],
      7: [
        Message(
          id: 701,
          threadId: 7,
          fromName: 'Hetzner',
          fromAddr: 'billing@hetzner.com',
          to: ['me'],
          date: daysAgo(1, 9),
          text: 'Your invoice for September is paid. Server CX22 · mail-sync-worker.',
          html: '<p>Hi,</p><p>your invoice for <b>September</b> is paid. Thank you.</p><table cellpadding="6" style="border: 1px solid #444"><tr><th align="left">Item</th><th align="right">Amount</th></tr><tr><td>CX22 · mail-sync-worker</td><td align="right">€ 4.51</td></tr><tr><td>Traffic</td><td align="right">€ 0.00</td></tr></table><p><a href="https://console.hetzner.cloud">Open the console</a></p><p style="color: #888; font-size: 12px">Hetzner Online GmbH · Industriestr. 25 · 91710 Gunzenhausen</p>',
          blockedImages: 1,
          attachments: const [
            Attachment(
              messageId: 701,
              idx: 0,
              name: 'invoice-2026-09.pdf',
              mime: 'application/pdf',
              size: 86016,
            ),
          ],
        ),
      ],
      2: [
        Message(
          id: 201,
          threadId: 2,
          fromName: 'Anna Sokolova',
          fromAddr: 'anna@studio.dev',
          to: ['me'],
          date: today(9, 12),
          text: 'Hey — moving the review to 15:00. The glass prototype needs one more pass on the sidebar translucency over bright wallpapers: contrast drops below 4.5:1 on the light mesh.\n\nCan you check the keyboard flow on the list before then? j/k feels right, but archive on `e` collides with the search field when it has focus.\n\nUpdated frames attached.',
          attachments: const [
            Attachment(
              messageId: 201,
              idx: 0,
              name: 'glass-v3.fig',
              mime: 'application/octet-stream',
              size: 12976128,
            ),
            Attachment(
              messageId: 201,
              idx: 1,
              name: 'sidebar-contrast.png',
              mime: 'image/png',
              size: 493568,
            ),
          ],
        ),
        Message(
          id: 202,
          threadId: 2,
          fromName: 'you',
          fromAddr: 'dev@gmail.com',
          to: ['Anna Sokolova'],
          date: today(9, 40),
          isMine: true,
          text: 'Works for me. I’ll move shortcut handling to a scoped keymap so focused inputs swallow keys first. Will ping you in Linear when it’s up.',
        ),
      ],
    };
  }

  static const _work = Label('work', Swatch.green);
  static const _ci = Label('ci', Swatch.blue);
  static const _invoices = Label('invoices', Swatch.orange);
  static const _personal = Label('personal', Swatch.pink);

  late List<Thread> _threads;
  late Map<int, List<Message>> _messages;
  final _events = StreamController<RepoEvent>.broadcast();

  @override
  Stream<RepoEvent> get events => _events.stream;

  /// Accounts for design work; profiles and removals stay in memory.
  final List<(int, String, String, Color, String)> _accountRows = [
    (1, 'dev@gmail.com', 'gmail', Swatch.green, 'imap.gmail.com:993'),
    (2, 'me@icloud.com', 'icloud', Swatch.blue, 'imap.mail.me.com:993'),
    (
      3,
      'work@outlook.com',
      'outlook',
      Swatch.orange,
      'outlook.office365.com:993',
    ),
  ];
  final Map<int, (String, String)> _profiles = {
    1: ('Zonda', 'Zonda\nflomsi.dev'),
  };
  final Map<String, String> _settings = {};

  @override
  Future<List<Account>> accounts() async => [
    for (final (id, email, kind, color, server) in _accountRows)
      Account(
        id: id,
        email: email,
        kind: kind,
        color: color,
        unread: _unread(id),
        displayName: _profiles[id]?.$1 ?? '',
        signature: _profiles[id]?.$2 ?? '',
        server: server,
        problem: problems[id],
      ),
  ];

  @override
  Future<void> updateAccount(
    int id, {
    required String displayName,
    required String signature,
  }) async {
    _profiles[id] = (displayName, signature);
    _events.add(const ThreadsChanged());
  }

  @override
  Future<String?> setting(String key) async => _settings[key];

  @override
  Future<void> setSetting(String key, String value) async =>
      _settings[key] = value;

  int _unread(int accountId) =>
      _threads.where((t) => t.accountId == accountId && t.unread).length;

  @override
  Future<List<Folder>> folders() async => [
    Folder(
      id: 1,
      accountId: 0,
      name: 'inbox',
      role: FolderRole.inbox,
      unread: _threads.where((t) => t.unread).length,
    ),
    Folder(
      id: 2,
      accountId: 0,
      name: 'starred',
      role: FolderRole.starred,
      unread: _threads.where((t) => t.starred).length,
    ),
    Folder(
      id: 3,
      accountId: 0,
      name: 'drafts',
      role: FolderRole.drafts,
      unread: _drafts.length,
    ),
    const Folder(id: 4, accountId: 0, name: 'sent', role: FolderRole.sent),
    const Folder(
      id: 5,
      accountId: 0,
      name: 'archive',
      role: FolderRole.archive,
    ),
    const Folder(
      id: 6,
      accountId: 0,
      name: 'spam',
      role: FolderRole.junk,
      unread: 7,
    ),
    const Folder(id: 7, accountId: 0, name: 'trash', role: FolderRole.trash),
  ];

  @override
  Future<List<Label>> labels() async => const [
    _work,
    _ci,
    _invoices,
    _personal,
  ];

  @override
  Future<List<Thread>> threads(String query, {int limit = 100}) async {
    final q = query.trim().toLowerCase();
    final now = DateTime.now();
    final snoozedView = q.split(RegExp(r'\s+')).contains('in:snoozed');
    Iterable<Thread> out = _threads.map(
      (t) => _snoozes.containsKey(t.id)
          ? Thread(
              id: t.id,
              accountId: t.accountId,
              subject: t.subject,
              participants: t.participants,
              lastDate: t.lastDate,
              msgCount: t.msgCount,
              unreadCount: t.unreadCount,
              snippet: t.snippet,
              hasAttachment: t.hasAttachment,
              starred: t.starred,
              labels: t.labels,
              snoozedUntil: _snoozes[t.id],
            )
          : t,
    );
    out = snoozedView
        ? out.where((t) => t.snoozedUntil?.isAfter(now) ?? false)
        : out.where((t) => !(t.snoozedUntil?.isAfter(now) ?? false));
    for (final tok in q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty)) {
      if (tok == 'is:unread') {
        out = out.where((t) => t.unread);
      } else if (tok == 'is:starred') {
        out = out.where((t) => t.starred);
      } else if (tok == 'has:attachment') {
        out = out.where((t) => t.hasAttachment);
      } else if (tok.startsWith('from:')) {
        final v = tok.substring(5);
        out = out.where(
          (t) => t.participants.any((p) => p.toLowerCase().contains(v)),
        );
      } else if (tok.startsWith('#') || tok.startsWith('label:')) {
        final v = tok.startsWith('#') ? tok.substring(1) : tok.substring(6);
        out = out.where((t) => t.labels.any((l) => l.name == v));
      } else if (tok.startsWith('account:')) {
        final email = tok.substring(8);
        final ids = {
          for (final (id, e, _, _, _) in _accountRows)
            if (e.toLowerCase() == email) id,
        };
        out = out.where((t) => ids.contains(t.accountId));
      } else if (tok.startsWith('in:')) {
        // mock has only an inbox
      } else {
        out = out.where(
          (t) =>
              t.subject.toLowerCase().contains(tok) ||
              t.snippet.toLowerCase().contains(tok) ||
              t.participants.any((p) => p.toLowerCase().contains(tok)),
        );
      }
    }
    final list = out.toList()..sort((a, b) => b.lastDate.compareTo(a.lastDate));
    return list.take(limit).toList();
  }

  @override
  Future<Thread?> thread(int id) async {
    final t = _threads.where((t) => t.id == id).firstOrNull;
    if (t == null || !_snoozes.containsKey(id)) return t;
    return Thread(
      id: t.id,
      accountId: t.accountId,
      subject: t.subject,
      participants: t.participants,
      lastDate: t.lastDate,
      msgCount: t.msgCount,
      unreadCount: t.unreadCount,
      snippet: t.snippet,
      hasAttachment: t.hasAttachment,
      starred: t.starred,
      labels: t.labels,
      snoozedUntil: _snoozes[id],
    );
  }

  @override
  Future<List<Message>> messages(int threadId) async {
    if (_messages.containsKey(threadId)) return _messages[threadId]!;
    final t = _threads.firstWhere((t) => t.id == threadId);
    return [
      Message(
        id: threadId * 100,
        threadId: threadId,
        fromName: t.sender,
        fromAddr: '${t.sender.toLowerCase().replaceAll(' ', '.')}@example.com',
        to: ['me'],
        date: t.lastDate,
        text: t.snippet,
        attachments: [
          if (t.hasAttachment)
            Attachment(
              messageId: threadId * 100,
              idx: 0,
              name: 'invoice.pdf',
              mime: 'application/pdf',
              size: 86016,
            ),
        ],
      ),
    ];
  }

  @override
  Future<String?> messageHtml(
    int messageId, {
    bool remoteImages = false,
  }) async => null;

  void _replace(int id, Thread Function(Thread) f) {
    _threads = _threads.map((t) => t.id == id ? f(t) : t).toList();
    _events.add(const ThreadsChanged());
  }

  /// The providers this demo offers to sign in with (a test can change it).
  List<String> providers = const ['google'];

  @override
  List<String> signInProviders() => providers;

  @override
  void cancelSignIn() {}

  /// What the next [signIn] does instead of succeeding (a test sets it).
  Problem? signInFails;

  @override
  Future<Account> signIn(
    String provider, {
    String? loginHint,
    void Function()? onReturned,
  }) async {
    onReturned?.call();
    final fail = signInFails;
    if (fail != null) {
      signInFails = null;
      throw fail;
    }
    final email = provider == 'google' ? 'you@gmail.com' : 'you@outlook.com';
    final kind = provider == 'google' ? 'gmail' : 'outlook';
    final id = _accountRows.fold(0, (m, a) => a.$1 > m ? a.$1 : m) + 1;
    if (!_accountRows.any((a) => a.$2 == email)) {
      _accountRows.add((id, email, kind, Swatch.blue, 'imap.gmail.com:993'));
    }
    signedIn.add(email);
    _events.add(const ThreadsChanged());
    return Account(
      id: id,
      email: email,
      kind: kind,
      color: const Color(0xFF74ADE8),
      auth: 'xoauth2',
    );
  }

  /// Addresses signed in through [signIn], for tests.
  final List<String> signedIn = [];

  /// How many older messages each "Load older" call brings (a test can change it).
  int olderOnServer = 0;

  @override
  Future<({int fetched, bool more})> loadOlder(String query) async {
    final n = olderOnServer;
    olderOnServer = 0;
    return (fetched: n, more: false);
  }

  @override
  Future<int> searchServer(String query) async => 0;

  /// Accounts whose server has no Archive folder yet (for trying the ask-and-create path).
  final Set<int> noArchive = {};

  @override
  Future<String> createRoleFolder(int accountId, String role) async {
    if (role == 'archive') noArchive.remove(accountId);
    return role == 'archive' ? 'Archive' : 'Trash';
  }

  @override
  Future<int> archive(int threadId) async {
    final t = _threads.where((t) => t.id == threadId).firstOrNull;
    if (t != null && noArchive.contains(t.accountId)) {
      throw MissingFolder(
        accountId: t.accountId,
        role: 'archive',
        gmail: false,
        message: 'the server has no Archive folder',
      );
    }
    final before = _threads.length;
    _threads = _threads.where((t) => t.id != threadId).toList();
    _events.add(const ThreadsChanged());
    return before - _threads.length;
  }

  @override
  Future<int> trash(int threadId) async {
    final before = _threads.length;
    _threads = _threads.where((t) => t.id != threadId).toList();
    _events.add(const ThreadsChanged());
    return before - _threads.length;
  }

  final Map<int, DateTime> _snoozes = {};

  @override
  Future<void> snooze(int threadId, DateTime until) async {
    _snoozes[threadId] = until;
    _events.add(const ThreadsChanged());
  }

  @override
  Future<void> unsnooze(int threadId) async {
    _snoozes.remove(threadId);
    _events.add(const ThreadsChanged());
  }

  @override
  Future<List<Folder>> accountFolders(int accountId) async => [
    for (final (i, (name, role)) in const [
      ('INBOX', FolderRole.inbox),
      ('Archive', FolderRole.archive),
      ('Sent', FolderRole.sent),
      ('Trash', FolderRole.trash),
      ('Projects/Flomsi', FolderRole.other),
      ('Receipts', FolderRole.other),
      ('Travel', FolderRole.other),
    ].indexed)
      Folder(
        id: accountId * 100 + i,
        accountId: accountId,
        name: name,
        role: role,
      ),
  ];

  @override
  Future<void> moveThread(int threadId, int folderId) async {
    await archive(threadId);
  }

  @override
  Future<void> markRead(int threadId, bool read) async =>
      _replace(threadId, (t) => t.copyWith(unreadCount: read ? 0 : 1));

  @override
  Future<void> star(int threadId, bool on) async =>
      _replace(threadId, (t) => t.copyWith(starred: on));

  @override
  Future<Draft> newDraft({int? accountId}) async {
    final all = await accounts();
    if (all.isEmpty) throw StateError('no account');
    final a = all.where((a) => a.id == accountId).firstOrNull ?? all.first;
    return Draft(accountId: a.id, from: a.email);
  }

  @override
  Future<Draft> replyDraft(int threadId, {bool all = false}) async {
    final msgs = await messages(threadId);
    final last = msgs.last;
    final t = _threads.firstWhere((t) => t.id == threadId);
    return Draft(
      accountId: t.accountId,
      from: 'dev@gmail.com',
      to: ['${last.fromName} <${last.fromAddr}>'],
      cc: all ? last.to.where((a) => a != 'me').toList() : const [],
      subject: t.subject.toLowerCase().startsWith('re:')
          ? t.subject
          : 'Re: ${t.subject}',
      text:
          '\n\nOn ${formatWhen(last.date)}, ${last.fromName} wrote:\n${last.text.split('\n').map((l) => '> $l').join('\n')}',
      inReplyTo: 'msg-${last.id}@mock',
      kind: DraftKind.reply,
    );
  }

  @override
  Future<Draft> forwardDraft(int threadId) async {
    final t = _threads.firstWhere((t) => t.id == threadId);
    final last = (await messages(threadId)).last;
    return Draft(
      accountId: t.accountId,
      from: 'dev@gmail.com',
      subject: 'Fwd: ${t.subject}',
      text: '\n\n---------- Forwarded message ----------\n${last.text}',
      kind: DraftKind.forward,
      attachments: [
        for (final a in last.attachments)
          DraftAttachment(
            name: a.name,
            mime: a.mime,
            size: a.size,
            messageId: a.messageId,
            idx: a.idx,
          ),
      ],
    );
  }

  /// A placeholder file: a one-page PDF for .pdf names, a text note otherwise.
  static List<int> _mockBytes(String name) =>
      name.toLowerCase().endsWith('.pdf')
      ? '%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n'
                '2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n'
                '3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 320 120]'
                '/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj\n'
                '4 0 obj<</Length 43>>stream\nBT /F1 16 Tf 32 56 Td (Mock $name) Tj ET\n'
                'endstream endobj\n'
                '5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj\n'
                'trailer<</Root 1 0 R>>\n%%EOF\n'
            .codeUnits
      : 'Mock attachment: $name\n'.codeUnits;

  static String _freePath(String dir, String name) {
    var candidate = '$dir${Platform.pathSeparator}$name';
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    for (var n = 1; File(candidate).existsSync(); n++) {
      candidate = '$dir${Platform.pathSeparator}$stem ($n)$ext';
    }
    return candidate;
  }

  /// Drafts kept "on this device" for design work; one is there from the start.
  final List<Draft> _drafts = [
    Draft(
      accountId: 1,
      from: 'dev@gmail.com',
      to: const ['anna@studio.dev'],
      subject: 'Sidebar contrast numbers',
      text: 'Measured the light mesh again: 3.9:1 on the selected row, 4.6:1 once the tint goes to 12%.',
      localId: 1,
      savedAt: DateTime.now().subtract(const Duration(minutes: 42)),
    ),
  ];
  int _draftSeq = 1;

  @override
  Future<int> saveDraft(Draft draft) async {
    final i = _drafts.indexWhere((d) => d.localId == draft.localId);
    final id = i >= 0 ? draft.localId! : ++_draftSeq + 100;
    final saved = draft.copyWith(localId: id, savedAt: DateTime.now());
    if (i >= 0) _drafts.removeAt(i);
    _drafts.insert(0, saved);
    return id;
  }

  @override
  Future<List<Draft>> drafts() async => List.unmodifiable(_drafts);

  @override
  Future<void> deleteDraft(int localId) async =>
      _drafts.removeWhere((d) => d.localId == localId);

  @override
  Future<String> openAttachment(Attachment a) async {
    final dir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}flomsi-mock',
    )..createSync(recursive: true);
    final f = File('${dir.path}${Platform.pathSeparator}${a.name}');
    if (!f.existsSync()) f.writeAsBytesSync(_mockBytes(a.name));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return f.path;
  }

  @override
  Future<String> saveAttachment(Attachment a, String dir) async {
    Directory(dir).createSync(recursive: true);
    final path = _freePath(dir, a.name);
    File(path).writeAsBytesSync(_mockBytes(a.name));
    return path;
  }

  /// A Dart copy of the core's rules (files.rs), enough for design work and tests.
  @override
  String displayFileName(String name) => name
      .replaceAll(
        RegExp(
          '[\u00AD\u061C\u180E\u200B-\u200F\u202A-\u202E\u2060-\u2064\u2066-\u206F\uFEFF]',
        ),
        '',
      )
      .replaceAll(RegExp('[\u2028\u2029\u0085]'), '_');

  @override
  String? riskyExtension(String name) {
    final clean = displayFileName(name);
    if (!clean.contains('.')) return null;
    final ext = clean.split('.').last.toLowerCase();
    const risky = {
      'exe',
      'com',
      'bat',
      'cmd',
      'msi',
      'scr',
      'pif',
      'js',
      'vbs',
      'hta',
      'ps1',
      'lnk',
      'url',
      'reg',
      'jar',
      'app',
      'pkg',
      'dmg',
      'command',
      'sh',
      'docm',
      'xlsm',
      'pptm',
      'html',
      'htm',
      'svg',
      'iso',
      'img',
      'apk',
      'rdp',
      'msix',
      'appx',
      'appinstaller',
      'msu',
      'xll',
      'xlsb',
      'one',
      'searchconnector-ms',
      'jnlp',
      'py',
      'pyw',
    };
    return risky.contains(ext) ? ext : null;
  }

  @override
  Future<DraftAttachment> describeFile(String path) async {
    final f = File(path);
    final name = f.uri.pathSegments.last;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    const types = {
      'pdf': 'application/pdf',
      'png': 'image/png',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'txt': 'text/plain',
      'zip': 'application/zip',
    };
    return DraftAttachment(
      name: name,
      mime: types[ext] ?? 'application/octet-stream',
      size: await f.length(),
      path: path,
    );
  }

  @override
  Future<String?> send(Draft draft) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (draft.inReplyTo != null) {
      final id = int.tryParse(draft.inReplyTo!.replaceAll(RegExp(r'\D'), ''));
      final tid = _messages.entries
          .where((e) => e.value.any((m) => m.id == id))
          .map((e) => e.key)
          .firstOrNull;
      if (tid != null) {
        _messages[tid] = [
          ..._messages[tid]!,
          Message(
            id: DateTime.now().millisecondsSinceEpoch,
            threadId: tid,
            fromName: 'you',
            fromAddr: draft.from,
            to: draft.to,
            date: DateTime.now(),
            text: draft.text.split('\n\nOn ').first.trim(),
            isMine: true,
          ),
        ];
        _replace(
          tid,
          (t) => Thread(
            id: t.id,
            accountId: t.accountId,
            subject: t.subject,
            participants: [
              ...t.participants,
              if (!t.participants.contains('you')) 'you',
            ],
            lastDate: DateTime.now(),
            msgCount: t.msgCount + 1,
            unreadCount: 0,
            snippet: draft.text.trim().split('\n').first,
            hasAttachment: t.hasAttachment,
            starred: t.starred,
            labels: t.labels,
          ),
        );
      }
    }
    _events.add(const ThreadsChanged());
    return null;
  }

  /// Sign-in problems per account, for design work and tests.
  final Map<int, Problem> problems = {};

  /// The password the mock servers accept; anything else is refused.
  static const goodPassword = 'app-password';

  static const _refused = Problem(
    kind: 'auth',
    title: 'The server rejected the name or password',
    hint: 'Check the address and password. Many providers want an app password for mail apps.',
    detail: 'auth: NO [AUTHENTICATIONFAILED] Invalid credentials',
  );

  @override
  Future<void> checkAccount(AccountSetup setup, String password) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (setup.imap.host.isEmpty) {
      throw const Problem(
        kind: 'network',
        title: "Can't find that server",
        hint: 'Check the server name.',
        stage: 'imap',
      );
    }
    if (password != goodPassword) {
      throw Problem(
        kind: _refused.kind,
        title: _refused.title,
        hint: _refused.hint,
        detail: _refused.detail,
        stage: 'imap',
      );
    }
    if (setup.smtp.host.startsWith('blocked.')) {
      throw const Problem(
        kind: 'network',
        title: 'Nothing answers on that port',
        hint: 'Check the port: 993 for IMAP over TLS, 465 or 587 for SMTP.',
        stage: 'smtp',
      );
    }
  }

  @override
  Future<Account> addAccount(AccountSetup setup, String password) async {
    final email = setup.email.trim();
    if (_accountRows.any((a) => a.$2.toLowerCase() == email.toLowerCase())) {
      throw const Problem(
        kind: 'local',
        title: 'This address is already added',
        hint: 'To use a new password, open Settings → Accounts.',
      );
    }
    final id = _accountRows.fold(0, (m, a) => a.$1 > m ? a.$1 : m) + 1;
    _accountRows.add((
      id,
      email,
      'imap',
      Swatch.purple,
      '${setup.imap.host}:${setup.imap.port}',
    ));
    _events.add(const ThreadsChanged());
    return Account(id: id, email: email, kind: 'imap', color: Swatch.purple);
  }

  @override
  ServerSetup? suggestSmtp(String imapHost) {
    final h = imapHost.trim().toLowerCase();
    if (!h.startsWith('imap.')) return null;
    return ServerSetup(
      host: 'smtp.${h.substring(5)}',
      port: 587,
      startTls: true,
    );
  }

  /// Make the server refuse an account's stored password, as a real one would.
  void failSignIn(int accountId, Problem p) {
    problems[accountId] = p;
    _events.add(const ThreadsChanged());
  }

  @override
  Future<void> updatePassword(int accountId, String password) async {
    if (password != goodPassword) throw _refused;
    await retryAccount(accountId);
  }

  @override
  Future<void> retryAccount(int accountId) async {
    problems.remove(accountId);
    _events.add(const ThreadsChanged());
  }

  @override
  Future<void> removeAccount(int id) async {
    _accountRows.removeWhere((a) => a.$1 == id);
    problems.remove(id);
    _events.add(const ThreadsChanged());
  }

  @override
  Future<void> sync() async {
    _events.add(const SyncStarted());
    await Future<void>.delayed(const Duration(milliseconds: 600));
    _events.add(const SyncFinished(fetched: 0));
  }
}
