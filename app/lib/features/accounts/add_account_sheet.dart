import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../state/providers.dart';
import '../../theme/motion.dart';
import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';
import 'problem_note.dart';

/// Server settings and a sign-in note for the providers people use most.
class Preset {
  const Preset(this.imap, this.smtp, this.note);
  final ServerSetup imap;
  final ServerSetup smtp;
  final String note;
}

const _gmail = Preset(
  ServerSetup(host: 'imap.gmail.com', port: 993),
  ServerSetup(host: 'smtp.gmail.com', port: 465),
  'Gmail wants an app password: turn on 2-Step Verification, then create one at myaccount.google.com/apppasswords.',
);
const _icloud = Preset(
  ServerSetup(host: 'imap.mail.me.com', port: 993),
  ServerSetup(host: 'smtp.mail.me.com', port: 587, startTls: true),
  'iCloud wants an app-specific password from account.apple.com → Sign-In and Security.',
);
const _outlook = Preset(
  ServerSetup(host: 'outlook.office365.com', port: 993),
  ServerSetup(host: 'smtp-mail.outlook.com', port: 587, startTls: true),
  'Microsoft turned off password sign-in over IMAP for Outlook.com, so this will most likely be refused. Signing in with a Microsoft account is not supported yet.',
);
const _yandex = Preset(
  ServerSetup(host: 'imap.yandex.ru', port: 993),
  ServerSetup(host: 'smtp.yandex.ru', port: 465),
  'Yandex wants an app password from id.yandex.ru, and IMAP allowed in Mail settings → Mail clients.',
);
const _yandexCom = Preset(
  ServerSetup(host: 'imap.yandex.com', port: 993),
  ServerSetup(host: 'smtp.yandex.com', port: 465),
  'Yandex wants an app password from id.yandex.com, and IMAP allowed in Mail settings.',
);
const _mailru = Preset(
  ServerSetup(host: 'imap.mail.ru', port: 993),
  ServerSetup(host: 'smtp.mail.ru', port: 465),
  'Mail.ru wants a password for external apps: Settings → Security → Passwords for external applications.',
);
const _fastmail = Preset(
  ServerSetup(host: 'imap.fastmail.com', port: 993),
  ServerSetup(host: 'smtp.fastmail.com', port: 465),
  'Fastmail wants an app password from Settings → Privacy & Security.',
);
const _proton = Preset(
  ServerSetup(host: '127.0.0.1', port: 1143, startTls: true),
  ServerSetup(host: '127.0.0.1', port: 1025, startTls: true),
  'Proton Bridge must be running on this computer. Use the password Bridge shows for this address, not your Proton password.',
);

/// The presets by provider, for guides that pick the provider first.
const providerPresets = <String, Preset>{
  'gmail': _gmail,
  'icloud': _icloud,
  'yandex': _yandex,
  'yandex_com': _yandexCom,
  'mailru': _mailru,
  'fastmail': _fastmail,
  'proton': _proton,
};

const presets = <String, Preset>{
  'gmail.com': _gmail,
  'googlemail.com': _gmail,
  'icloud.com': _icloud,
  'me.com': _icloud,
  'mac.com': _icloud,
  'outlook.com': _outlook,
  'hotmail.com': _outlook,
  'live.com': _outlook,
  'msn.com': _outlook,
  'yandex.ru': _yandex,
  'ya.ru': _yandex,
  'yandex.com': _yandexCom,
  'mail.ru': _mailru,
  'bk.ru': _mailru,
  'inbox.ru': _mailru,
  'list.ru': _mailru,
  'internet.ru': _mailru,
  'fastmail.com': _fastmail,
  'fastmail.fm': _fastmail,
  'proton.me': _proton,
  'protonmail.com': _proton,
  'protonmail.ch': _proton,
  'pm.me': _proton,
};

/// The preset for [domain], including Microsoft's country domains (hotmail.co.uk, live.fr…).
Preset? presetFor(String domain) =>
    presets[domain] ??
    (RegExp(r'^(hotmail|outlook|live)\.').hasMatch(domain) ? _outlook : null);

