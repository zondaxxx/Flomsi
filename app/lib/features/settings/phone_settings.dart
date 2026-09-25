import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/repository.dart';
import '../../state/appearance.dart';
import '../../state/providers.dart';
import '../../theme/app_icons.dart';
import '../../theme/motion.dart';
import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';
import '../accounts/problem_note.dart';
import '../accounts/sign_in_again.dart';
import '../onboarding/account_setup_screen.dart';
import '../phone/phone_route.dart';
import '../sidebar/sidebar_model.dart';

/// The version the About section shows. Keep it in step with `version:` in pubspec.yaml
/// (the app does not read its own package info).
const appVersion = '0.2.4';
const appBuild = 6;

/// Settings on a phone, as a screen of its own: the accounts, the theme, and what this
/// build is. Key presets are for keyboards, so they are not here.
class PhoneSettingsScreen extends ConsumerWidget {
  const PhoneSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    return Scaffold(
      backgroundColor: s.bg,
      appBar: _bar(context, 'Settings'),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            const _Header('Accounts'),
            const Hairline(),
            for (final a in accounts) ...[
              _AccountRow(
                account: a,
                onTap: () => Navigator.of(
                  context,
                ).push(phonePage((_) => AccountDetailScreen(accountId: a.id))),
              ),
              const _Rule(),
            ],
            _Row(
              leading: Icon(
                AppIcons.addAccount,
                size: 20,
                color: s.accentStrong,
              ),
              title: 'Add account',
              onTap: () {
                // Held now: this screen has closed by the time the account is added.
                final query = ref.read(queryProvider.notifier);
                Navigator.of(context).push(
                  phonePage(
                    (_) => AccountSetupScreen(
                      // The new account's mail is among all of them.
                      onAdded: (_) =>
                          query.set(mailboxQuery(FolderRole.inbox, null)),
                    ),
                  ),
                );
              },
            ),
            const Hairline(),
            const _Header('Appearance'),
            const Hairline(),
            _Row(
              title: 'Theme',
              trailing: Segmented<ThemeMode>(
                options: const [
                  (ThemeMode.system, 'System'),
                  (ThemeMode.light, 'Light'),
                  (ThemeMode.dark, 'Dark'),
                ],
                value: ref.watch(appearanceProvider),
                onChanged: (m) => ref.read(appearanceProvider.notifier).set(m),
                height: 34,
              ),
            ),
            const Hairline(),
            const _Header('About'),
            const Hairline(),
            _Row(
              title: 'Version',
              trailing: Text(
                '$appVersion ($appBuild)',
                style: mono(context, size: 13, color: s.fg2),
              ),
            ),
            const _Rule(),
            _Row(
              title: 'Open-source licences',
              trailing: Icon(AppIcons.chevron, size: 18, color: s.fg3),
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'Flomsi',
                applicationVersion: '$appVersion ($appBuild)',
              ),
            ),
            const Hairline(),
          ],
        ),
      ),
    );
  }
}

/// A pushed screen's bar: the way back and a 17 semibold title, on the page's own colour
/// up under the status bar. Large system text is held at 1.3 here, as in the other bars.
AppBar _bar(BuildContext context, String? title) {
  final s = context.s;
  final ink = s.isDark ? Brightness.light : Brightness.dark;
  return AppBar(
    backgroundColor: s.bg,
    surfaceTintColor: Colors.transparent,
    scrolledUnderElevation: 0,
    elevation: 0,
    toolbarHeight: Touch.appBar,
    automaticallyImplyLeading: false,
    systemOverlayStyle: SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: ink,
      statusBarBrightness: s.brightness,
      systemNavigationBarColor: s.bg2,
      systemNavigationBarIconBrightness: ink,
    ),
    leading: IconButton(
      tooltip: 'Back',
      icon: Icon(AppIcons.back, color: s.fg),
      onPressed: () => Navigator.of(context).maybePop(),
    ),
    title: title == null
        ? null
        : MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.3,
            child: Text(
              title,
              style: ui(context, size: 17, weight: FontWeight.w600),
            ),
          ),
  );
}

/// How an account signs in, in a few words.
String _method(Account a) => switch (a.signInProvider) {
  'google' => 'Google sign-in',
  'microsoft' => 'Microsoft sign-in',
  _ => 'App password',
};

String _imapHost(Account a) => a.imap?.host ?? a.server.split(':').first;

