import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../platform.dart';
import '../../state/appearance.dart';
import '../../state/providers.dart';
import '../../theme/motion.dart';
import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';
import '../accounts/add_account_sheet.dart';
import '../accounts/problem_note.dart';
import '../phone/phone_route.dart';
import 'phone_settings.dart';

/// Settings over the app: accounts (name, signature, remove), key preset, appearance.
/// Like the add-account sheet, the dialog key scope is set around it rather than inside it.
/// A phone gets a screen of its own, pushed like any other.
Future<void> showSettingsSheet(BuildContext context) async {
  if (isPhone(context)) {
    await Navigator.of(context)
        .push(phonePage<void>((_) => const PhoneSettingsScreen()));
    return;
  }
  final scope = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(scopeProvider.notifier);
  scope.set('dialog');
  try {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.black.withValues(alpha: 0.25),
      transitionDuration: const Duration(milliseconds: 120),
      pageBuilder: (_, _, _) => const Center(
        child: Appear(duration: Motion.fast, dy: 8, child: SettingsSheet()),
      ),
    );
  } finally {
    scope.set('list');
  }
}

class SettingsSheet extends ConsumerWidget {
  const SettingsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final size = MediaQuery.sizeOf(context);
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: (size.width - 32).clamp(280.0, 600.0),
        constraints: BoxConstraints(maxHeight: size.height * 0.86),
        decoration: BoxDecoration(
          color: s.bg2,
          border: Border.all(color: s.border),
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [
            BoxShadow(
              color: Color(0x40000000),
              blurRadius: 30,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 40,
              padding: const EdgeInsets.only(left: 16, right: 8),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: s.border)),
              ),
              child: Row(
                children: [
                  Text('Settings', style: ui(context, weight: FontWeight.w500)),
                  const Spacer(),
                  if (!kTouch) ...[
                    const KeyHint('esc'),
                    const SizedBox(width: 6),
                  ],
                  IconBtn(
                    icon: CupertinoIcons.xmark,
                    label: 'Close',
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                children: [
                  const SectionLabel('Accounts', padding: _labelPad),
                  if (accounts.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'No accounts yet.',
                        style: ui(context, color: s.fg3),
                      ),
                    ),
                  for (final a in accounts)
                    _AccountEditor(
                      key: ValueKey('account-${a.id}'),
                      account: a,
                    ),
                  HoverRegion(
                    onTap: () {
                      Navigator.of(context).pop();
                      showAddAccountSheet(context);
                    },
                    builder: (context, hovered) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        '+ Add account',
                        style: ui(
                          context,
                          size: 12.5,
                          color: hovered ? s.fg : s.fg2,
                        ),
                      ),
                    ),
                  ),
                  const SectionLabel('Keys', padding: _labelPad),
                  const _KeysPicker(),
                  const SectionLabel('Appearance', padding: _labelPad),
                  const _ThemePicker(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const _labelPad = EdgeInsets.fromLTRB(0, 16, 0, 8);

/// Name and signature of one account, saved on demand; removal takes a second click.
class _AccountEditor extends ConsumerStatefulWidget {
  const _AccountEditor({super.key, required this.account});
  final Account account;

  @override
  ConsumerState<_AccountEditor> createState() => _AccountEditorState();
}

class _AccountEditorState extends ConsumerState<_AccountEditor> {
  late final _name = TextEditingController(text: widget.account.displayName);
  late final _signature = TextEditingController(text: widget.account.signature);
  final _password = TextEditingController();
  bool _saving = false;

  /// The password row is open: always while the server refuses the stored one.
  bool _passwordOpen = false;
  bool _checking = false;
  Problem? _passwordProblem;
  bool _confirmRemove = false;
  Timer? _confirmTimer;

  @override
  void initState() {
    super.initState();
    _name.addListener(_changed);
    _signature.addListener(_changed);
  }

  @override
  void dispose() {
    _confirmTimer?.cancel();
    _name.dispose();
    _signature.dispose();
    _password.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  bool get _dirty =>
      _name.text.trim() != widget.account.displayName ||
      _signature.text != widget.account.signature;

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref
          .read(repositoryProvider)
          .updateAccount(
            widget.account.id,
            displayName: _name.text.trim(),
            signature: _signature.text,
          );
      ref.read(noticeProvider.notifier).show('Saved ${widget.account.email}');
    } catch (e) {
      ref.read(noticeProvider.notifier).show('$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _savePassword() async {
    if (_password.text.isEmpty || _checking) return;
    setState(() {
      _checking = true;
      _passwordProblem = null;
    });
    final email = widget.account.email;
    final notice = ref.read(noticeProvider.notifier);
    try {
      await ref
          .read(repositoryProvider)
          .updatePassword(widget.account.id, _password.text);
      notice.show('Signed in to $email');
      if (!mounted) return;
      _password.clear();
      setState(() => _passwordOpen = false);
    } on Problem catch (p) {
      if (mounted) setState(() => _passwordProblem = p);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _retry() async {
    setState(() {
      _checking = true;
      _passwordProblem = null;
    });
    try {
      await ref.read(repositoryProvider).retryAccount(widget.account.id);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Widget _passwordSection(BuildContext context) {
    final s = context.s;
    final a = widget.account;
    final problem = _passwordProblem ?? a.problem;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (problem != null) ...[
          const SizedBox(height: 8),
          ProblemNote(
            problem,
            key: ValueKey('${problem.title}${problem.detail}'),
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: QuietField(
                controller: _password,
                hint: a.needsPassword ? 'New app password' : 'New password',
                obscure: true,
                autofocus: !a.needsPassword,
                onSubmitted: (_) => _savePassword(),
              ),
            ),
            const SizedBox(width: 8),
            SmallButton(
              label: _checking ? 'Signing in…' : 'Sign in',
              primary: true,
              onPressed: _checking ? null : _savePassword,
            ),
          ],
        ),
        if (a.needsPassword)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Syncing is paused so the server does not lock the mailbox after repeated refusals.',
                    style: ui(context, size: 11.5, color: s.fg3),
                  ),
                ),
                const SizedBox(width: 8),
                SmallButton(
                  label: 'Try again',
                  onPressed: _checking ? null : _retry,
                ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _remove() async {
    if (!_confirmRemove) {
      setState(() => _confirmRemove = true);
      _confirmTimer?.cancel();
      _confirmTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _confirmRemove = false);
      });
      return;
    }
    _confirmTimer?.cancel();
    final email = widget.account.email;
    final notice = ref.read(noticeProvider.notifier);
    try {
      await ref.read(repositoryProvider).removeAccount(widget.account.id);
      notice.show('Removed $email');
    } catch (e) {
      // Nothing irreversible happened (cached files go first); it can be retried.
      notice.show(
        'Could not remove $email: ${e.toString().replaceFirst(RegExp(r'^\w+: '), '')}',
      );
      if (mounted) setState(() => _confirmRemove = false);
    }
    ref.invalidate(accountsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final a = widget.account;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: s.bg,
        border: Border.all(color: s.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Dot(color: a.color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  a.email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui(context, weight: FontWeight.w500),
                ),
              ),
              if (a.needsPassword)
                Text(
                  'needs password',
                  style: mono(context, size: 11, color: s.red),
                ),
            ],
          ),
          if (a.imap != null || a.server.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 16),
              child: Text(
                [
                  'IMAP ${a.imap ?? a.server}',
                  if (a.smtp != null) 'SMTP ${a.smtp}',
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: mono(context, size: 11, color: s.fg3),
              ),
            ),
          AnimatedSize(
            duration: Motion.of(context, Motion.fast),
            curve: Motion.curve,
            alignment: Alignment.topLeft,
            child: a.needsPassword || _passwordOpen
                ? _passwordSection(context)
                : const SizedBox(width: double.infinity),
          ),
          const SizedBox(height: 8),
          _Field(label: 'name', controller: _name, hint: 'Shown in From'),
          _Field(
            label: 'signature',
            controller: _signature,
            hint: 'Added under “-- ” in new messages',
            lines: 2,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              AnimatedSwitcher(
                duration: Motion.of(context, Motion.fast),
                child: _confirmRemove
                    ? SmallButton(
                        key: const ValueKey('confirm'),
                        label: 'Remove account and its mail here',
                        danger: true,
                        onPressed: _remove,
                      )
                    : SmallButton(
                        key: const ValueKey('remove'),
                        label: 'Remove…',
                        onPressed: _remove,
                      ),
              ),
              if (!a.needsPassword && !_confirmRemove) ...[
                const SizedBox(width: 8),
                SmallButton(
                  label: _passwordOpen ? 'Keep password' : 'Password…',
                  onPressed: () => setState(() {
                    _passwordOpen = !_passwordOpen;
                    _passwordProblem = null;
                    _password.clear();
                  }),
                ),
              ],
              const Spacer(),
              AnimatedOpacity(
                opacity: _dirty ? 1 : 0,
                duration: Motion.of(context, Motion.fast),
                child: SmallButton(
                  label: _saving ? 'Saving…' : 'Save',
                  primary: true,
                  onPressed: _dirty && !_saving ? _save : null,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Mono label column + borderless input, like the composer's header fields.
class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    required this.hint,
    this.lines = 1,
  });
  final String label;
  final TextEditingController controller;
  final String hint;
  final int lines;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: s.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(label, style: mono(context, size: 12, color: s.fg3)),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              minLines: lines,
              maxLines: lines == 1 ? 1 : 8,
              style: lines == 1 ? ui(context) : ui(context, height: 1.45),
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
        ],
      ),
    );
  }
}

class _KeysPicker extends ConsumerWidget {
  const _KeysPicker();