/// Same rule as the core's: `localhost`, 127.0.0.0/8 or ::1, nothing that merely looks alike.
bool isLoopback(String host) {
  final h = host.trim().toLowerCase().replaceAll(RegExp(r'[\[\]]'), '');
  if (h == 'localhost' || h == '::1') return true;
  final parts = h.split('.');
  return parts.length == 4 &&
      parts.first == '127' &&
      parts.every((p) {
        final n = int.tryParse(p);
        return n != null && n >= 0 && n <= 255;
      });
}

/// The keymap scope is set around the dialog here, not in the sheet's lifecycle methods:
/// Riverpod does not allow providers to change while widgets mount or unmount.
Future<void> showAddAccountSheet(BuildContext context) async {
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
      pageBuilder: (_, _, _) => const _Placement(
        child: Appear(duration: Motion.fast, dy: 8, child: AddAccountSheet()),
      ),
    );
  } finally {
    scope.set('list');
  }
}

/// Centered, but lifted above an on-screen keyboard and scrollable when it does not fit.
class _Placement extends StatelessWidget {
  const _Placement({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.viewInsetsOf(context);
    final padding = MediaQuery.paddingOf(context);
    return AnimatedPadding(
      duration: const Duration(milliseconds: 120),
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(16, padding.top + 16, 16, 16),
          child: child,
        ),
      ),
    );
  }
}

class AddAccountSheet extends ConsumerStatefulWidget {
  const AddAccountSheet({super.key});

  @override
  ConsumerState<AddAccountSheet> createState() => _AddAccountSheetState();
}

enum _Step { idle, checking, adding }

