import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models.dart';
import '../attachments/attachment_chip.dart';
import '../../state/providers.dart';
import '../../theme/app_icons.dart';
import '../../theme/motion.dart';
import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';
import '../shell/shell_actions.dart';
import 'mail_colours.dart';

/// Reading pane: labeled toolbar with keys, mono header block, messages, reply line.
class ThreadBody extends ConsumerWidget {
  const ThreadBody({super.key, this.compact = false, this.onBack});
  final bool compact;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    // Across a reload (every sync event) the thread stays on screen; only a different
    // selection clears it until that one loads.
    final selectedId = ref.watch(selectedThreadIdProvider);
    final loaded = ref.watch(selectedThreadProvider).value;
    final thread = loaded?.id == selectedId ? loaded : null;
    final threads = ref.watch(threadsProvider).value ?? const <Thread>[];
    final actions = ShellActions(ref: ref, context: context);
    // Delete in Trash deletes for good: the button says so.
    ref.watch(queryProvider);
    final forever = actions.shownBin == FolderRole.trash;
    final pos = thread == null
        ? -1
        : threads.indexWhere((t) => t.id == thread.id);
    final pad = compact ? 16.0 : 44.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: s.border)),
          ),
          child: LayoutBuilder(
            builder: (context, c) {
              final labels = c.maxWidth >= 620;
              final enabled = thread != null;
              return Row(
                children: [
                  if (compact) ...[
                    IconBtn(
                      icon: CupertinoIcons.chevron_left,
                      label: 'Back',
                      onTap: onBack,
                    ),
                    const SizedBox(width: 4),
                  ],
                  _Tool(
                    icon: CupertinoIcons.arrowshape_turn_up_left,
                    label: 'Reply',
                    keyHint: keyHintFor(ref, 'thread.reply'),
                    enabled: enabled,
                    showLabel: labels,
                    onTap: () => actions.openReply(),
                  ),
                  _Tool(
                    icon: CupertinoIcons.arrowshape_turn_up_right,
                    label: 'Forward',
                    keyHint: keyHintFor(ref, 'thread.forward'),
                    enabled: enabled,
                    showLabel: labels,
                    onTap: actions.openForward,
                  ),
                  Container(
                    width: 1,
                    height: 16,
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    color: s.border,
                  ),
                  _Tool(
                    icon: CupertinoIcons.archivebox,
                    label: 'Archive',
                    keyHint: keyHintFor(ref, 'thread.archive'),
                    enabled: enabled,
                    showLabel: labels,
                    onTap: actions.archiveSelected,
                  ),
                  _Tool(
                    icon: CupertinoIcons.clock,
                    label: thread?.snoozed ?? false ? 'Snoozed' : 'Snooze',
                    keyHint: keyHintFor(ref, 'thread.snooze'),
                    enabled: enabled,
                    showLabel: labels,
                    onTap: actions.snoozeSelected,
                  ),
                  _Tool(
                    icon: CupertinoIcons.folder,
                    label: 'Move',
                    keyHint: keyHintFor(ref, 'thread.label'),
                    enabled: enabled,
                    showLabel: labels,
                    onTap: actions.moveSelected,
                  ),
                  _Tool(
                    icon: CupertinoIcons.trash,
                    label: forever ? 'Delete Forever' : 'Delete',
                    keyHint: keyHintFor(ref, 'thread.delete'),
                    enabled: enabled,
                    showLabel: labels,
                    onTap: actions.trashSelected,
                  ),
                  const Spacer(),
                  if (pos >= 0)
                    Text(
                      '${pos + 1} / ${threads.length}',
                      style: mono(context, size: 11, color: s.fg3),
                    ),
                ],
              );
            },
          ),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: Motion.of(context, Motion.base),
            switchInCurve: Motion.curve,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, a) => FadeTransition(
              opacity: a,
              child: SlideTransition(
                position: Tween(
                  begin: const Offset(0, 0.012),
                  end: Offset.zero,
                ).animate(a),
                child: child,
              ),
            ),
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topLeft,
              children: [...previous, ?current],
            ),
            child: thread == null
                ? const EmptyNote('No message selected')
                : ThreadContent(
                    key: ValueKey(thread.id),
                    thread: thread,
                    pad: pad,
                  ),
          ),
        ),
        if (thread != null)
          Container(
            padding: EdgeInsets.fromLTRB(pad, 12, pad, 14),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: s.border)),
            ),
            // Keyed by thread: a half-written reply never moves to another thread.
            child: _QuickReply(key: ValueKey(thread.id), thread: thread),
          ),
      ],
    );
  }
}

