import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/repository.dart';
import '../../platform.dart';
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
  bool _dragging = false;
  String? _error;

  // Autosave: every pause in typing stores the draft on this device.
  late final MailRepository _repo; // read in initState: dispose may not use ref
  late int? _localId = widget.draft.localId;
  late final String _initial = _fingerprint(_current);
  String? _lastSaved;
  DateTime? _savedAt;
  Timer? _saveTimer;
  Future<void> _saving = Future.value();
  bool _done = false;

  /// Most servers (Gmail, Outlook, iCloud) refuse messages over 25 MB after base64.
  static const _serverLimit = 25 * 1024 * 1024;
  int get _encodedSize =>
      (_files.fold<int>(0, (sum, f) => sum + f.size) * 4 / 3).ceil();

  @override
  void initState() {
    super.initState();
    _repo = ref.read(repositoryProvider);
    _showCc = widget.draft.cc.isNotEmpty;
    _lastSaved = _initial;
    for (final c in [_to, _cc, _subject, _body]) {
      c.addListener(_scheduleSave);
    }
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
    _saveTimer?.cancel();
    // Closed some other way (another draft opened, window closing): keep what was typed.
    if (!_done && _fingerprint(_current) != _lastSaved && !_untouched) {
      _repo.saveDraft(_current.copyWith(localId: _localId));
    }
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

  static String _fingerprint(Draft d) => [
    d.to.join(','),
    d.cc.join(','),
    d.subject,
    d.text,
    for (final a in d.attachments)
      '${a.name}|${a.path}|${a.messageId}|${a.idx}',
  ].join('\u0000');

  /// Still exactly what the composer opened with (a fresh reply nobody typed into).
  bool get _untouched => _fingerprint(_current) == _initial;

  void _scheduleSave() {
    if (_done) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 700), _saveNow);
  }

  /// Store the draft unless it is unchanged since the last save, or an untouched
  /// template that was never stored. Saves run one after another.
  Future<void> _saveNow() {
    _saveTimer?.cancel();
    if (_done) return _saving;
    final d = _current;
    final fp = _fingerprint(d);
    if (fp == _lastSaved || (fp == _initial && _localId == null)) {
      return _saving;
    }
    _lastSaved = fp;
    return _saving = _saving.then((_) async {
      try {
        _localId = await _repo.saveDraft(d.copyWith(localId: _localId));
        if (!mounted) return;
        setState(() => _savedAt = DateTime.now());
        ref.invalidate(draftsProvider);
      } catch (e) {
        _lastSaved = null; // try again on the next change
        if (mounted) setState(() => _error = 'Draft not saved: ${_reason(e)}');
      }
    });
  }

  Future<void> _attach() async {
    if (_picking) return;
    _picking = true;
    try {
      final picked = await openFiles();
      await _addPaths([for (final x in picked) x.path]);
    } catch (e) {
      if (mounted) setState(() => _error = _reason(e));
    } finally {
      _picking = false;
    }
  }

  static String _reason(Object e) =>
      e.toString().replaceFirst(RegExp(r'^\w+: '), '');

  /// Describe each file and add it; the first failure (a folder, a vanished file) is
  /// shown in the send row, the rest still attach.
  Future<void> _addPaths(List<String> paths) async {
    if (paths.isEmpty) return;
    final repo = ref.read(repositoryProvider);
    final added = <DraftAttachment>[];
    String? failed;
    for (final p in paths) {
      try {
        added.add(await repo.describeFile(p));
      } catch (e) {
        failed ??= _reason(e);
      }
    }
    if (!mounted) return;
    setState(() {
      _files = [..._files, ...added];
      _error = failed;
    });
    _scheduleSave();
  }

  void _dropped(DropDoneDetails d) {
    setState(() => _dragging = false);
    final folders = d.files.whereType<DropItemDirectory>().length;
    _addPaths([
      for (final f in d.files)
        if (f is! DropItemDirectory) f.path,
    ]).then((_) {
      if (folders > 0 && mounted) {
        setState(() => _error = 'Folders can’t be attached; zip them first.');
      }
    });
  }

  static List<String> _split(String s) => s
      .split(RegExp(r'[,;]'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  void _leave() {
    _done = true;
    _saveTimer?.cancel();
    ref.invalidate(draftsProvider);
    ref.read(scopeProvider.notifier).set('list');
    ref.read(composeProvider.notifier).close();
  }

  /// Esc and ×: close and keep the draft (unless nothing was typed).
  Future<void> _close() async {
    if (_done) return;
    if (_untouched) {
      await _saving;
      // A draft created in this session and then typed back to the template is noise.
      if (widget.draft.localId == null && _localId != null) {
        await _repo.deleteDraft(_localId!);
      }
    } else {
      await _saveNow();
      if (_lastSaved == null) return; // save failed: the error stays visible
      ref.read(noticeProvider.notifier).show('Draft saved');
    }
    if (mounted) _leave();
  }

  /// The Discard button: close and delete the stored draft.
  Future<void> _discard() async {
    if (_done) return;
    _done = true;
    _saveTimer?.cancel();
    await _saving;
    if (_localId != null) await _repo.deleteDraft(_localId!);
    if (!mounted) return;
    if (_localId != null) {
      ref.read(noticeProvider.notifier).show('Draft discarded');
    }
    _leave();
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
    _saveTimer?.cancel();
    try {
      await _repo.send(d);
      _done = true;
      await _saving;
      if (_localId != null) await _repo.deleteDraft(_localId!);
      if (!mounted) return;
      ref.read(noticeProvider.notifier).show('Sent to ${d.to.first}');
      _leave();
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
    final body = Focus(
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
                Expanded(
                  child: Text(
                    'from ${d.from}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: mono(context, size: 11, color: s.fg3),
                  ),
                ),
                AnimatedSwitcher(
                  duration: Motion.of(context, Motion.base),
                  child: _savedAt == null
                      ? const SizedBox.shrink()
                      : Padding(
                          key: ValueKey(_savedAt),
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            'saved ${formatWhen(_savedAt!)}',
                            style: mono(context, size: 11, color: s.fg3),
                          ),
                        ),
                ),
                IconBtn(
                  icon: CupertinoIcons.xmark,
                  label: kTouch ? 'Close' : 'Close, keep draft  esc',
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
                SmallButton(label: 'Discard', height: 30, onPressed: _discard),
                const SizedBox(width: 8),
                SmallButton(
                  label: _sending ? 'Sending…' : 'Send',
                  hint: kTouch ? null : '⌘↵',
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
    if (kTouch) return body;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: _dropped,
      child: Stack(
        children: [
          body,
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _dragging ? 1 : 0,
                duration: Motion.of(context, Motion.fast),
                curve: Motion.curve,
                child: const _DropHint(),
              ),
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

/// Shown over the composer while files are dragged in from the desktop.
class _DropHint extends StatelessWidget {
  const _DropHint();

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Container(
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: s.blue.withValues(alpha: 0.07),
        border: Border.all(color: s.blue.withValues(alpha: 0.7)),
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(CupertinoIcons.paperclip, size: 20, color: s.blue),
          const SizedBox(height: 8),
          Text('Drop to attach', style: mono(context, size: 12, color: s.blue)),
        ],
      ),
    );
  }
}
