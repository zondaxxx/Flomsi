import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models.dart';
import '../attachments/attachment_chip.dart';
import '../../state/providers.dart';
import '../../theme/motion.dart';
import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';
import '../shell/shell_actions.dart';

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
                    label: 'Delete',
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
                : _ThreadContent(
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

class _ThreadContent extends ConsumerStatefulWidget {
  const _ThreadContent({super.key, required this.thread, required this.pad});
  final Thread thread;
  final double pad;

  @override
  ConsumerState<_ThreadContent> createState() => _ThreadContentState();
}

class _ThreadContentState extends ConsumerState<_ThreadContent> {
  Timer? _readTimer;

  @override
  void initState() {
    super.initState();
    _scheduleMarkRead();
  }

  @override
  void didUpdateWidget(covariant _ThreadContent old) {
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
    final first = messages.firstOrNull;
    return ListView(
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
            child: _MessageBlock(
              message: m,
              first: i == 0,
              last: i == messages.length - 1,
            ),
          ),
      ],
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

class _MessageBlock extends ConsumerStatefulWidget {
  const _MessageBlock({
    required this.message,
    required this.first,
    required this.last,
  });
  final Message message;
  final bool first;
  final bool last;

  @override
  ConsumerState<_MessageBlock> createState() => _MessageBlockState();
}

class _MessageBlockState extends ConsumerState<_MessageBlock> {
  String? _htmlWithImages;
  bool _loadingImages = false;

  Future<void> _loadImages() async {
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

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final m = widget.message;
    final html = _htmlWithImages ?? m.html;
    final imagesBlocked = _htmlWithImages == null && m.blockedImages > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!widget.first) ...[
          const Hairline(),
          const SizedBox(height: 18),
          Row(
            children: [
              Text(
                m.isMine ? 'you' : m.fromName,
                style: mono(
                  context,
                  size: 12,
                  color: m.isMine ? s.green : s.fg,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '→ ${m.to.join(', ')} · ${formatWhen(m.date)}',
                style: mono(context, size: 12, color: s.fg3),
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
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Material(
            type: MaterialType.transparency,
            child: html != null
                ? HtmlWidget(
                    html,
                    textStyle: ui(context, size: 14, height: 1.6),
                    onTapUrl: _openLink,
                    onErrorBuilder: (context, element, error) =>
                        Text(m.text, style: ui(context, size: 14, height: 1.6)),
                  )
                : SelectableText(
                    m.text,
                    style: ui(context, size: 14, height: 1.6),
                  ),
          ),
        ),
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
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: QuietField(
          controller: _ctl,
          focusNode: _focus,
          hint: 'Reply to ${widget.thread.sender}',
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
