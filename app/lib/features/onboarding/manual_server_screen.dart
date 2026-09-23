import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../state/providers.dart';
import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';
import '../accounts/account_form_controller.dart';
import '../accounts/add_account_sheet.dart' show providerPresets;
import '../accounts/problem_note.dart';

/// Any mail server by hand: the address and password, then incoming (IMAP) and outgoing
/// (SMTP) servers, filled in from the address and checked before anything is kept.
class ManualServerScreen extends ConsumerStatefulWidget {
  const ManualServerScreen({super.key, this.onAdded, this.proton = false});
  final void Function(Account account)? onAdded;

  /// Proton Mail Bridge on this computer: its local servers are filled in.
  final bool proton;

  @override
  ConsumerState<ManualServerScreen> createState() => _ManualServerScreenState();
}

class _ManualServerScreenState extends ConsumerState<ManualServerScreen> {
  late final AccountFormController _form = AccountFormController(
    repo: ref.read(repositoryProvider),
    preset: widget.proton ? providerPresets['proton'] : null,
  );
  final _passwordFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _form.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _form.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit({bool anyway = false}) async {
    final notice = ref.read(noticeProvider.notifier);
    final a = await _form.submit(skipCheck: anyway);
    if (a == null || !mounted) return;
    TextInput.finishAutofillContext();
    notice.show('Added ${a.email}');
    widget.onAdded?.call(a);
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final problem = _form.problem;
    return Scaffold(
      backgroundColor: s.bg,
      appBar: AppBar(
        backgroundColor: s.bg,
        surfaceTintColor: Colors.transparent,
        title: Text(
          widget.proton ? 'Proton Mail Bridge' : 'Other mail server',
          style: ui(context, size: 17, weight: FontWeight.w600),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: AutofillGroup(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      children: [
                        if (widget.proton)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              'Proton Mail Bridge must be running on this computer. Use the password Bridge shows for this address, not your Proton password.',
                              style: ui(
                                context,
                                size: 14,
                                color: s.fg2,
                                height: 1.45,
                              ),
                            ),
                          ),
                        _Section('Account'),
                        QuietField(
                          controller: _form.email,
                          hint: 'Email address',
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          autofillHints: const [
                            AutofillHints.email,
                            AutofillHints.username,
                          ],
                          onChanged: (_) => _form.edited(),
                          onEditingComplete: _passwordFocus.requestFocus,
                        ),
                        const SizedBox(height: 10),
                        QuietField(
                          controller: _form.password,
                          focusNode: _passwordFocus,
                          hint: 'Password',
                          obscure: true,
                          reveal: true,
                          autofillHints: const [AutofillHints.password],
                          textInputAction: TextInputAction.done,
                          onChanged: (_) => _form.edited(),
                          onSubmitted: (_) => _submit(),
                        ),
                        ServerFields(form: _form),
                        if (problem != null) ...[
                          const SizedBox(height: 12),
                          ProblemNote(problem),
                          if (_form.canAddAnyway)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton(
                                onPressed: () => _submit(anyway: true),
                                child: const Text('Add anyway'),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: FilledButton(
                  onPressed: _form.busy || !_form.complete ? null : _submit,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(Touch.button),
                  ),
                  child: Text(switch (_form.step) {
                    FormStep.checking => 'Checking…',
                    FormStep.adding => 'Adding…',
                    FormStep.idle => 'Check and add',
                  }),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
    child: Text(
      title,
      style: ui(
        context,
        size: 13,
        weight: FontWeight.w600,
        color: context.s.fg2,
      ),
    ),
  );
}

/// Incoming and outgoing servers: host, port, and TLS or STARTTLS for each.
class ServerFields extends StatelessWidget {
  const ServerFields({super.key, required this.form});
  final AccountFormController form;

  @override
  Widget build(BuildContext context) {
    Widget server(
      String title,
      TextEditingController host,
      TextEditingController port,
      bool startTls,
      void Function(bool) setStartTls,
    ) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Section(title),
        QuietField(
          controller: host,
          hint: 'Server',
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.next,
          onChanged: (_) => form.touchServers(),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            SizedBox(
              width: 110,
              child: QuietField(
                controller: port,
                hint: 'Port',
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.next,
                onChanged: (_) => form.touchServers(),
              ),
            ),
            const SizedBox(width: 12),
            Segmented<bool>(
              options: const [(false, 'TLS'), (true, 'STARTTLS')],
              value: startTls,
              onChanged: setStartTls,
            ),
          ],
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        server(
          'Incoming mail (IMAP)',
          form.imapHost,
          form.imapPort,
          form.imapStartTls,
          (v) => form.setSecurity(imapStart: v),
        ),
        server(
          'Outgoing mail (SMTP)',
          form.smtpHost,
          form.smtpPort,
          form.smtpStartTls,
          (v) => form.setSecurity(smtpStart: v),
        ),
      ],
    );
  }
}
