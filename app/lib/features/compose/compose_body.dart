import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/repository.dart';
import '../../platform.dart';
import '../attachments/attachment_chip.dart';
import '../../state/providers.dart';
import '../../theme/app_icons.dart';
import '../../theme/motion.dart';
import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';

/// Composer in the reading pane: mono-labelled header fields, plain body, send row.
/// With [phone], a phone's whole screen: Close, the title and Send on top, fields sized
/// for fingers, and a bar of Attach and Discard over the keyboard.
class ComposeBody extends ConsumerStatefulWidget {
  const ComposeBody({
    super.key,
    required this.draft,
    this.compact = false,
    this.phone = false,
  });
  final Draft draft;
  final bool compact;
  final bool phone;

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
  final _ccFocus = FocusNode(debugLabel: 'compose-cc');
  final _subjectFocus = FocusNode(debugLabel: 'compose-subject');
  late var _files = [...widget.draft.attachments];
  bool _showCc = false;

  /// Cc was asked for with its button (rather than opening with the draft): it slides in.
  bool _ccAdded = false;
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
  bool _closing = false;

  /// Typed into since the last save: the phone's "Saved" waits for the next one.
  bool _pending = false;

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
    _ccFocus.dispose();
    _subjectFocus.dispose();
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
      if (_pending && mounted) setState(() => _pending = false);
      return _saving;
    }
    _lastSaved = fp;
    return _saving = _saving.then((_) async {
      try {
        _localId = await _repo.saveDraft(d.copyWith(localId: _localId));
        if (!mounted) return;
        setState(() {
          _savedAt = DateTime.now();
          _pending = _fingerprint(_current) != _lastSaved;
        });
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

  /// Esc and ×: close and keep the draft (unless nothing was typed). On a phone, Close and
  /// the system's back both come here.
  Future<void> _close() async {
    if (_done || _closing) return;
    _closing = true;
    try {
      await _closeNow();
    } finally {
      _closing = false;
    }
  }

  Future<void> _closeNow() async {
    final notice = ref.read(
      noticeProvider.notifier,
    ); // the page may be gone by then
    if (_untouched) {
      await _saving;
      // A draft created in this session and then typed back to the template is noise.
      if (widget.draft.localId == null && _localId != null) {
        await _repo.deleteDraft(_localId!);
      }
    } else {
      await _saveNow();
      if (_lastSaved == null) return; // save failed: the error stays visible
      notice.show('Draft saved');
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

  /// The phone's Discard: ask first, since it cannot be undone. If the stored draft
  /// cannot be deleted, the page stays and says so; Close and Send work again.
  Future<void> _confirmDiscard() async {
    final yes = await confirmDialog(
      context,
      title: 'Discard this draft?',
      body: 'It won’t be kept in Drafts.',
      action: 'Discard',
      danger: true,
    );
    if (!yes || !mounted) return;
    try {
      await _discard();
    } catch (e) {
      _done = false;
      if (!mounted) return;
      setState(() => _error = 'Draft not discarded: ${_reason(e)}');
    }
  }

  /// Something typed on the phone: the error line goes, and "Saved" hides until the
  /// next save.
  void _edited() {
    if (_error == null && _pending) return;
    setState(() {
      _error = null;
      _pending = true;
    });
  }

  void _removeFile(DraftAttachment f) {
    setState(() => _files = [..._files]..remove(f));
    _edited();
    _scheduleSave();
  }

  void _addCc() {
    setState(() {
      _showCc = true;
      _ccAdded = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ccFocus.requestFocus();
    });
  }

  /// Send waits for a recipient that looks like an address.
  bool get _hasAddress => _split(_to.text).any((a) => a.contains('@'));

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
    final notice = ref.read(noticeProvider.notifier);
    final String? warning;
    try {
      warning = await _repo.send(d);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        // An unrecognised failure keeps the server's own words.
        _error = switch (e) {
          Problem(hint: null, detail: final d) when d.isNotEmpty =>
            '${e.title}: ${d.split('\n').first}',
          Problem() => '$e',
          _ => _reason(e),
        };
      });
      return;
    }
    // Sent. Nothing from here on may read as a failed send: that invites a second one.
    _done = true;
    try {
      await _saving;
      if (_localId != null) await _repo.deleteDraft(_localId!);
    } catch (_) {
      // The draft stays in Drafts; the mail went out regardless.
    }
    notice.show(
      warning ?? 'Sent to ${d.to.first}',
      ttl: warning == null
          ? const Duration(milliseconds: 2500)
          : const Duration(seconds: 8),
    );
    if (mounted) _leave();
  }

  /// ⌘↵ sends, ⌘⇧A attaches, Esc closes (a hardware keyboard, phones included).
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
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
    if (widget.phone) {
      return Focus(onKeyEvent: _onKey, child: _phoneLayout(context, title));
    }
    final pad = widget.compact ? 16.0 : 44.0;
    final body = Focus(
      onKeyEvent: _onKey,
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
                  label: 'Attach files  ${modKey('A', shift: true)}',
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
                  hint: kTouch ? null : modKey('↵'),
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

  /// The phone's screen. Back (Android's button or gesture) closes it the way Close does:
  /// the draft is kept, and the page goes once it is. While the mail is on its way, both
  /// wait: leaving then would hide whether it went.
  Widget _phoneLayout(BuildContext context, String title) {
    final s = context.s;
    final ios = defaultTargetPlatform == TargetPlatform.iOS;
    final ink = s.isDark ? Brightness.light : Brightness.dark;
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final saved = _savedAt != null && !_pending;
    final header = MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: AppBar(
        backgroundColor: s.bg,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        toolbarHeight: Touch.appBar,
        automaticallyImplyLeading: false,
        centerTitle: ios,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: ink,
          statusBarBrightness: s.brightness,
          systemNavigationBarColor: s.bg2,
          systemNavigationBarIconBrightness: ink,
        ),
        shape: Border(bottom: BorderSide(color: s.border)),
        leading: IconButton(
          tooltip: 'Close',
          color: s.fg,
          disabledColor: s.fg3,
          icon: Icon(AppIcons.close, size: 24),
          onPressed: _sending ? null : _close,
        ),
        title: Semantics(
          header: true,
          child: Text(
            title,
            style: ui(context, size: 17, weight: FontWeight.w600, height: 1.3),
          ),
        ),
        actions: [
          // Only the button follows what is typed in To.
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _to,
            builder: (context, _, _) => FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size(64, 36),
                tapTargetSize: MaterialTapTargetSize.padded,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                textStyle: ui(context, size: 15, weight: FontWeight.w600),
              ),
              onPressed: _sending || !_hasAddress ? null : send,
              child: Text(_sending ? 'Sending…' : 'Send'),
            ),
          ),
          const SizedBox(width: Touch.gutter),
        ],
      ),
    );
    // Keyed: rows come and go above the fields (From once accounts load, Cc), and a
    // field must keep its state, or the keyboard loses it.
    final fields = [
      if (accounts.length > 1)
        _PhoneRow(
          key: const ValueKey('from'),
          label: 'From',
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              widget.draft.from,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ui(context, size: 16, color: s.fg2),
            ),
          ),
        ),
      _PhoneRow(
        key: const ValueKey('to'),
        label: 'To',
        trailing: _showCc
            ? null
            : TextButton(
                style: TextButton.styleFrom(
                  textStyle: ui(context, size: 15, weight: FontWeight.w500),
                ),
                onPressed: _addCc,
                child: const Text('Cc'),
              ),
        child: _phoneInput(
          _to,
          _toFocus,
          address: true,
          next: _showCc ? _ccFocus : _subjectFocus,
        ),
      ),
      if (_showCc)
        _SizeIn(
          key: const ValueKey('cc'),
          animate: _ccAdded,
          child: _PhoneRow(
            label: 'Cc',
            child: _phoneInput(
              _cc,
              _ccFocus,
              address: true,
              next: _subjectFocus,
            ),
          ),
        ),
      _PhoneRow(
        key: const ValueKey('subject'),
        label: 'Subject',
        child: _phoneInput(_subject, _subjectFocus, next: _bodyFocus),
      ),
      for (final f in _files)
        _PhoneFile(key: ObjectKey(f), file: f, onRemove: () => _removeFile(f)),
      if (_encodedSize > _serverLimit)
        Padding(
          key: const ValueKey('too-large'),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Text(
            'About ${formatBytes(_encodedSize)} once encoded: most servers refuse mail over 25 MB.',
            style: ui(context, size: 13, color: s.red),
          ),
        ),
    ];
    final bodyField = TextField(
      controller: _body,
      focusNode: _bodyFocus,
      maxLines: null,
      keyboardType: TextInputType.multiline,
      textCapitalization: TextCapitalization.sentences,
      onChanged: (_) => _edited(),
      style: ui(context, size: 16, height: 1.55),
      cursorColor: s.accentStrong,
      decoration: const InputDecoration(
        isDense: true,
        border: InputBorder.none,
        contentPadding: EdgeInsets.zero,
      ),
    );
    // One line just above the bar, until the next edit.
    final error = AnimatedSize(
      duration: Motion.of(context, Motion.base),
      curve: Motion.curve,
      alignment: Alignment.bottomCenter,
      child: _error == null
          ? const SizedBox(width: double.infinity)
          : SafeArea(
              top: false,
              bottom: false,
              child: Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Row(
                    children: [
                      Icon(AppIcons.error, size: 18, color: s.red),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ui(context, size: 14, color: s.red),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
    final bar = DecoratedBox(
      decoration: BoxDecoration(
        color: s.bg2,
        border: Border(top: BorderSide(color: s.border)),
      ),
      child: SafeArea(
        top: false,
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.3,
          child: SizedBox(
            height: Touch.target,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Attach files',
                    color: s.fg2,
                    icon: Icon(AppIcons.attach, size: 24),
                    onPressed: _attach,
                  ),
                  const SizedBox(width: 4),
                  AnimatedOpacity(
                    opacity: saved ? 1 : 0,
                    duration: Motion.of(context, Motion.base),
                    curve: Motion.curve,
                    child: Text(
                      'Saved',
                      style: ui(context, size: 13, color: s.fg2),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Discard draft',
                    color: s.fg2,
                    disabledColor: s.fg3,
                    icon: Icon(AppIcons.delete, size: 24),
                    onPressed: _sending ? null : _confirmDiscard,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_sending) _close();
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Expanded(
            child: SafeArea(
              top: false,
              bottom: false,
              child: Material(
                type: MaterialType.transparency,
                child: CustomScrollView(
                  slivers: [
                    SliverList.list(children: fields),
                    // The body takes the rest of the page; a tap below the text
                    // still lands in it.
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _bodyFocus.requestFocus,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: bodyField,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          error,
          bar,
        ],
      ),
    );
  }

  /// A header field on the phone: reading type, the keyboard for what it holds, and
  /// Next to the field after it.
  Widget _phoneInput(
    TextEditingController controller,
    FocusNode focusNode, {
    required FocusNode next,
    bool address = false,
  }) {
    final s = context.s;
    return TextField(
      controller: controller,
      focusNode: focusNode,
      keyboardType: address ? TextInputType.emailAddress : TextInputType.text,
      textInputAction: TextInputAction.next,
      textCapitalization: address
          ? TextCapitalization.none
          : TextCapitalization.sentences,
      autocorrect: !address,
      enableSuggestions: !address,
      onChanged: (_) => _edited(),
      onEditingComplete: next.requestFocus,
      style: ui(context, size: 16),
      cursorColor: s.accentStrong,
      decoration: const InputDecoration(
        isDense: true,
        border: InputBorder.none,
        contentPadding: EdgeInsets.symmetric(vertical: 12),
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

/// A header row on the phone: its name in a 64 column, then the field, over a hairline
/// that starts at the margin. The column grows with large text, so a name never breaks
/// in the middle.
class _PhoneRow extends StatelessWidget {
  const _PhoneRow({
    super.key,
    required this.label,
    required this.child,
    this.trailing,
  });
  final String label;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final scale = MediaQuery.textScalerOf(context).scale(15) / 15;
    return Padding(
      padding: const EdgeInsets.only(left: Touch.gutter),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: s.border)),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Touch.row),
          child: Padding(
            padding: EdgeInsets.only(
              right: trailing == null ? Touch.gutter : 4,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 64 * scale,
                  child: Text(
                    label,
                    style: ui(context, size: 15, color: s.fg2),
                  ),
                ),
                Expanded(child: child),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A file going with the message: its kind, name and size, and a way to take it off.
class _PhoneFile extends StatelessWidget {
  const _PhoneFile({super.key, required this.file, required this.onRemove});
  final DraftAttachment file;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Padding(
      padding: const EdgeInsets.only(left: Touch.gutter),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: s.border)),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Row(
            children: [
              Icon(iconForFile(file.mime, file.name), size: 20, color: s.fg2),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ui(context, size: 15, height: 1.3),
                    ),
                    Text(
                      formatBytes(file.size),
                      style: mono(context, size: 12.5, color: s.fg2),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Remove ${file.name}',
                icon: Icon(AppIcons.close, size: 20, color: s.fg2),
                onPressed: onRemove,
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens its child downwards from nothing when it first appears, if [animate]; otherwise
/// it is simply there.
class _SizeIn extends StatefulWidget {
  const _SizeIn({super.key, required this.animate, required this.child});
  final bool animate;
  final Widget child;

  @override
  State<_SizeIn> createState() => _SizeInState();
}

class _SizeInState extends State<_SizeIn> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    value: widget.animate ? 0 : 1,
  );
  late final _size = CurvedAnimation(parent: _c, curve: Motion.curve);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _c.duration = Motion.of(context, Motion.base);
    if (_c.isDismissed) _c.forward();
  }

  @override
  void dispose() {
    _size.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizeTransition(
    sizeFactor: _size,
    alignment: Alignment.topCenter,
    child: widget.child,
  );
}
