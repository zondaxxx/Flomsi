import 'dart:async';

import 'models.dart';
import 'repository.dart';

/// In-memory data matching the design mockups. Swapped for the Rust core later.
class MockRepository implements MailRepository {
  MockRepository() {
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
            Attachment('invoice-2026-09.pdf', '84 KB', kind: 'pdf'),
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
          attachments: const [Attachment('glass-v3.fig', '12 MB', kind: 'fig')],
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

  @override
  Future<List<Account>> accounts() async => [
    Account(
      id: 1,
      email: 'dev@gmail.com',
      kind: 'gmail',
      color: Swatch.green,
      unread: _unread(1),
    ),
    Account(
      id: 2,
      email: 'me@icloud.com',
      kind: 'icloud',
      color: Swatch.blue,
      unread: _unread(2),
    ),
    Account(
      id: 3,
      email: 'work@outlook.com',
      kind: 'outlook',
      color: Swatch.orange,
      unread: _unread(3),
    ),
  ];

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
    const Folder(
      id: 3,
      accountId: 0,
      name: 'drafts',
      role: FolderRole.drafts,
      unread: 2,
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
    Iterable<Thread> out = _threads;
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
  Future<Thread?> thread(int id) async =>
      _threads.where((t) => t.id == id).firstOrNull;

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
        attachments: t.hasAttachment
            ? const [Attachment('invoice.pdf', '84 KB', kind: 'pdf')]
            : const [],
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

  @override
  Future<void> archive(int threadId) async {
    _threads = _threads.where((t) => t.id != threadId).toList();
    _events.add(const ThreadsChanged());
  }

  @override
  Future<void> trash(int threadId) => archive(threadId);

  @override
  Future<void> markRead(int threadId, bool read) async =>
      _replace(threadId, (t) => t.copyWith(unreadCount: read ? 0 : 1));

  @override
  Future<void> star(int threadId, bool on) async =>
      _replace(threadId, (t) => t.copyWith(starred: on));

  @override
  Future<Draft> newDraft() async =>
      const Draft(accountId: 1, from: 'dev@gmail.com');

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
    );
  }

  @override
  Future<void> send(Draft draft) async {
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
  }

  @override
  Future<void> testImapLogin({
    required String email,
    required String host,
    required int port,
    required String password,
  }) async {}

  @override
  Future<Account> addImapAccount({
    required String email,
    required String host,
    required int port,
    required String password,
    String displayName = '',
  }) async {
    _events.add(const ThreadsChanged());
    return Account(id: 99, email: email, kind: 'imap', color: Swatch.purple);
  }

  @override
  Future<void> removeAccount(int id) async =>
      _events.add(const ThreadsChanged());

  @override
  Future<void> sync() async {
    _events.add(const SyncStarted());
    await Future<void>.delayed(const Duration(milliseconds: 600));
    _events.add(const SyncFinished(fetched: 0));
  }
}