/// Which messages of a conversation on a phone may fetch their remote images. Held
/// while the conversation is on screen, so it opens with images blocked again next time.
final remoteImagesProvider = NotifierProvider.autoDispose
    .family<RemoteImages, Set<int>, int>((_) => RemoteImages());

class RemoteImages extends Notifier<Set<int>> {
  @override
  Set<int> build() => const {};

  /// Let [messageIds] load their images; each message fetches them itself.
  void allow(Iterable<int> messageIds) => state = {...state, ...messageIds};
}

/// A conversation's subject and messages, in one scrolling selection. On a phone
/// ([phone]) the type is larger, every message has its own header, and a last row
/// starts a reply ([onReply]).
class ThreadContent extends ConsumerStatefulWidget {
  const ThreadContent({
    super.key,
    required this.thread,
    this.pad = Touch.gutter,
    this.phone = false,
    this.onReply,
  });
  final Thread thread;
  final double pad;
  final bool phone;
  final VoidCallback? onReply;

  @override
  ConsumerState<ThreadContent> createState() => _ThreadContentState();
}

class _ThreadContentState extends ConsumerState<ThreadContent> {
  Timer? _readTimer;

  @override
  void initState() {
    super.initState();
    _scheduleMarkRead();
  }

  @override
  void didUpdateWidget(covariant ThreadContent old) {
    super.didUpdateWidget(old);
    if (old.thread.id != widget.thread.id) _scheduleMarkRead();
  }

