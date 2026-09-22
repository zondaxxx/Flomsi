import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../attachments/attachment_chip.dart';
import '../../state/providers.dart';
import '../../theme/motion.dart';
import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';

/// Composer in the reading pane: mono-labelled header fields, plain body, send row.
class ComposeBody extends ConsumerStatefulWidget {
  const ComposeBody({super.key, required this.draft, this.compact = false});
  final Draft draft;
  final bool compact;

  @override
  ConsumerState<ComposeBody> createState() => _ComposeBodyState();
}

class _ComposeBodyState extends ConsumerState<ComposeBody> {
  late final _to = TextEditingController(text: widget.draft.to.join(', '));
  late final _cc = TextEditingController(text: widget.draft.cc.join(', '));
  late final _subject = TextEditingController(text: widget.draft.subject);
  late final _body = TextEditingController(text: widget.draft.text);
  final _bodyFocus = FocusNode(debugLabel: 'compose-body');
  final _toFocus = FocusNode(debugLabel: 'compose-to');
  late var _files = [...widget.draft.attachments];
  bool _showCc = false;
  bool _sending = false;
  bool _picking = false;
  String? _error;

  /// Most servers (Gmail, Outlook, iCloud) refuse messages over 25 MB after base64.
  static const _serverLimit = 25 * 1024 * 1024;
  int get _encodedSize =>
      (_files.fold<int>(0, (sum, f) => sum + f.size) * 4 / 3).ceil();

