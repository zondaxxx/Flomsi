import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../theme/motion.dart';
import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';

const _presets = <String, (String, String)>{
  'gmail.com': (
    'imap.gmail.com',
    'Use an app password (Google Account → Security → App passwords).',
  ),
  'googlemail.com': ('imap.gmail.com', 'Use an app password.'),
  'icloud.com': (
    'imap.mail.me.com',
    'Use an app-specific password from appleid.apple.com.',
  ),
  'me.com': ('imap.mail.me.com', 'Use an app-specific password.'),
  'outlook.com': (
    'outlook.office365.com',
    'Use an app password; basic auth must be enabled for the account.',
  ),
  'hotmail.com': ('outlook.office365.com', 'Use an app password.'),
  'yandex.ru': ('imap.yandex.ru', 'Use an app password from id.yandex.ru.'),
  'yandex.com': ('imap.yandex.com', 'Use an app password.'),
  'fastmail.com': ('imap.fastmail.com', 'Use an app password.'),
  'proton.me': ('127.0.0.1', 'Requires Proton Bridge running locally.'),
};

Future<void> showAddAccountSheet(BuildContext context) =>
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.black.withValues(alpha: 0.25),
      transitionDuration: const Duration(milliseconds: 120),
      pageBuilder: (_, _, _) => const Center(
        child: Appear(duration: Motion.fast, dy: 8, child: AddAccountSheet()),
      ),
    );

class AddAccountSheet extends ConsumerStatefulWidget {
  const AddAccountSheet({super.key});

  @override
  ConsumerState<AddAccountSheet> createState() => _AddAccountSheetState();
}

class _AddAccountSheetState extends ConsumerState<AddAccountSheet> {
  final _email = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '993');
  final _password = TextEditingController();
  String? _hint;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    ref.read(scopeProvider.notifier).set('dialog');
    _email.addListener(_autofill);
  }

  @override
  void dispose() {
    ref.read(scopeProvider.notifier).set('list');
    _email.dispose();
    _host.dispose();
    _port.dispose();
    _password.dispose();
    super.dispose();
  }

  void _autofill() {
    final domain = _email.text
        .split('@')
        .elementAtOrNull(1)
        ?.trim()
        .toLowerCase();
    if (domain == null) return;
    final preset = _presets[domain];
    if (preset != null &&
        (_host.text.isEmpty ||
            _presets.values.any((p) => p.$1 == _host.text))) {
      setState(() {
        _host.text = preset.$1;
        _hint = preset.$2;
      });
    }
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(repositoryProvider);
      final email = _email.text.trim();
      final host = _host.text.trim();
      final port = int.tryParse(_port.text.trim()) ?? 993;
      await repo.testImapLogin(
        email: email,
        host: host,
        port: port,
        password: _password.text,
      );
      await repo.addImapAccount(
        email: email,
        host: host,
        port: port,
        password: _password.text,
      );
      _password.clear();
      if (mounted) Navigator.of(context).pop();
      unawaited(repo.sync());
    } catch (e) {
      setState(() {
        _busy = false;
        _error = e.toString().replaceFirst(RegExp(r'^\w+: '), '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Container(
      width: 440,
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
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
            'IMAP over TLS. The password is stored in the system keychain.',
            style: ui(context, size: 12, color: s.fg2),
          ),
          const SizedBox(height: 16),
          _field('Email', _email, hint: 'you@gmail.com', autofocus: true),
          _field('IMAP Server', _host, hint: 'imap.example.com'),
          Row(
            children: [
              SizedBox(width: 90, child: _field('Port', _port, hint: '993')),
              const SizedBox(width: 12),
              Expanded(
                child: _field(
                  'Password',
                  _password,
                  hint: 'App password',
                  obscure: true,
                  onSubmit: _submit,
                ),
              ),
            ],
          ),
          if (_hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(_hint!, style: ui(context, size: 11.5, color: s.fg3)),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_error!, style: ui(context, size: 12, color: s.red)),
            ),
          const SizedBox(height: 18),
          Row(
            children: [
              const Spacer(),
              SmallButton(
                label: 'Cancel',
                onPressed: () => Navigator.of(context).pop(),
              ),
              const SizedBox(width: 8),
              SmallButton(
                label: _busy ? 'Connecting…' : 'Add',
                primary: true,
                onPressed: _busy ? null : _submit,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController c, {
    String? hint,
    bool obscure = false,
    bool autofocus = false,
    VoidCallback? onSubmit,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: ui(context, size: 11.5, color: context.s.fg2)),
        const SizedBox(height: 4),
        QuietField(
          controller: c,
          hint: hint,
          obscure: obscure,
          autofocus: autofocus,
          onSubmitted: (_) => onSubmit?.call(),
        ),
      ],
    ),
  );
}