  /// Reading a thread marks it read after a beat, like every mail client; j/k skimming stays unread.
  void _scheduleMarkRead() {
    _readTimer?.cancel();
    if (!widget.thread.unread) return;
    final id = widget.thread.id;
    _readTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      // A phone page on its way out (Back, Mark as unread, Archive) leaves the
      // conversation as it was.
      if (widget.phone && !(ModalRoute.of(context)?.isActive ?? true)) return;
      ref.read(repositoryProvider).markRead(id, true);
    });
  }

  @override
  void dispose() {
    _readTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final thread = widget.thread;
    final pad = widget.pad;
    final messages =
        ref.watch(messagesProvider(thread.id)).value ?? const <Message>[];
    if (widget.phone) return _phone(context, thread, messages);
    final first = messages.firstOrNull;
    // One selection across the whole thread: text in HTML mail and plain mail alike.
    return SelectionArea(
      child: ListView(
        padding: EdgeInsets.fromLTRB(pad, 30, pad, 24),
        children: [
          Text(
            thread.subject,
            style: ui(
              context,
              size: 20,
              weight: FontWeight.w600,
              height: 1.3,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 12),
          _Meta(
            rows: [
              (
                'from',
                first == null
                    ? thread.sender
                    : '${first.fromName}  <${first.fromAddr}>',
              ),
              ('to', first?.to.join(', ') ?? 'me'),
              (
                'date',
                first == null
                    ? formatWhen(thread.lastDate)
                    : _longDate(first.date),
              ),
              if (thread.labels.isNotEmpty)
                ('labels', thread.labels.map((l) => l.name).join(', ')),
            ],
          ),
          const SizedBox(height: 22),
          for (final (i, m) in messages.indexed)
            Appear(
              delay: Duration(milliseconds: 40 * i),
              child: MessageBlock(
                message: m,
                first: i == 0,
                last: i == messages.length - 1,
              ),
            ),
        ],
      ),
    );
  }

  /// A phone: the subject large, its labels and how many messages, the account when
  /// there are several; each message under its own header; a reply row to end on.
  Widget _phone(BuildContext context, Thread thread, List<Message> messages) {
    final s = context.s;
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final account = accounts.where((a) => a.id == thread.accountId).firstOrNull;
    final count = messages.isEmpty ? thread.msgCount : messages.length;
    return SelectionArea(
      child: ListView(
        padding: EdgeInsets.fromLTRB(widget.pad, 12, widget.pad, 24),
        children: [
          Text(
            thread.subject,
            style: ui(context, size: 21, weight: FontWeight.w600, height: 1.3),
          ),
          if (thread.labels.isNotEmpty || count > 1) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // A chip fills the width it is offered; here it takes its own.
                for (final l in thread.labels)
                  IntrinsicWidth(child: TagChip(l.name)),
                if (count > 1)
                  Text(
                    '$count messages',
                    style: mono(context, size: 12.5, color: s.fg2),
                  ),
              ],
            ),
          ],
          if (accounts.length > 1 && account != null) ...[
            const SizedBox(height: 6),
            Text(
              'in ${account.email}',
              style: ui(context, size: 13, color: s.fg2),
            ),
          ],
          const SizedBox(height: 20),
          for (final (i, m) in messages.indexed)
            Appear(
              key: ValueKey(m.id),
              delay: Duration(milliseconds: 40 * i),
              child: MessageBlock(
                message: m,
                first: i == 0,
                last: i == messages.length - 1,
                phone: true,
                account: account,
              ),
            ),
          if (widget.onReply case final reply? when messages.isNotEmpty) ...[
            const SizedBox(height: 24),
            _ReplyRow(thread: thread, last: messages.last, onTap: reply),
          ],
        ],
      ),
    );
  }

  static String _longDate(DateTime d) {
    final l = d.toLocal();
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${days[l.weekday - 1]} ${l.day} ${months[l.month - 1]} ${l.year}, ${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.rows});
  final List<(String, String)> rows;
  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (k, v) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 60,
                  child: Text(k, style: mono(context, size: 12, color: s.fg3)),
                ),
                Expanded(
                  child: Text(
                    v,
                    style: mono(
                      context,
                      size: 12,
                      color: k == 'labels' ? s.blue : s.fg,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One message of a conversation: who sent it (on a computer from the second message
/// on, the first being in the header block; on a phone always), blocked images, the
/// body and its files.
class MessageBlock extends ConsumerStatefulWidget {
  const MessageBlock({
    super.key,
    required this.message,
    required this.first,
    required this.last,
    this.phone = false,
    this.account,
  });
  final Message message;
  final bool first;
  final bool last;
  final bool phone;

  /// The account the conversation is in: its address reads as "me" among recipients.
  final Account? account;

  @override
  ConsumerState<MessageBlock> createState() => _MessageBlockState();
}

class _MessageBlockState extends ConsumerState<MessageBlock> {
  String? _htmlWithImages;
  bool _loadingImages = false;

  /// The phone's header shows the whole To list and the date.
  bool _details = false;

  @override
  void initState() {
    super.initState();
    // A phone's menu can allow images before this block is built (Load images, then
    // scrolling down to it).
    final m = widget.message;
    if (widget.phone &&
        ref.read(remoteImagesProvider(m.threadId)).contains(m.id)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadImages();
      });
    }
  }

  /// A phone keeps what was allowed in [remoteImagesProvider], where its menu sees it.
  void _allowImages() {
    final m = widget.message;
    ref.read(remoteImagesProvider(m.threadId).notifier).allow([m.id]);
    _loadImages();
  }

  Future<void> _loadImages() async {
    if (_loadingImages || _htmlWithImages != null) return;
    setState(() => _loadingImages = true);
    final html = await ref
        .read(repositoryProvider)
        .messageHtml(widget.message.id, remoteImages: true);
    if (!mounted) return;
    setState(() {
      _htmlWithImages = html;
      _loadingImages = false;
    });
  }

  Future<bool> _openLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !(uri.scheme == 'http' ||
            uri.scheme == 'https' ||
            uri.scheme == 'mailto')) {
      return false;
    }
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// HTML mail. Mail that sets its own colours was designed for a white page, so it gets
  /// one (dark text on dark would be unreadable in the dark theme); the rest takes the
  /// app's colours. `bgcolor`, which the renderer ignores, becomes a background.
  Widget _htmlBody(BuildContext context, String html, Message m) {
    final s = context.s;
    final ink = m.styled ? const Color(0xFF24292F) : null;
    final width = (680 * MediaQuery.devicePixelRatioOf(context)).round();
    final body = HtmlWidget(
      html,
      textStyle: _reading(context, ink),
      onTapUrl: _openLink,
      factoryBuilder: () => _MailWidgets(width),
      customStylesBuilder: (e) {
        final styles = <String, String>{};
        final bg = htmlColour(e.attributes['bgcolor']);
        if (bg != null) styles['background-color'] = bg;
        // A dark fill whose light text colour lived in a <style> block the sanitizer
        // removed: without this the paper's dark ink would sit on it.
        final style = e.attributes['style'];
        final fill = bg ?? styleValue(style, 'background-color');
        if (m.styled &&
            fill != null &&
            isDarkColour(fill) &&
            e.attributes['color'] == null &&
            styleValue(style, 'color') == null) {
          styles['color'] = '#ffffff';
        }
        return styles.isEmpty ? null : styles;
      },
      onErrorBuilder: (context, element, error) =>
          Text(m.text, style: _reading(context, ink)),
    );
    if (!m.styled) return body;
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: s.border),
      ),
      // Links take the light page's blue, not the dark theme's pale one.
      child: Theme(
        data: theme.copyWith(
          colorScheme: theme.colorScheme.copyWith(
            primary: const Color(0xFF0969DA),
          ),
        ),
        child: body,
      ),
    );
  }

  /// Reading text: 16 at 1.55 on a phone, 14 at 1.6 on a computer.
  TextStyle _reading(BuildContext context, [Color? ink]) => widget.phone
      ? ui(context, size: 16, height: 1.55, color: ink)
      : ui(context, size: 14, height: 1.6, color: ink);

  Widget _body(BuildContext context, Message m, String? html) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 680),
    child: Material(
      type: MaterialType.transparency,
      child: html != null
          ? _htmlBody(context, html, m)
          : Text(m.text, style: _reading(context)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final m = widget.message;
    if (widget.phone) {
      ref.listen(remoteImagesProvider(m.threadId), (_, allowed) {
        if (allowed.contains(m.id)) _loadImages();
      });
    }
    final html = _htmlWithImages ?? m.html;
    final imagesBlocked = _htmlWithImages == null && m.blockedImages > 0;
    if (widget.phone) return _phone(context, m, html, imagesBlocked);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!widget.first) ...[
          const Hairline(),
          const SizedBox(height: 18),
          Row(
            children: [
              // The name a sender claims, and the address it really came from. On a
              // narrow screen the name gives way first; the address keeps most room.
              Flexible(
                flex: 3,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        m.isMine ? 'you' : m.fromName,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: mono(
                          context,
                          size: 12,
                          color: m.isMine ? s.green : s.fg,
                        ),
                      ),
                    ),
                    if (!m.isMine && m.fromAddr != m.fromName)
                      Flexible(
                        flex: 2,
                        child: Text(
                          '  <${m.fromAddr}>',
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: mono(context, size: 12, color: s.fg3),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                flex: 2,
                child: Text(
                  '→ ${m.to.join(', ')} · ${formatWhen(m.date)}',
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: mono(context, size: 12, color: s.fg3),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
        ],
        if (imagesBlocked)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Icon(CupertinoIcons.photo, size: 13, color: s.fg3),
                const SizedBox(width: 6),
                Text(
                  '${m.blockedImages} ${m.blockedImages == 1 ? 'image' : 'images'} blocked',
                  style: mono(context, size: 11, color: s.fg3),
                ),
                const SizedBox(width: 10),
                SmallButton(
                  label: _loadingImages ? 'Loading…' : 'Load images',
                  onPressed: _loadingImages ? null : _loadImages,
                ),
              ],
            ),
          ),
        _body(context, m, html),
        if (m.attachments.isNotEmpty) ...[
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final a in m.attachments) AttachmentChip(a)],
          ),
        ],
        SizedBox(height: widget.last ? 0 : 20),
      ],
    );
  }

  /// A phone: the header, the images line with a full-size button, the body, and the
  /// files as rows.
  Widget _phone(BuildContext context, Message m, String? html, bool blocked) {
    final s = context.s;
    final n = m.blockedImages;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!widget.first) ...[
          Divider(height: 1, color: s.border),
          const SizedBox(height: 16),
        ],
        _header(context, m),
        const SizedBox(height: 12),
        if (blocked)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Icon(AppIcons.images, size: 18, color: s.fg2),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$n ${n == 1 ? 'image' : 'images'} blocked',
                    style: ui(context, size: 14, color: s.fg2),
                  ),
                ),
                TextButton(
                  onPressed: _loadingImages ? null : _allowImages,
                  child: Text(_loadingImages ? 'Loading…' : 'Load images'),
                ),
              ],
            ),
          ),
        _body(context, m, html),
        if (m.attachments.isNotEmpty) ...[
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(Touch.radius),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: s.border),
                borderRadius: BorderRadius.circular(Touch.radius),
              ),
              child: Column(
                children: [
                  for (final (i, a) in m.attachments.indexed) ...[
                    if (i > 0) Divider(height: 1, color: s.border),
                    _AttachmentRow(a),
                  ],
                ],
              ),
            ),
          ),
        ],
        SizedBox(height: widget.last ? 0 : 24),
      ],
    );
  }

  /// Name, the address it really came from (never hidden), the time, and "to me, Boris":
  /// a tap anywhere on it shows the whole To list and the date.
  Widget _header(BuildContext context, Message m) {
    final s = context.s;
    final name = m.isMine
        ? 'Me'
        : m.fromName.isEmpty
        ? m.fromAddr
        : m.fromName;
    final duration = Motion.of(context, Motion.fast);
    return Semantics(
      button: true,
      expanded: _details,
      onTapHint: _details ? 'Hide details' : 'Show details',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _details = !_details),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ui(
                      context,
                      size: 16,
                      weight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  formatWhen(m.date),
                  style: mono(context, size: 12.5, color: s.fg2),
                ),
              ],
            ),
            if (m.fromAddr.isNotEmpty && m.fromAddr != name)
              Text(
                m.fromAddr,
                style: mono(context, size: 13, color: s.fg2, height: 1.4),
              ),
            const SizedBox(height: 2),
            Row(
              children: [
                Flexible(
                  child: Text(
                    _toLine(m),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ui(context, size: 13, color: s.fg2),
                  ),
                ),
                const SizedBox(width: 2),
                AnimatedRotation(
                  turns: _details ? 0.5 : 0,
                  duration: duration,
                  child: Icon(AppIcons.expand, size: 16, color: s.fg2),
                ),
              ],
            ),
            AnimatedSize(
              duration: duration,
              curve: Motion.curve,
              alignment: Alignment.topLeft,
              child: !_details
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: _PhoneMeta(
                        rows: [
                          (
                            'to',
                            m.to.isEmpty
                                ? 'undisclosed recipients'
                                : m.to.join(', '),
                          ),
                          ('date', _ThreadContentState._longDate(m.date)),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// "to me, Boris": first names, whole addresses, and "me" for the account's own.
  String _toLine(Message m) {
    if (m.to.isEmpty) return 'to undisclosed recipients';
    final a = widget.account;
    bool mine(String r) {
      final x = r.trim().toLowerCase();
      return x == 'me' ||
          (a != null &&
              (x == a.email.toLowerCase() ||
                  (a.displayName.isNotEmpty &&
                      x == a.displayName.toLowerCase())));
    }

    final names = [
      for (final r in m.to)
        mine(r)
            ? 'me'
            : r.contains('@')
            ? r.trim()
            : r.trim().split(RegExp(r'\s+')).first,
    ];
    return 'to ${names.join(', ')}';
  }
}

/// The phone header's details: a quiet label, then the value as data.
class _PhoneMeta extends StatelessWidget {
  const _PhoneMeta({required this.rows});
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (k, v) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 44,
                  child: Text(k, style: ui(context, size: 13, color: s.fg2)),
                ),
                Expanded(
                  child: Text(
                    v,
                    style: mono(context, size: 13, color: s.fg, height: 1.45),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// A received file on a phone: a 56 row with its kind, name and size. A tap hands it to
/// another app through the share sheet; a file that can run code asks first.
class _AttachmentRow extends ConsumerStatefulWidget {
  const _AttachmentRow(this.attachment);
  final Attachment attachment;

  @override
  ConsumerState<_AttachmentRow> createState() => _AttachmentRowState();
}

class _AttachmentRowState extends ConsumerState<_AttachmentRow> {
  bool _busy = false;

  // The same steps as AttachmentChip's on a touch screen.
  Future<void> _open() async {
    if (_busy) return;
    final a = widget.attachment;
    final repo = ref.read(repositoryProvider);
    final notice = ref.read(noticeProvider.notifier);
    final risky = repo.riskyExtension(a.name);
    if (risky != null) {
      if (!await allowRiskyAttachment(context, repo, a, risky) || !mounted) {
        return;
      }
    }
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    setState(() => _busy = true);
    try {
      await shareAttachment(repo, notice, a, origin: origin);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final a = widget.attachment;
    final repo = ref.read(repositoryProvider);
    final name = repo.displayFileName(a.name);
    final risky = repo.riskyExtension(a.name);
    // The extension is laid out on its own and never cut: a disguised `.pdf.exe` shows.
    final shown = middleEllipsis(name);
    final ext = fileExtension(shown);
    final style = ui(context, size: 15);
    return Semantics(
      button: true,
      label: '$name, ${a.sizeLabel}',
      onTap: _open,
      excludeSemantics: true,
      child: HoverRegion(
        onTap: _open,
        builder: (context, pressed) => Container(
          constraints: const BoxConstraints(minHeight: 56),
          color: pressed ? s.hover : null,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                child: _busy
                    ? const CircularProgressIndicator.adaptive(strokeWidth: 2)
                    : Icon(
                        risky == null
                            ? iconForFile(a.mime, name)
                            : CupertinoIcons.exclamationmark_shield,
                        size: 20,
                        color: risky == null ? s.fg2 : s.red,
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        shown.substring(0, shown.length - ext.length),
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: style,
                      ),
                    ),
                    if (ext.isNotEmpty)
                      Text(ext, maxLines: 1, softWrap: false, style: style),
                    if (risky != null) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: s.red.withValues(alpha: 0.6),
                          ),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          '.$risky',
                          style: mono(context, size: 12, color: s.red),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(a.sizeLabel, style: mono(context, size: 12.5, color: s.fg2)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The last row on a phone: who a reply goes to, address included, so a look-alike
/// sender shows before anything is written. Like the core: the last message's sender, or
/// its recipients when the last message is ours.
class _ReplyRow extends StatelessWidget {
  const _ReplyRow({
    required this.thread,
    required this.last,
    required this.onTap,
  });
  final Thread thread;
  final Message last;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final (String name, String? address) = last.isMine
        ? (last.to.isEmpty ? thread.sender : last.to.join(', '), null)
        : last.fromName.isEmpty || last.fromName == last.fromAddr
        ? (last.fromAddr, null)
        : (last.fromName, last.fromAddr);
    return Semantics(
      button: true,
      label: 'Reply to $name${address == null ? '' : ' <$address>'}',
      onTap: onTap,
      excludeSemantics: true,
      child: HoverRegion(
        onTap: onTap,
        builder: (context, pressed) => Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: pressed ? s.hover : null,
            border: Border.all(color: s.border),
            borderRadius: BorderRadius.circular(Touch.radius),
          ),
          child: Row(
            children: [
              Icon(AppIcons.reply, size: 20, color: s.fg2),
              const SizedBox(width: 12),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: 'Reply to ',
                        style: ui(context, size: 16, color: s.fg2),
                      ),
                      TextSpan(text: name, style: ui(context, size: 16)),
                      if (address != null)
                        TextSpan(
                          text: ' <$address>',
                          style: mono(context, size: 13, color: s.fg2),
                        ),
                    ],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Images decode at most as wide as the reading column (in device pixels): a mail's
/// 4000-pixel photo would otherwise take its full size in memory.
class _MailWidgets extends WidgetFactory {
  _MailWidgets(this.maxWidth);
  final int maxWidth;

  ImageProvider? _fit(ImageProvider? p) =>
      p == null ? null : ResizeImage(p, width: maxWidth, allowUpscaling: false);

  @override
  ImageProvider? imageProviderFromDataUri(String dataUri) =>
      _fit(super.imageProviderFromDataUri(dataUri));

  @override
  ImageProvider? imageProviderFromNetwork(String url) =>
      _fit(super.imageProviderFromNetwork(url));
}

class _Tool extends StatelessWidget {
  const _Tool({
    required this.icon,
    required this.label,
    required this.keyHint,
    required this.enabled,
    required this.onTap,
    this.showLabel = true,
  });
  final bool showLabel;
  final IconData icon;
  final String label;
  final String? keyHint;
  final bool enabled;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Tooltip(
      message: showLabel ? '' : [label, ?keyHint].join('  '),
      child: HoverRegion(
        onTap: enabled ? onTap : null,
        builder: (context, hovered) => AnimatedContainer(
          duration: Motion.of(context, Motion.fast),
          height: 28,
          padding: EdgeInsets.symmetric(horizontal: showLabel ? 9 : 7),
          decoration: BoxDecoration(
            color: hovered && enabled ? s.raised : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Opacity(
            opacity: enabled ? 1 : 0.4,
            child: Row(
              children: [
                Icon(icon, size: 15, color: s.fg2),
                if (showLabel) ...[
                  const SizedBox(width: 6),
                  Text(label, style: ui(context, size: 12.5)),
                  if (keyHint case final k?) ...[
                    const SizedBox(width: 6),
                    KeyHint(k),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One-line reply from the reading pane. ↵ sends; the composer is a keystroke away for anything longer.
class _QuickReply extends ConsumerStatefulWidget {
  const _QuickReply({super.key, required this.thread});
  final Thread thread;
  @override
  ConsumerState<_QuickReply> createState() => _QuickReplyState();
}

class _QuickReplyState extends ConsumerState<_QuickReply> {
  final _ctl = TextEditingController();
  final _focus = FocusNode(debugLabel: 'quick-reply');
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(
      () => ref
          .read(scopeProvider.notifier)
          .set(_focus.hasFocus ? 'search' : 'list'),
    );
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _ctl.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() => _busy = true);
    final repo = ref.read(repositoryProvider);
    // Taken now: the thread may close before the server answers.
    final notice = ref.read(noticeProvider.notifier);
    final Draft d;
    final String? warning;
    try {
      d = await repo.replyDraft(widget.thread.id);
      warning = await repo.send(d.copyWith(text: '$text${d.text}'));
    } catch (e) {
      notice.show(
        'Send failed: ${e is Problem ? '$e' : e.toString().replaceFirst(RegExp(r'^\w+: '), '')}',
        ttl: const Duration(seconds: 6),
      );
      if (mounted) setState(() => _busy = false);
      return;
    }
    // Sent: nothing after this may read as a failure.
    notice.show(
      warning ?? 'Sent to ${d.to.firstOrNull ?? 'the sender'}',
      ttl: warning == null
          ? const Duration(milliseconds: 2500)
          : const Duration(seconds: 8),
    );
    if (!mounted) return;
    _ctl.clear();
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    // Say who the reply goes to, address included, so a look-alike sender shows before
    // anything is sent. Like the core: the last message's sender, or its recipients when
    // the last message is ours.
    final messages = ref.watch(messagesProvider(widget.thread.id)).value;
    final last = messages?.lastOrNull;
    final to = last == null
        ? null
        : last.isMine
        ? last.to.join(', ')
        : last.fromLine;
    return _field(to == null || to.isEmpty ? widget.thread.sender : to);
  }

  Widget _field(String to) => Row(
    children: [
      Expanded(
        child: QuietField(
          controller: _ctl,
          focusNode: _focus,
          hint: 'Reply to $to',
          height: 34,
          onSubmitted: (_) => _send(),
        ),
      ),
      const SizedBox(width: 10),
      SmallButton(
        label: _busy ? 'Sending…' : 'Send',
        hint: '↵',
        height: 34,
        onPressed: _busy ? null : _send,
      ),
    ],
  );
}