  @override
  void initState() {
    super.initState();
    _showCc = widget.draft.cc.isNotEmpty;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(scopeProvider.notifier).set('compose');
      if (widget.draft.to.isEmpty) {
        _toFocus.requestFocus();
      } else {
        _bodyFocus.requestFocus();
        _body.selection = const TextSelection.collapsed(offset: 0);
      }
    });
  }

  @override
  void dispose() {
    _to.dispose();
    _cc.dispose();
    _subject.dispose();
    _body.dispose();
    _bodyFocus.dispose();
    _toFocus.dispose();
    super.dispose();
  }

  Draft get _current => widget.draft.copyWith(
    to: _split(_to.text),
    cc: _split(_cc.text),
    subject: _subject.text.trim(),
    text: _body.text,
    attachments: _files,
  );

  Future<void> _attach() async {
    if (_picking) return;
    _picking = true;
    try {
      final picked = await openFiles();
      if (picked.isEmpty) return;
      final repo = ref.read(repositoryProvider);
      final added = [for (final x in picked) await repo.describeFile(x.path)];
      if (mounted) setState(() => _files = [..._files, ...added]);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e.toString().replaceFirst(RegExp(r'^\w+: '), ''),
        );
      }
    } finally {
      _picking = false;
    }
  }

  static List<String> _split(String s) => s
      .split(RegExp(r'[,;]'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  void _close() {
    ref.read(scopeProvider.notifier).set('list');
    ref.read(composeProvider.notifier).close();
  }

  Future<void> send() async {
    final d = _current;
    if (d.to.isEmpty) {
      setState(() => _error = 'Add at least one recipient.');
      _toFocus.requestFocus();
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await ref.read(repositoryProvider).send(d);
      ref.read(noticeProvider.notifier).show('Sent to ${d.to.first}');
      _close();
    } catch (e) {
      setState(() {
        _sending = false;
        _error = e.toString().replaceFirst(RegExp(r'^\w+: '), '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final d = widget.draft;
    final title = switch (d.kind) {
      DraftKind.reply => 'Reply',
      DraftKind.forward => 'Forward',
      DraftKind.fresh => 'New message',
    };
    final pad = widget.compact ? 16.0 : 44.0;
    return Focus(
      onKeyEvent: (node, e) {
        if (e is! KeyDownEvent) return KeyEventResult.ignored;
        final mod =
            HardwareKeyboard.instance.isMetaPressed ||
            HardwareKeyboard.instance.isControlPressed;
        if (mod &&
            (e.logicalKey == LogicalKeyboardKey.enter ||
                e.logicalKey == LogicalKeyboardKey.numpadEnter)) {
          send();
          return KeyEventResult.handled;
        }
        if (mod &&
            HardwareKeyboard.instance.isShiftPressed &&
            e.logicalKey == LogicalKeyboardKey.keyA) {
          _attach();
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.escape) {
          _close();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: s.border)),
            ),
            child: Row(
              children: [
                Text(title, style: ui(context, weight: FontWeight.w500)),
                const SizedBox(width: 10),
                Text(
                  'from ${d.from}',
                  style: mono(context, size: 11, color: s.fg3),
                ),
                const Spacer(),
                IconBtn(
                  icon: CupertinoIcons.xmark,
                  label: 'Discard  esc',
                  onTap: _close,
                ),
              ],
            ),
          ),
          Expanded(
            child: Appear(
              child: ListView(
                padding: EdgeInsets.fromLTRB(pad, 18, pad, 0),
                children: [
                  _HeaderField(
                    label: 'to',
                    controller: _to,
                    focusNode: _toFocus,
                    hint: 'name@example.com, …',
                    trailing: _showCc
                        ? null
                        : _link('cc', () => setState(() => _showCc = true)),
                  ),
                  if (_showCc)
                    _HeaderField(label: 'cc', controller: _cc, hint: ''),
                  _HeaderField(
                    label: 'subject',
                    controller: _subject,
                    hint: 'Subject',
                  ),
                  const SizedBox(height: 14),
                  Material(
                    type: MaterialType.transparency,
                    child: TextField(
                      controller: _body,
                      focusNode: _bodyFocus,
                      maxLines: null,
                      minLines: 12,
                      keyboardType: TextInputType.multiline,
                      style: ui(context, size: 14, height: 1.6),
                      cursorColor: s.fg,
                      cursorWidth: 1.5,
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                        hintText: 'Write…',
                        hintStyle: ui(context, size: 14, color: s.fg3),
                      ),
                    ),
                  ),
                  if (_files.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final f in _files)
                          Appear(
                            key: ObjectKey(f),
                            child: DraftFileChip(
                              file: f,
                              onRemove: () => setState(
                                () => _files = [..._files]..remove(f),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _encodedSize > _serverLimit
                          ? '≈ ${formatBytes(_encodedSize)} encoded · most servers refuse mail over 25 MB'
                          : '${_files.length} ${_files.length == 1 ? 'file' : 'files'} · ${formatBytes(_files.fold(0, (s, f) => s + f.size))}',
                      style: mono(
                        context,
                        size: 11,
                        color: _encodedSize > _serverLimit
                            ? context.s.red
                            : context.s.fg3,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
          Container(
            padding: EdgeInsets.fromLTRB(pad, 10, pad, 12),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: s.border)),
            ),
            child: Row(
              children: [
                IconBtn(
                  icon: CupertinoIcons.paperclip,
                  label: 'Attach files  ⌘⇧A',
                  onTap: _attach,
                ),
                const SizedBox(width: 8),
                if (_error != null)
                  Expanded(
                    child: Text(
                      _error!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono(context, size: 11, color: s.red),
                    ),
                  )
                else
                  const Spacer(),
                SmallButton(
                  label: 'Discard',
                  hint: 'esc',
                  height: 30,
                  onPressed: _close,
                ),
                const SizedBox(width: 8),
                SmallButton(
                  label: _sending ? 'Sending…' : 'Send',
                  hint: '⌘↵',
                  primary: true,
                  height: 30,
                  onPressed: _sending ? null : send,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _link(String text, VoidCallback onTap) => HoverRegion(
    onTap: onTap,
    builder: (context, hovered) => Text(
      text,
      style: mono(
        context,
        size: 11,
        color: hovered ? context.s.fg : context.s.fg3,
      ),
    ),
  );
}

class _HeaderField extends StatelessWidget {
  const _HeaderField({
    required this.label,
    required this.controller,
    required this.hint,
    this.focusNode,
    this.trailing,
  });
  final String label;
  final TextEditingController controller;
  final String hint;
  final FocusNode? focusNode;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Container(
      height: 34,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: s.border)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: Text(label, style: mono(context, size: 12, color: s.fg3)),
          ),
          Expanded(
            child: Material(
              type: MaterialType.transparency,
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                style: ui(context),
                cursorColor: s.fg,
                cursorWidth: 1.5,
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: hint,
                  hintStyle: ui(context, color: s.fg3),
                ),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
