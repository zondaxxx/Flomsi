import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../data/models.dart';
import '../../platform.dart';
import '../../state/providers.dart';
import '../../theme/app_icons.dart';
import '../../theme/motion.dart';
import '../../theme/tokens.dart';
import '../accounts/problem_note.dart';
import '../accounts/provider_guides.dart';
import '../phone/phone_route.dart';
import 'app_password_screen.dart';
import 'provider_picker.dart';

/// Google's "G" as its brand kit draws it.
const _googleG =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 18 18">'
    '<path fill="#EA4335" d="M9 3.48c1.69 0 2.83.73 3.48 1.34l2.54-2.48C13.46.89 11.43 0 9 0 5.48 0 2.44 2.02.96 4.96l2.91 2.26C4.6 5.05 6.62 3.48 9 3.48z"/>'
    '<path fill="#4285F4" d="M17.64 9.2c0-.74-.06-1.28-.19-1.84H9v3.34h4.96c-.1.83-.64 2.08-1.84 2.92l2.84 2.2c1.7-1.57 2.68-3.88 2.68-6.62z"/>'
    '<path fill="#FBBC05" d="M3.88 10.78A5.54 5.54 0 0 1 3.58 9c0-.62.11-1.22.29-1.78L.96 4.96A9.008 9.008 0 0 0 0 9c0 1.45.35 2.82.96 4.04l2.92-2.26z"/>'
    '<path fill="#34A853" d="M9 18c2.43 0 4.47-.8 5.96-2.18l-2.84-2.2c-.76.53-1.78.9-3.12.9-2.38 0-4.4-1.57-5.12-3.74L.97 13.04C2.45 15.98 5.48 18 9 18z"/>'
    '</svg>';

/// Microsoft's four squares.
const _microsoft =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 21 21">'
    '<rect x="0" y="0" width="10" height="10" fill="#F25022"/>'
    '<rect x="11" y="0" width="10" height="10" fill="#7FBA00"/>'
    '<rect x="0" y="11" width="10" height="10" fill="#00A4EF"/>'
    '<rect x="11" y="11" width="10" height="10" fill="#FFB900"/>'
    '</svg>';

/// Google has not reviewed Flomsi (a mail app needs a security audit for that), so its
/// page warns first. Builds for a reviewed client pass --dart-define=FLOMSI_GOOGLE_VERIFIED=true.
const _googleVerified = bool.fromEnvironment('FLOMSI_GOOGLE_VERIFIED');

/// The ways in: the providers this build signs in with on their own page, then any other
/// mail account with a password. Shared by the start screen and "Add account".
class SignInPanel extends ConsumerStatefulWidget {
  const SignInPanel({super.key, this.onAdded});

  /// Called with the account once it is here (the start screen needs nothing: the app
  /// switches to the mail by itself).
  final void Function(Account account)? onAdded;

  @override
  ConsumerState<SignInPanel> createState() => _SignInPanelState();
}

class _SignInPanelState extends ConsumerState<SignInPanel> {
  /// The provider being signed in with, and whether its page is done (connecting now).
  String? _busy;
  bool _returned = false;
  Problem? _problem;

  /// The provider [_problem] came from.
  String? _failed;

  /// The last Google sign-in was closed: offer the app-password way instead.
  bool _googleClosed = false;