/// The provider's name, told by its server rather than the address: custom domains on
/// iCloud+, Fastmail or Yandex 360 say nothing about who runs them.
String _provider(Account a) {
  if (a.localBridge) return 'Proton Mail Bridge';
  final host = _imapHost(a);
  return switch (host) {
    'imap.gmail.com' => 'Gmail',
    'imap.mail.me.com' => 'iCloud Mail',
    'outlook.office365.com' => 'Outlook',
    'imap.yandex.ru' || 'imap.yandex.com' => 'Yandex Mail',
    'imap.mail.ru' => 'Mail.ru',
    'imap.fastmail.com' => 'Fastmail',
    _ => switch (a.kind) {
      'gmail' => 'Gmail',
      'outlook' => 'Outlook',
      _ => host.isEmpty ? 'Mail server' : host,
    },
  };
}

/// A section's name: 13 semibold, sentence case, over its rows.
class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Touch.gutter, 24, Touch.gutter, 8),
    child: Semantics(
      header: true,
      child: Text(
        text,
        style: ui(
          context,
          size: 13,
          weight: FontWeight.w600,
          color: context.s.fg2,
        ),
      ),
    ),
  );
}

/// The hairline between two rows of a section, in line with their text.
class _Rule extends StatelessWidget {
  const _Rule();

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    thickness: 1,
    indent: Touch.gutter,
    color: context.s.border,
  );
}

/// A full-width row, at least 48 tall: an optional icon, the title, something at the end.
class _Row extends StatelessWidget {
  const _Row({
    required this.title,
    this.leading,
    this.trailing,
    this.onTap,
    this.color,
  });
  final String title;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: Touch.row),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Touch.gutter,
          vertical: 4,
        ),
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 16)],
            Expanded(
              child: trailing == null
                  ? Text(title, style: ui(context, size: 16, color: color))
                  // Large text: what is at the end moves under the title instead of
                  // off the screen.
                  : Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        Text(title, style: ui(context, size: 16, color: color)),
                        // Wider than the screen even on a line of its own (the theme
                        // choice at the largest text): drawn smaller, not cut.
                        FittedBox(fit: BoxFit.scaleDown, child: trailing),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
    if (onTap == null) return row;
    return Semantics(
      button: true,
      child: InkWell(onTap: onTap, child: row),
    );
  }
}