  static const _sample = [
    ('nav.next', 'next'),
    ('thread.archive', 'archive'),
    ('thread.delete', 'delete'),
    ('thread.reply', 'reply'),
    ('search.focus', 'search'),
    ('palette.open', 'commands'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final keymap = ref.watch(keymapProvider).value;
    final current = keymap?.name ?? 'vim';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Segmented<String>(
          options: [for (final p in keymapPresets) (p, p)],
          value: current,
          onChanged: (p) async {
            await ref.read(repositoryProvider).setSetting('keymap', p);
            ref.invalidate(keymapProvider);
          },
        ),
        if (keymap != null) ...[
          const SizedBox(height: 8),
          AnimatedSwitcher(
            duration: Motion.of(context, Motion.base),
            child: Text(
              [
                for (final (action, what) in _sample)
                  if (keymap.hint(action, mac: isMac) case final hint?)
                    '$what $hint',
              ].join(' · '),
              key: ValueKey(keymap.name),
              style: mono(context, size: 11, color: s.fg3),
            ),
          ),
        ],
      ],
    );
  }
}

class _ThemePicker extends ConsumerWidget {
  const _ThemePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Segmented<ThemeMode>(
      options: const [
        (ThemeMode.dark, 'dark'),
        (ThemeMode.light, 'light'),
        (ThemeMode.system, 'system'),
      ],
      value: ref.watch(appearanceProvider),
      onChanged: (m) => ref.read(appearanceProvider.notifier).set(m),
    );
  }
}
