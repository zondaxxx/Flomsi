import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../platform.dart';
import '../../state/providers.dart';
import '../../theme/app_icons.dart';
import '../../theme/tokens.dart';
import '../accounts/provider_guides.dart';
import '../phone/phone_route.dart';
import 'app_password_screen.dart';
import 'manual_server_screen.dart';

/// "Other email account": the providers that let mail apps in with an app password, each
/// with its steps, then any server by hand.
class ProviderPicker extends ConsumerWidget {
  const ProviderPicker({super.key, this.onAdded});
  final void Function(Account account)? onAdded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final providers = ref.read(repositoryProvider).signInProviders();
    final microsoft = providers.contains('microsoft');
    final google = providers.contains('google');
    void guide(String id) => Navigator.of(context).push(
      phonePage(
        (_) => AppPasswordScreen(guide: providerGuides[id]!, onAdded: onAdded),
      ),
    );
    Future<void> microsoftSignIn() async {
      final notice = ref.read(noticeProvider.notifier);
      try {
        final a = await ref.read(repositoryProvider).signIn('microsoft');
        notice.show('Signed in as ${a.email}');
        onAdded?.call(a);
        if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
      } on Problem catch (p) {
        if (p.kind != 'cancelled') notice.show(p.title, error: true);
      }
    }

    final rows = <Widget>[
      _Row(
        title: 'iCloud Mail',
        subtitle: 'App-specific password',
        onTap: () => guide('icloud'),
      ),
      _Row(
        title: 'Yandex Mail',
        subtitle: 'App password',
        onTap: () => guide('yandex'),
      ),
      _Row(
        title: 'Mail.ru',
        subtitle: 'Password for external apps',
        onTap: () => guide('mailru'),
      ),
      _Row(
        title: 'Fastmail',
        subtitle: 'App password',
        onTap: () => guide('fastmail'),
      ),
      _Row(
        title: 'Outlook, Hotmail, Microsoft 365',
        subtitle: microsoft
            ? 'Sign in with Microsoft'
            : 'Needs Microsoft sign-in, which this version doesn’t include',
        onTap: microsoft ? microsoftSignIn : null,
      ),
      _Row(
        title: google ? 'Gmail with an app password' : 'Gmail',
        subtitle: google
            ? 'Only if Google sign-in can’t be used'
            : 'App password',
        onTap: () => guide('gmail'),
      ),
      _Row(
        title: 'Proton Mail',
        subtitle: kTouch
            ? 'Needs Proton Mail Bridge, which runs only on a computer'
            : 'Through Proton Mail Bridge on this computer',
        onTap: kTouch
            ? null
            : () => Navigator.of(context).push(
                phonePage(
                  (_) => ManualServerScreen(onAdded: onAdded, proton: true),
                ),
              ),
      ),
      _Row(
        title: 'Other mail server',
        subtitle: 'Enter the IMAP and SMTP details',
        onTap: () =>
            Navigator.of(context)
                .push(phonePage((_) => ManualServerScreen(onAdded: onAdded))),
      ),
    ];
    return Scaffold(
      backgroundColor: s.bg,
      appBar: AppBar(
        backgroundColor: s.bg,
        surfaceTintColor: Colors.transparent,
        title: Text(
          'Other email account',
          style: ui(context, size: 17, weight: FontWeight.w600),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              children: [
                for (final r in rows) ...[
                  r,
                  Divider(height: 1, indent: 16, color: s.border),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  child: Text(
                    'Most providers let mail apps in with an app password: a separate password you create in your account’s security settings.',
                    style: ui(context, size: 13, color: s.fg2, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.title, required this.subtitle, this.onTap});
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final enabled = onTap != null;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 60),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: ui(
                        context,
                        size: 16,
                        weight: FontWeight.w500,
                        color: enabled ? s.fg : s.fg3,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: ui(
                        context,
                        size: 14,
                        color: enabled ? s.fg2 : s.fg3,
                      ),
                    ),
                  ],
                ),
              ),
              if (enabled) Icon(AppIcons.chevron, size: 18, color: s.fg3),
            ],
          ),
        ),
      ),
    );
  }
}