  Future<void> _signIn(String provider) async {
    if (_busy != null) return;
    final repo = ref.read(repositoryProvider);
    final notice = ref.read(noticeProvider.notifier);
    setState(() {
      _busy = provider;
      _returned = false;
      _problem = null;
    });
    try {
      final a = await repo.signIn(
        provider,
        onReturned: () {
          if (mounted) setState(() => _returned = true);
        },
      );
      notice.show('Signed in as ${a.email}');
      widget.onAdded?.call(a);
    } on Problem catch (p) {
      if (!mounted) return;
      setState(() {
        if (p.kind == 'cancelled') {
          _googleClosed = provider == 'google';
        } else {
          _problem = p;
          _failed = provider;
        }
      });
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  void _openOther() =>
      Navigator.of(context)
          .push(phonePage((_) => ProviderPicker(onAdded: widget.onAdded)));

  void _openGmailGuide() => Navigator.of(context).push(
    phonePage(
      (_) => AppPasswordScreen(
        guide: providerGuides['gmail']!,
        onAdded: widget.onAdded,
      ),
    ),
  );

  String _label(String provider) {
    final google = provider == 'google';
    if (_busy != provider) {
      return google ? 'Continue with Google' : 'Sign in with Microsoft';
    }
    if (!kTouch) return 'Finish signing in in your browser…';
    if (_returned) {
      return google ? 'Connecting to Gmail…' : 'Connecting to Outlook…';
    }
    return google ? 'Opening Google…' : 'Opening Microsoft…';
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final providers = ref.read(repositoryProvider).signInProviders();
    final google = providers.contains('google');
    final microsoft = providers.contains('microsoft');
    final any = google || microsoft;
    final problem = _problem;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Above the buttons, so they never move under the thumb.
        AnimatedSize(
          duration: Motion.of(context, Motion.base),
          curve: Motion.curve,
          alignment: Alignment.topCenter,
          child: problem == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _SignInProblem(
                    problem: problem,
                    onRetry: () => setState(() => _problem = null),
                    // Only Google accounts have the app-password way round.
                    onAppPassword:
                        problem.kind == 'admin' && _failed == 'google'
                        ? _openGmailGuide
                        : null,
                  ),
                ),
        ),
        if (google) ...[
          _BrandButton(
            svg: _googleG,
            label: _label('google'),
            busy: _busy == 'google',
            enabled: _busy == null,
            light: const (
              Color(0xFFFFFFFF),
              Color(0xFF747775),
              Color(0xFF1F1F1F),
            ),
            dark: const (
              Color(0xFF131314),
              Color(0xFF8E918F),
              Color(0xFFE3E3E3),
            ),
            onTap: () => _signIn('google'),
          ),
          if (!_googleVerified && _busy == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                'Google will warn that it hasn’t verified Flomsi. Tap Advanced, then Go to Flomsi.',
                style: ui(context, size: 13, color: s.fg2, height: 1.4),
              ),
            ),
          if (_googleClosed && _busy == null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _openGmailGuide,
                child: const Text('Use a Gmail app password instead'),
              ),
            ),
          const SizedBox(height: 12),
        ],
        if (microsoft) ...[
          _BrandButton(
            svg: _microsoft,
            label: _label('microsoft'),
            busy: _busy == 'microsoft',
            enabled: _busy == null,
            light: const (
              Color(0xFFFFFFFF),
              Color(0xFF8C8C8C),
              Color(0xFF5E5E5E),
            ),
            dark: const (
              Color(0xFF2F2F2F),
              Color(0xFF2F2F2F),
              Color(0xFFFFFFFF),
            ),
            onTap: () => _signIn('microsoft'),
          ),
          const SizedBox(height: 12),
        ],
        AnimatedOpacity(
          duration: Motion.of(context, Motion.fast),
          opacity: _busy == null ? 1 : 0.4,
          child: any
              ? OutlinedButton.icon(
                  onPressed: _busy == null ? _openOther : null,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(Touch.button),
                  ),
                  icon: Icon(AppIcons.mail, size: 20),
                  label: const Text('Other email account'),
                )
              : FilledButton.icon(
                  onPressed: _busy == null ? _openOther : null,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(Touch.button),
                  ),
                  icon: Icon(AppIcons.mail, size: 20),
                  label: const Text('Add an email account'),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Text(
            any
                ? 'iCloud, Yandex, Mail.ru, Fastmail or any IMAP server'
                : 'Gmail, iCloud, Yandex, Mail.ru, Fastmail or any IMAP server',
            style: ui(context, size: 13, color: s.fg2, height: 1.4),
          ),
        ),
        // A computer waits on the browser: the wait can be called off here.
        if (_busy != null && !kTouch)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => ref.read(repositoryProvider).cancelSignIn(),
              child: const Text('Cancel'),
            ),
          ),
      ],
    );
  }
}

/// A provider's sign-in button in its own colours (light and dark: fill, outline, text).
class _BrandButton extends StatelessWidget {
  const _BrandButton({
    required this.svg,
    required this.label,
    required this.busy,
    required this.enabled,
    required this.light,
    required this.dark,
    required this.onTap,
  });
  final String svg;
  final String label;
  final bool busy;
  final bool enabled;
  final (Color, Color, Color) light;
  final (Color, Color, Color) dark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (fill, outline, text) = context.s.isDark ? dark : light;
    return AnimatedOpacity(
      duration: Motion.of(context, Motion.fast),
      opacity: enabled || busy ? 1 : 0.4,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: label,
        onTap: enabled ? onTap : null,
        excludeSemantics: true,
        child: Material(
          color: fill,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Touch.radius),
            side: BorderSide(color: outline),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: enabled ? onTap : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: Touch.button),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned(
                    left: 16,
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: busy
                          ? CircularProgressIndicator.adaptive(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation(text),
                            )
                          : SvgPicture.string(svg),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 48,
                      vertical: 12,
                    ),
                    child: AnimatedSwitcher(
                      duration: Motion.of(context, Motion.fast),
                      child: Text(
                        label,
                        key: ValueKey(label),
                        textAlign: TextAlign.center,
                        style: ui(
                          context,
                          size: 15,
                          weight: FontWeight.w500,
                          color: text,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Why a sign-in went nowhere, and what can be done about it.
class _SignInProblem extends StatelessWidget {
  const _SignInProblem({
    required this.problem,
    required this.onRetry,
    this.onAppPassword,
  });
  final Problem problem;
  final VoidCallback onRetry;
  final VoidCallback? onAppPassword;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    // Saying no is a choice, not a failure: no red for it.
    final neutral = problem.kind == 'denied';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (neutral)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(AppIcons.error, size: 18, color: s.fg2),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      problem.title,
                      style: ui(context, size: 15, weight: FontWeight.w600),
                    ),
                    if (problem.hint != null)
                      Text(
                        problem.hint!,
                        style: ui(context, size: 14, color: s.fg2),
                      ),
                  ],
                ),
              ),
            ],
          )
        else
          ProblemNote(problem),
        Wrap(
          spacing: 8,
          children: [
            TextButton(onPressed: onRetry, child: const Text('Try again')),
            if (onAppPassword != null)
              TextButton(
                onPressed: onAppPassword,
                child: const Text('Use an app password'),
              ),
          ],
        ),
      ],
    );
  }
}