/// One account: its colour, address and how it signs in (or that it needs to).
class _AccountRow extends StatelessWidget {
  const _AccountRow({required this.account, required this.onTap});
  final Account account;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final a = account;
    final host = _imapHost(a);
    final subtitle = a.needsPassword
        ? 'Sign-in needed'
        : a.signInProvider != null || host.isEmpty
        ? _method(a)
        : '${_method(a)} · $host';
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Touch.gutter,
              vertical: 10,
            ),
            child: Row(
              children: [
                Dot(color: a.color, size: 10),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        a.email,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ui(context, size: 16, height: 1.35),
                      ),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ui(
                          context,
                          size: 13,
                          color: a.needsPassword ? s.red : s.fg2,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(AppIcons.chevron, size: 18, color: s.fg3),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One account on its own screen: who it is, the name and signature it sends with, how
/// it signs in, and removing it. The name and signature are kept on the way out.
class AccountDetailScreen extends ConsumerStatefulWidget {
  const AccountDetailScreen({
    super.key,
    required this.accountId,
    this.focusPassword = false,
  });
  final int accountId;

  /// Opened to type a new password ("Enter password" on a parked account): the password
  /// part starts open, with the keyboard up.
  final bool focusPassword;

  @override
  ConsumerState<AccountDetailScreen> createState() =>
      _AccountDetailScreenState();
}

class _AccountDetailScreenState extends ConsumerState<AccountDetailScreen> {
  final _name = TextEditingController();
  final _signature = TextEditingController();
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();

  /// The name and signature came from the account once; after that they are the
  /// person's edits.
  bool _filled = false;

  /// The account as last seen, so the screen keeps its content while it slides away
  /// after a removal.
  Account? _last;

  late bool _passwordOpen = widget.focusPassword;
  bool _checking = false;
  bool _signingIn = false;
  Problem? _passwordProblem;

  /// Removed from here, or being removed: nothing to save on the way out, and no
  /// second removal.
  bool _removed = false;

  Account? _find(List<Account>? accounts) =>
      accounts?.where((a) => a.id == widget.accountId).firstOrNull;

  @override
  void initState() {
    super.initState();
    _fill(_find(ref.read(accountsProvider).value));
    _password.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _signature.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  void _fill(Account? a) {
    if (_filled || a == null) return;
    _name.text = a.displayName;
    _signature.text = a.signature;
    _filled = true;
  }

  /// Leaving: the name and signature go to the account if they changed.
  void _saveOnLeave() {
    final a = _find(ref.read(accountsProvider).value);
    if (_removed || !_filled || a == null) return;
    final name = _name.text.trim();
    final signature = _signature.text;
    if (name == a.displayName && signature == a.signature) return;
    unawaited(
      _save(
        ref.read(repositoryProvider),
        ref.read(noticeProvider.notifier),
        a.id,
        name,
        signature,
      ),
    );
  }

  /// Runs after the screen is gone, so it holds on to nothing of it.
  static Future<void> _save(
    MailRepository repo,
    NoticeController notice,
    int id,
    String name,
    String signature,
  ) async {
    try {
      await repo.updateAccount(id, displayName: name, signature: signature);
      notice.show('Saved');
    } catch (e) {
      notice.show('Couldn’t save: $e', error: true);
    }
  }

  Future<void> _checkPassword(Account a) async {
    if (_password.text.isEmpty || _checking) return;
    setState(() {
      _checking = true;
      _passwordProblem = null;
    });
    final notice = ref.read(noticeProvider.notifier);
    try {
      await ref.read(repositoryProvider).updatePassword(a.id, _password.text);
      notice.show('Signed in to ${a.email}');
      if (!mounted) return;
      _password.clear();
      _passwordFocus.unfocus();
      setState(() => _passwordOpen = false);
    } on Problem catch (p) {
      if (mounted) setState(() => _passwordProblem = p);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _retry(Account a) async {
    setState(() {
      _checking = true;
      _passwordProblem = null;
    });
    try {
      await ref.read(repositoryProvider).retryAccount(a.id);
    } on Problem catch (p) {
      if (mounted) setState(() => _passwordProblem = p);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _signIn(Account a) async {
    setState(() => _signingIn = true);
    try {
      await signInAgain(context, ref, a);
    } finally {
      if (mounted) setState(() => _signingIn = false);
    }
  }

  void _togglePassword() {
    setState(() {
      _passwordOpen = !_passwordOpen;
      _passwordProblem = null;
      _password.clear();
    });
    if (_passwordOpen) {
      _passwordFocus.requestFocus();
    } else {
      _passwordFocus.unfocus();
    }
  }

  Future<void> _remove(Account a) async {
    // The row stays tappable while a removal runs.
    if (_removed) return;
    final sure = await confirmDialog(
      context,
      title: 'Remove ${a.email}?',
      body: 'Mail and drafts kept on this phone for this account are deleted. Nothing changes on the server.',
      action: 'Remove',
      danger: true,
    );
    if (!sure || !mounted) return;
    // All held now: the screen may be swiped away while the account goes.
    final nav = Navigator.of(context);
    final notice = ref.read(noticeProvider.notifier);
    final queries = ref.read(queryProvider.notifier);
    final accounts = ref.read(accountsProvider).value ?? const <Account>[];
    final last = accounts.every((b) => b.id == a.id);
    final base = withoutFilter(
      ref.read(queryProvider),
      ref.read(listFilterProvider),
    );
    final scoped = parseMailbox(base)?.scope == a.email;
    _removed = true;
    try {
      await ref.read(repositoryProvider).removeAccount(a.id);
    } catch (e) {
      // Nothing irreversible happened (cached files go first); it can be tried again.
      _removed = false;
      notice.show(
        'Couldn’t remove ${a.email}: ${e.toString().replaceFirst(RegExp(r'^\w+: '), '')}',
        error: true,
      );
      return;
    }
    notice.show('Removed ${a.email}');
    // A list narrowed to the account it no longer has shows all of them instead.
    if (scoped) queries.set(mailboxQuery(FolderRole.inbox, null));
    if (mounted) ref.invalidate(accountsProvider);
    // With the last one gone the start screen comes back, with nothing left over it.
    if (last) {
      nav.popUntil((r) => r.isFirst);
    } else if (mounted) {
      nav.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final found = _find(ref.watch(accountsProvider).value);
    _fill(found);
    if (found != null) _last = found;
    final a = found ?? _last;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _saveOnLeave();
      },
      child: Scaffold(
        backgroundColor: s.bg,
        appBar: _bar(context, null),
        body: a == null
            ? const SizedBox.shrink()
            : SafeArea(
                top: false,
                // Built whole, not lazily: with large text on a small phone the password
                // field sits below the fold and still has to take the focus.
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          Touch.gutter,
                          4,
                          Touch.gutter,
                          8,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Semantics(
                              header: true,
                              child: Text(
                                a.email,
                                style: ui(
                                  context,
                                  size: 17,
                                  weight: FontWeight.w600,
                                  height: 1.3,
                                ),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${_provider(a)} · ${_method(a)}',
                              style: ui(context, size: 14, color: s.fg2),
                            ),
                          ],
                        ),
                      ),
                      if (a.problem case final p?)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            Touch.gutter,
                            8,
                            Touch.gutter,
                            0,
                          ),
                          child: ProblemNote(
                            p,
                            key: ValueKey('${p.title}${p.detail}'),
                          ),
                        ),
                      const _Header('Name shown to recipients'),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Touch.gutter,
                        ),
                        child: QuietField(
                          controller: _name,
                          hint: 'Your name',
                          keyboardType: TextInputType.name,
                          textCapitalization: TextCapitalization.words,
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.name],
                        ),
                      ),
                      const _Header('Signature'),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Touch.gutter,
                        ),
                        child: _SignatureField(controller: _signature),
                      ),
                      const _Header('Sign-in'),
                      const Hairline(),
                      if (a.signInProvider case final provider?)
                        _Row(
                          title:
                              'Signed in with ${provider == 'microsoft' ? 'Microsoft' : 'Google'}',
                          trailing: TextButton(
                            onPressed: _signingIn ? null : () => _signIn(a),
                            child: Text(
                              _signingIn
                                  ? 'Signing in…'
                                  : a.needsPassword
                                  ? 'Sign in'
                                  : 'Sign in again',
                            ),
                          ),
                        )
                      else
                        _passwordPart(context, a),
                      const Hairline(),
                      const SizedBox(height: 32),
                      const Hairline(),
                      _Row(
                        title: 'Remove account',
                        color: s.red,
                        onTap: () => _remove(a),
                      ),
                      const Hairline(),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  /// "Password", opening to a new one and Check and save; always open while the server
  /// refuses the stored one.
  Widget _passwordPart(BuildContext context, Account a) {
    final s = context.s;
    final parked = a.needsPassword;
    final open = _passwordOpen || parked;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Row(
          title: 'Password',
          trailing: parked
              ? null
              : AnimatedRotation(
                  turns: open ? 0.5 : 0,
                  duration: Motion.of(context, Motion.fast),
                  child: Icon(AppIcons.expand, size: 18, color: s.fg2),
                ),
          onTap: parked ? null : _togglePassword,
        ),
        AnimatedSize(
          duration: Motion.of(context, Motion.base),
          curve: Motion.curve,
          alignment: Alignment.topCenter,
          child: !open
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Touch.gutter,
                    4,
                    Touch.gutter,
                    16,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      QuietField(
                        controller: _password,
                        focusNode: _passwordFocus,
                        hint: parked ? 'New app password' : 'New password',
                        obscure: true,
                        reveal: true,
                        autofocus: widget.focusPassword,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _checkPassword(a),
                      ),
                      if (_passwordProblem case final p?) ...[
                        const SizedBox(height: 12),
                        ProblemNote(p, key: ValueKey('${p.title}${p.detail}')),
                      ],
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: _checking || _password.text.isEmpty
                            ? null
                            : () => _checkPassword(a),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(Touch.target),
                        ),
                        child: Text(_checking ? 'Checking…' : 'Check and save'),
                      ),
                      if (parked) ...[
                        const SizedBox(height: 12),
                        Text(
                          'Syncing is paused so the server doesn’t lock the mailbox after repeated refusals.',
                          style: ui(
                            context,
                            size: 14,
                            color: s.fg2,
                            height: 1.4,
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: _checking ? null : () => _retry(a),
                            child: const Text('Try again'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

/// A signature: several lines in the same box as the other fields, growing as it is
/// typed.
class _SignatureField extends StatelessWidget {
  const _SignatureField({required this.controller});
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: s.raised,
        borderRadius: BorderRadius.circular(Touch.radius),
        border: Border.all(color: s.border),
      ),
      child: TextField(
        controller: controller,
        minLines: 3,
        maxLines: null,
        keyboardType: TextInputType.multiline,
        textCapitalization: TextCapitalization.sentences,
        style: ui(context, size: 16, height: 1.45),
        cursorColor: s.fg,
        cursorWidth: 1.5,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.all(12),
          hintText: 'Added under “-- ” in new messages',
          hintStyle: ui(context, size: 16, color: s.fg3),
        ),
      ),
    );
  }
}
