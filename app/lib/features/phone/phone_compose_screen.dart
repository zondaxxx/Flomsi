import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../compose/compose_body.dart';
import 'phone_route.dart';

/// The composer as a screen of its own. However it goes (Send, close, Android's back),
/// the compose state goes with it, so the next new message opens.
Future<void> openPhoneCompose(BuildContext context, WidgetRef ref) async {
  await Navigator.of(context)
      .push(phoneModal((_) => const PhoneComposeScreen()));
  if (context.mounted) ref.read(composeProvider.notifier).close();
}

class PhoneComposeScreen extends ConsumerWidget {
  const PhoneComposeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<Draft?>(composeProvider, (prev, next) {
      if (next == null && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
    final draft = ref.watch(composeProvider);
    return Scaffold(
      backgroundColor: context.s.bg,
      body: SafeArea(
        child: draft == null
            ? const SizedBox.shrink()
            : ComposeBody(
                key: ValueKey(draft.hashCode),
                draft: draft,
                compact: true,
              ),
      ),
    );
  }
}