class _AddAccountSheetState extends ConsumerState<AddAccountSheet> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _imapHost = TextEditingController();
  final _imapPort = TextEditingController(text: '993');
  final _smtpHost = TextEditingController();
  final _smtpPort = TextEditingController(text: '465');
  bool _imapStartTls = false;
  bool _smtpStartTls = false;

  /// Servers typed by hand are never overwritten by a preset.
  bool _serversTouched = false;
  bool _serversOpen = false;
  String? _note;
  Problem? _problem;
  _Step _step = _Step.idle;

  @override
  void initState() {
    super.initState();
    _email.addListener(_autofill);
  }

  @override
  void dispose() {
    for (final c in [
      _email,
      _password,
      _imapHost,
      _imapPort,
      _smtpHost,
      _smtpPort,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String? get _domain {
    final parts = _email.text.trim().toLowerCase().split('@');
    if (parts.length != 2 || !parts[1].contains('.')) return null;
    return parts[1];
  }

  void _autofill() {
    final domain = _domain;
    final preset = domain == null ? null : presetFor(domain);
    setState(() {
      _note = preset?.note;
      if (_serversTouched || domain == null) return;
      if (preset != null) {
        _apply(preset.imap, preset.smtp);
      } else {
        final imap = ServerSetup(host: 'imap.$domain', port: 993);
        final smtp =
            ref.read(repositoryProvider).suggestSmtp(imap.host) ??
            ServerSetup(host: 'smtp.$domain', port: 587, startTls: true);
        _apply(imap, smtp);
      }
    });
  }

  void _apply(ServerSetup imap, ServerSetup smtp) {
    _imapHost.text = imap.host;
    _imapPort.text = '${imap.port}';
    _imapStartTls = imap.startTls;
    _smtpHost.text = smtp.host;
    _smtpPort.text = '${smtp.port}';
    _smtpStartTls = smtp.startTls;
  }

  void _touch() {
    if (!_serversTouched || _problem != null) {
      setState(() {
        _serversTouched = true;
        _problem = null;
      });
    }
  }

  /// A problem belongs to what was tried; editing starts a new attempt.
  void _edited(String _) {
    if (_problem != null && _step == _Step.idle) {
      setState(() => _problem = null);
    }
  }

  ServerSetup get _imap => ServerSetup(
    host: _imapHost.text.trim(),
    port: int.tryParse(_imapPort.text.trim()) ?? 0,
    startTls: _imapStartTls,
  );

  ServerSetup get _smtp => ServerSetup(
    host: _smtpHost.text.trim(),
    port: int.tryParse(_smtpPort.text.trim()) ?? 0,
    startTls: _smtpStartTls,
  );

  bool get _localBridge => isLoopback(_imap.host) && isLoopback(_smtp.host);

  AccountSetup get _setup => AccountSetup(
    email: _email.text.trim(),
    imap: _imap,
    smtp: _smtp,
    localBridge: _localBridge,
  );

  /// What is missing before anything goes to a server, or null.
  Problem? _incomplete() {
    Problem missing(String title, [String? hint]) =>
        Problem(kind: 'local', title: title, hint: hint);
    if (_domain == null) return missing('Enter the full address, name@domain');
    if (_password.text.isEmpty) return missing('Enter the password');
    final imap = _imap, smtp = _smtp;
    if (imap.host.isEmpty || imap.port <= 0 || imap.port > 65535) {
      _serversOpen = true;
      return missing(
        'Check the incoming server',
        'Name and port, usually 993 with TLS.',
      );
    }
    if (smtp.host.isEmpty || smtp.port <= 0 || smtp.port > 65535) {
      _serversOpen = true;
      return missing(
        'Check the outgoing server',
        'Name and port, usually 465 with TLS or 587 with STARTTLS.',
      );
    }
    return null;
  }

  /// What the last check signed in with; "Add anyway" adds exactly that.
  (AccountSetup, String)? _attempt;

  static String _key(AccountSetup a) =>
      '${a.email}|${a.imap}|${a.smtp}|${a.localBridge}';

  bool get _attemptIsCurrent {
    final a = _attempt;
    return a != null && _key(a.$1) == _key(_setup) && a.$2 == _password.text;
  }

  Future<void> _submit({bool skipCheck = false}) async {
    if (_step != _Step.idle) return;
    final incomplete = _incomplete();
    if (incomplete != null) {
      setState(() => _problem = incomplete);
      return;
    }
    if (skipCheck && !_attemptIsCurrent) return;
    final repo = ref.read(repositoryProvider);
    // Taken now: the sheet may be closed before the servers answer.
    final notice = ref.read(noticeProvider.notifier);
    final (setup, password) = skipCheck ? _attempt! : (_setup, _password.text);
    _attempt = (setup, password);
    setState(() {
      _problem = null;
      _step = skipCheck ? _Step.adding : _Step.checking;
    });
    try {
      // An address that is already here needs no trip to the server.
      final email = setup.email.toLowerCase();
      if ((await repo.accounts()).any((a) => a.email.toLowerCase() == email)) {
        throw const Problem(
          kind: 'local',
          title: 'This address is already added',
          hint: 'To use a new password, open Settings → Accounts.',
        );
      }
      if (!skipCheck) {
        await repo.checkAccount(setup, password);
        if (!mounted) return;
        setState(() => _step = _Step.adding);
      }
      await repo.addAccount(setup, password);
      unawaited(repo.sync());
      notice.show('Added ${setup.email}');
      if (!mounted) return;
      _password.clear();
      Navigator.of(context).pop();
    } on Problem catch (p) {
      if (!mounted) return;
      setState(() {
        _step = _Step.idle;
        _problem = p;
        // A refused server is often a wrong server setting: show them.
        if (p.stage != null && !p.isAuth) _serversOpen = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _step = _Step.idle;
        _problem = Problem(kind: 'local', title: '$e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final width = MediaQuery.sizeOf(context).width;
    final busy = _step != _Step.idle;
    final problem = _problem;
    // SMTP can fail for reasons that do not stop reading mail (a blocked port on
    // this network): let people add the account anyway.
    final offerAnyway =
        problem != null &&
        problem.stage == 'smtp' &&
        !problem.isAuth &&
        _attemptIsCurrent;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: (width - 32).clamp(280.0, 460.0),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        decoration: BoxDecoration(
          color: s.bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: s.border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: s.isDark ? 0.5 : 0.18),
              blurRadius: 30,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Add Account',
              style: ui(context, size: 15, weight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'Mail over IMAP and SMTP. The password stays in the system keychain.',
              style: ui(context, size: 12, color: s.fg2),
            ),
            const SizedBox(height: 16),
            _label('Email'),
            QuietField(
              controller: _email,
              hint: 'you@example.com',
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              onChanged: _edited,
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 10),
            _label('Password'),
            QuietField(
              controller: _password,
              hint: 'App password',
              obscure: true,
              onChanged: _edited,
              onSubmitted: (_) => _submit(),
            ),
            AnimatedSize(
              duration: Motion.of(context, Motion.fast),
              curve: Motion.curve,
              alignment: Alignment.topLeft,
              child: _note == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        _note!,
                        style: ui(
                          context,
                          size: 11.5,
                          color: s.fg3,
                          height: 1.4,
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 12),
            _servers(context),
            AnimatedSize(
              duration: Motion.of(context, Motion.fast),
              curve: Motion.curve,
              alignment: Alignment.topLeft,
              child: problem == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: ProblemNote(
                        problem,
                        key: ValueKey('${problem.stage}${problem.title}'),
                      ),
                    ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Spacer(),
                SmallButton(
                  label: 'Cancel',
                  onPressed: () => Navigator.of(context).pop(),
                ),
                if (offerAnyway && !busy) ...[
                  const SizedBox(width: 8),
                  SmallButton(
                    label: 'Add anyway',
                    onPressed: () => _submit(skipCheck: true),
                  ),
                ],
                const SizedBox(width: 8),
                SmallButton(
                  label: switch (_step) {
                    _Step.idle => 'Add',
                    _Step.checking => 'Signing in…',
                    _Step.adding => 'Adding…',
                  },
                  primary: true,
                  onPressed: busy ? null : _submit,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _servers(BuildContext context) {
    final s = context.s;
    final summary = _imapHost.text.isEmpty
        ? 'filled in from the address'
        : 'IMAP $_imap · SMTP $_smtp';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HoverRegion(
          onTap: () => setState(() => _serversOpen = !_serversOpen),
          builder: (context, hovered) => Row(
            children: [
              AnimatedRotation(
                turns: _serversOpen ? 0.25 : 0,
                duration: Motion.of(context, Motion.fast),
                curve: Motion.curve,
                child: Icon(
                  CupertinoIcons.chevron_right,
                  size: 11,
                  color: hovered ? s.fg : s.fg2,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                'Servers',
                style: ui(context, size: 11.5, color: hovered ? s.fg : s.fg2),
              ),
              const SizedBox(width: 8),
              if (!_serversOpen)
                Expanded(
                  child: Text(
                    summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: mono(context, size: 11, color: s.fg3),
                  ),
                ),
            ],
          ),
        ),
        AnimatedSize(
          duration: Motion.of(context, Motion.fast),
          curve: Motion.curve,
          alignment: Alignment.topLeft,
          child: !_serversOpen
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _serverRow(
                        'Incoming · IMAP',
                        _imapHost,
                        _imapPort,
                        _imapStartTls,
                        (v) => setState(() {
                          _imapStartTls = v;
                          _serversTouched = true;
                          _problem = null;
                        }),
                        hostHint: 'imap.example.com',
                      ),
                      const SizedBox(height: 10),
                      _serverRow(
                        'Outgoing · SMTP',
                        _smtpHost,
                        _smtpPort,
                        _smtpStartTls,
                        (v) => setState(() {
                          _smtpStartTls = v;
                          _serversTouched = true;
                          _problem = null;
                        }),
                        hostHint: 'smtp.example.com',
                      ),
                      if (_localBridge)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'A bridge on this computer: its own certificate is accepted as it is.',
                            style: ui(context, size: 11.5, color: s.fg3),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _serverRow(
    String title,
    TextEditingController host,
    TextEditingController port,
    bool startTls,
    ValueChanged<bool> onSecurity, {
    required String hostHint,
  }) {
    final fields = Row(
      children: [
        Expanded(
          child: QuietField(
            controller: host,
            hint: hostHint,
            keyboardType: TextInputType.url,
            onChanged: (_) => _touch(),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 64,
          child: QuietField(
            controller: port,
            hint: 'port',
            keyboardType: TextInputType.number,
            onChanged: (_) => _touch(),
          ),
        ),
      ],
    );
    final security = Segmented<bool>(
      height: 22,
      options: const [(false, 'TLS'), (true, 'STARTTLS')],
      value: startTls,
      onChanged: onSecurity,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label(title),
        LayoutBuilder(
          // On a phone the security choice goes under the name and port.
          builder: (context, c) => c.maxWidth < 380
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [fields, const SizedBox(height: 6), security],
                )
              : Row(
                  children: [
                    Expanded(child: fields),
                    const SizedBox(width: 6),
                    security,
                  ],
                ),
        ),
      ],
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(text, style: ui(context, size: 11.5, color: context.s.fg2)),
  );
}
