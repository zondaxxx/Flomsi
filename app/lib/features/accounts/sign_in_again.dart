import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../state/providers.dart';
import '../settings/settings_sheet.dart';

/// Sign an account in again on its provider's page (Google, Microsoft), keeping its mail;
/// its sync picks up where it stopped.
Future<void> signInAgain(BuildContext context, WidgetRef ref, Account a) async {
  final provider = a.signInProvider;
  if (provider == null) return;
  final notice = ref.read(noticeProvider.notifier);
  try {
    final b = await ref
        .read(repositoryProvider)
        .signIn(provider, loginHint: a.email);
    notice.show('Signed in as ${b.email}');
  } on Problem catch (p) {
    if (p.kind != 'cancelled') notice.show(p.title, error: true);
  }
}

/// Where a password account gets its new password typed in.
Future<void> openPasswordEntry(BuildContext context, Account a) =>
    showSettingsSheet(context);
