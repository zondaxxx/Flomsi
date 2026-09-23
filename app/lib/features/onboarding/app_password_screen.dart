import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models.dart';
import '../../state/providers.dart';
import '../../theme/app_icons.dart';
import '../../theme/motion.dart';
import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';
import '../accounts/account_form_controller.dart';
import '../accounts/problem_note.dart';
import '../accounts/provider_guides.dart';
import 'manual_server_screen.dart';

/// A provider that wants an app password: its steps, each with the page it happens on,
/// then the address and the password, checked with the servers before anything is kept.
class AppPasswordScreen extends ConsumerStatefulWidget {
  const AppPasswordScreen({super.key, required this.guide, this.onAdded});
  final ProviderGuide guide;
  final void Function(Account account)? onAdded;

  @override
  ConsumerState<AppPasswordScreen> createState() => _AppPasswordScreenState();
}

class _AppPasswordScreenState extends ConsumerState<AppPasswordScreen>
    with WidgetsBindingObserver {
  late final AccountFormController _form = AccountFormController(
    repo: ref.read(repositoryProvider),
    preset: widget.guide.preset,
  );
  final _passwordFocus = FocusNode();
  bool _servers = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _form.addListener(_changed);
    _form.password.addListener(_stripSpaces);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _form.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  /// Gmail shows app passwords in groups of four; the spaces are not part of them.
  void _stripSpaces() {
    if (!widget.guide.stripSpaces) return;
    final t = _form.password.text;
    if (t.contains(' ')) {
      _form.password.value = TextEditingValue(
        text: t.replaceAll(' ', ''),
        selection: TextSelection.collapsed(
          offset: t.replaceAll(' ', '').length,
        ),
      );
    }
  }

  /// Back from the provider's page with the password copied: straight to its field.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _form.email.text.trim().isNotEmpty &&
        _form.password.text.isEmpty) {
      _passwordFocus.requestFocus();
    }
  }

  Future<void> _open(String url) => launchUrl(
    Uri.parse(url),
    mode: Theme.of(context).platform == TargetPlatform.android
        ? LaunchMode.inAppBrowserView
        : LaunchMode.externalApplication,
  );

  Future<void> _submit({bool anyway = false}) async {
    final notice = ref.read(noticeProvider.notifier);
    final a = await _form.submit(skipCheck: anyway);
    if (a == null || !mounted) return;
    TextInput.finishAutofillContext();
    notice.show('Added ${a.email}');
    widget.onAdded?.call(a);
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  /// The provider's own words for a refused password, pointing at the right one.
  Problem? get _problem {
    final p = _form.problem;
    if (p == null || !p.isAuth) return p;
    return Problem(
      kind: p.kind,
      title: '${widget.guide.name} refused the password',
      hint:
          'Use the ${widget.guide.passwordName} from the steps above, not your account password.',
      detail: p.detail,
      stage: p.stage,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final g = widget.guide;
    final busy = _form.busy;
    final problem = _problem;
    final steps = [
      for (final (i, step) in g.steps.indexed)
        _Step(number: i + 1, step: step, open: _open),
    ];
    return Scaffold(
      backgroundColor: s.bg,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: s.bg,
        surfaceTintColor: Colors.transparent,
        title: Text(
          g.name,
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
                        Text(
                          g.intro,
                          style: ui(
                            context,
                            size: 15,
                            color: s.fg2,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 16),
                        ...steps,
                        _Numbered(
                          number: g.steps.length + 1,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                'Enter your address and the ${g.passwordName}.',
                                style: ui(context, size: 15, height: 1.45),
                              ),
                              const SizedBox(height: 12),
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
                                hint:
                                    g.passwordName[0].toUpperCase() +
                                    g.passwordName.substring(1),
                                obscure: true,
                                reveal: true,
                                textInputAction: TextInputAction.done,
                                onChanged: (_) => _form.edited(),
                                onSubmitted: (_) => _submit(),
                              ),
                            ],
                          ),
                        ),
                        if (g.note != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              g.note!,
                              style: ui(context, size: 13, color: s.fg2),
                            ),
                          ),
                        const SizedBox(height: 8),
                        InkWell(
                          onTap: () => setState(() => _servers = !_servers),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              minHeight: Touch.row,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Server settings',
                                    style: ui(context, size: 15, color: s.fg2),
                                  ),
                                ),
                                AnimatedRotation(
                                  turns: _servers ? 0.5 : 0,
                                  duration: Motion.of(context, Motion.fast),
                                  child: Icon(
                                    AppIcons.expand,
                                    size: 18,
                                    color: s.fg2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        AnimatedSize(
                          duration: Motion.of(context, Motion.base),
                          curve: Motion.curve,
                          alignment: Alignment.topCenter,
                          child: _servers
                              ? ServerFields(form: _form)
                              : const SizedBox(width: double.infinity),
                        ),
                        AnimatedSize(
                          duration: Motion.of(context, Motion.base),
                          alignment: Alignment.topCenter,
                          child: problem == null
                              ? const SizedBox(width: double.infinity)
                              : Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      ProblemNote(problem),
                                      if (_form.canAddAnyway)
                                        TextButton(
                                          onPressed: () =>
                                              _submit(anyway: true),
                                          child: const Text('Add anyway'),
                                        ),
                                    ],
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Under the form, above the keyboard.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: FilledButton(
                  onPressed: busy || !_form.complete ? null : _submit,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(Touch.button),
                  ),
                  child: Text(switch (_form.step) {
                    FormStep.checking => 'Checking…',
                    FormStep.adding => 'Adding…',
                    FormStep.idle => 'Sign in',
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

/// A numbered step: a hairline circle with the number, then what to do.
class _Numbered extends StatelessWidget {
  const _Numbered({required this.number, required this.child});
  final int number;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: s.border),
            ),
            child: Text(
              '$number',
              style: ui(
                context,
                size: 13,
                weight: FontWeight.w600,
                color: s.fg2,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.step, required this.open});
  final int number;
  final GuideStep step;
  final Future<void> Function(String url) open;

  @override
  Widget build(BuildContext context) {
    final link = step.link;
    return _Numbered(
      number: number,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(step.text, style: ui(context, size: 15, height: 1.45)),
          if (link != null)
            TextButton.icon(
              onPressed: () => open(link),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                alignment: Alignment.centerLeft,
              ),
              icon: Icon(AppIcons.external, size: 18),
              label: Text(step.linkLabel ?? 'Open'),
            ),
        ],
      ),
    );
  }
}
