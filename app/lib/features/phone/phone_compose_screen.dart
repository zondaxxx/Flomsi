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

/// Close, Send and Discard end the draft first; the page follows by itself.
class PhoneComposeScreen extends ConsumerStatefulWidget {
  const PhoneComposeScreen({super.key});

  @override
  ConsumerState<PhoneComposeScreen> createState() => _PhoneComposeScreenState();
}

class _PhoneComposeScreenState extends ConsumerState<PhoneComposeScreen> {
  /// The draft on screen, kept while the page slides away after the state has cleared,
  /// so it does not go blank on the way out.
  Draft? _shown;

  @override
  Widget build(BuildContext context) {
    ref.listen<Draft?>(composeProvider, (prev, next) {
      // Only this page goes, and only once: not one already on its way out, and not
      // a page opened over it.
      final route = ModalRoute.of(context);
      if (next != null || route == null || !route.isActive || route.isFirst) {
        return;
      }
      final nav = Navigator.of(context);
      // A question the page asked (Discard?) goes with it.
      nav.popUntil((r) => r == route || r is! PopupRoute);
      if (route.isCurrent) {
        nav.pop();
      } else {
        nav.removeRoute(route);
      }
    });
    final draft = _shown = ref.watch(composeProvider) ?? _shown;
    return Scaffold(
      backgroundColor: context.s.bg,
      body: draft == null
          ? const SizedBox.shrink()
          : ComposeBody(
              key: ValueKey(draft.hashCode),
              draft: draft,
              phone: true,
            ),
    );
  }
}
