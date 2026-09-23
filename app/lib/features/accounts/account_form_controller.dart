import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../data/models.dart';
import '../../data/repository.dart';
import 'add_account_sheet.dart' show Preset, isLoopback, presetFor;

/// Where an account form is: typing, the servers being asked, the account being added.
enum FormStep { idle, checking, adding }

/// The fields of an account added with a password, and what adding it takes: the address
/// fills the servers from the provider presets (or `imap.<domain>`), the servers are asked
/// before anything is saved, and a refused SMTP alone may be added anyway.
class AccountFormController extends ChangeNotifier {
  AccountFormController({required this.repo, Preset? preset})
    : _fixed = preset {
    if (preset != null) _apply(preset.imap, preset.smtp);
    email.addListener(_autofill);
  }

  final MailRepository repo;

  /// Servers chosen with the provider (iCloud+ and Yandex 360 on their own domains):
  /// the address never changes them.
  final Preset? _fixed;

  final email = TextEditingController();
  final password = TextEditingController();
  final imapHost = TextEditingController();
  final imapPort = TextEditingController(text: '993');
  final smtpHost = TextEditingController();
  final smtpPort = TextEditingController(text: '465');
  bool imapStartTls = false;
  bool smtpStartTls = false;

  /// Servers typed by hand are never overwritten.
  bool serversTouched = false;
  Problem? problem;
  FormStep step = FormStep.idle;

  bool get busy => step != FormStep.idle;

  @override
  void dispose() {
    for (final c in [email, password, imapHost, imapPort, smtpHost, smtpPort]) {
      c.dispose();
    }
    super.dispose();
  }

  String? get domain {
    final parts = email.text.trim().toLowerCase().split('@');
    if (parts.length != 2 || !parts[1].contains('.')) return null;
    return parts[1];
  }

  void _autofill() {
    if (_fixed != null || serversTouched) return;
    final d = domain;
    if (d == null) return;
    final preset = presetFor(d);
    if (preset != null) {
      _apply(preset.imap, preset.smtp);
    } else {
      final imap = ServerSetup(host: 'imap.$d', port: 993);
      _apply(
        imap,
        repo.suggestSmtp(imap.host) ??
            ServerSetup(host: 'smtp.$d', port: 587, startTls: true),
      );
    }
    notifyListeners();
  }

  void _apply(ServerSetup imap, ServerSetup smtp) {
    imapHost.text = imap.host;
    imapPort.text = '${imap.port}';
    imapStartTls = imap.startTls;
    smtpHost.text = smtp.host;
    smtpPort.text = '${smtp.port}';
    smtpStartTls = smtp.startTls;
  }

  /// A server field was edited by hand.
  void touchServers() {
    serversTouched = true;
    edited();
  }

  /// A problem belongs to what was tried; editing starts a new attempt.
  void edited() {
    if (problem != null && step == FormStep.idle) {
      problem = null;
      notifyListeners();
    } else {
      notifyListeners();
    }
  }

  void setSecurity({bool? imapStart, bool? smtpStart}) {
    if (imapStart != null) {
      imapStartTls = imapStart;
      // Ports follow the choice unless someone typed one.
      if (imapPort.text == '993' || imapPort.text == '143') {
        imapPort.text = imapStart ? '143' : '993';
      }
    }
    if (smtpStart != null) {
      smtpStartTls = smtpStart;
      if (smtpPort.text == '465' || smtpPort.text == '587') {
        smtpPort.text = smtpStart ? '587' : '465';
      }
    }
    touchServers();
  }

  ServerSetup get imap => ServerSetup(
    host: imapHost.text.trim(),
    port: int.tryParse(imapPort.text.trim()) ?? 0,
    startTls: imapStartTls,
  );

  ServerSetup get smtp => ServerSetup(
    host: smtpHost.text.trim(),
    port: int.tryParse(smtpPort.text.trim()) ?? 0,
    startTls: smtpStartTls,
  );

  AccountSetup get setup => AccountSetup(
    email: email.text.trim(),
    imap: imap,
    smtp: smtp,
    localBridge: isLoopback(imap.host) && isLoopback(smtp.host),
  );

  bool get complete => domain != null && password.text.isNotEmpty;

  /// What is missing before anything goes to a server, or null.
  Problem? incomplete() {
    Problem missing(String title, [String? hint]) =>
        Problem(kind: 'local', title: title, hint: hint);
    if (domain == null) return missing('Enter the full address, name@domain');
    if (password.text.isEmpty) return missing('Enter the password');
    if (imap.host.isEmpty || imap.port <= 0 || imap.port > 65535) {
      return missing(
        'Check the incoming server',
        'Name and port, usually 993 with TLS.',
      );
    }
    if (smtp.host.isEmpty || smtp.port <= 0 || smtp.port > 65535) {
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
    return a != null && _key(a.$1) == _key(setup) && a.$2 == password.text;
  }

  /// SMTP can fail for reasons that do not stop reading mail (a blocked port on this
  /// network): such an account may be added anyway.
  bool get canAddAnyway {
    final p = problem;
    return p != null && p.stage == 'smtp' && !p.isAuth && _attemptIsCurrent;
  }

  /// Check the servers, then add. Returns the account, or null (see [problem]).
  Future<Account?> submit({bool skipCheck = false}) async {
    if (busy) return null;
    final missing = incomplete();
    if (missing != null) {
      problem = missing;
      notifyListeners();
      return null;
    }
    if (skipCheck && !_attemptIsCurrent) return null;
    final (s, pw) = skipCheck ? _attempt! : (setup, password.text);
    _attempt = (s, pw);
    problem = null;
    step = skipCheck ? FormStep.adding : FormStep.checking;
    notifyListeners();
    try {
      final address = s.email.toLowerCase();
      if ((await repo.accounts()).any(
        (a) => a.email.toLowerCase() == address,
      )) {
        throw const Problem(
          kind: 'local',
          title: 'This address is already added',
          hint: 'To use a new password, open Settings → Accounts.',
        );
      }
      if (!skipCheck) {
        await repo.checkAccount(s, pw);
        step = FormStep.adding;
        notifyListeners();
      }
      final a = await repo.addAccount(s, pw);
      unawaited(repo.sync());
      password.clear();
      step = FormStep.idle;
      notifyListeners();
      return a;
    } on Problem catch (p) {
      step = FormStep.idle;
      problem = p;
      notifyListeners();
      return null;
    } catch (e) {
      step = FormStep.idle;
      problem = Problem(kind: 'local', title: '$e');
      notifyListeners();
      return null;
    }
  }
}
