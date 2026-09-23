import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform.dart';
import '../../state/providers.dart';
import '../../theme/motion.dart';
import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';
import '../phone/phone_shell.dart';
import '../shell/editor_shell.dart';
import 'welcome_screen.dart';

/// What the app opens on: the start screen until there is an account, then the mail.
/// Removing the last account brings the start screen back.
class AppGate extends ConsumerStatefulWidget {
  const AppGate({super.key, this.shell});

  /// The mail screen: the phone layout on phones, the editor elsewhere.
  final Widget? shell;

  @override
  ConsumerState<AppGate> createState() => _AppGateState();
}

class _AppGateState extends ConsumerState<AppGate> {
  /// Which layout was shown last, to notice a window crossing between phone and tablet
  /// sizes (Split View, a foldable).
  bool? _phone;

  /// The other layout takes over: screens pushed over the old one close (a draft keeps
  /// what was typed in it, in Drafts), so the new one starts clean.
  void _switched() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    ref.read(composeProvider.notifier).close();
  });

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final phone = isPhone(context);
    if (_phone != null && _phone != phone) _switched();
    _phone = phone;
    final shell = widget.shell;
    final accounts = ref.watch(accountsProvider);
    final Widget child = switch (accounts) {
      // No "No mail" flash while the list of accounts is read.
      AsyncValue(:final value?) when value.isEmpty => const WelcomeScreen(
        key: ValueKey('welcome'),
      ),
      AsyncValue(value: _?) => KeyedSubtree(
        key: const ValueKey('mail'),
        child: shell ?? (phone ? const PhoneShell() : const EditorShell()),
      ),
      AsyncError(:final error) => Scaffold(
        key: const ValueKey('error'),
        backgroundColor: s.bg,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Couldn’t read the accounts on this device',
                  style: ui(context, size: 17, weight: FontWeight.w500),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  '$error',
                  style: ui(context, size: 14, color: s.fg2),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                SmallButton(
                  label: 'Try again',
                  onPressed: () => ref.invalidate(accountsProvider),
                ),
              ],
            ),
          ),
        ),
      ),
      _ => ColoredBox(key: const ValueKey('loading'), color: s.bg),
    };
    return AnimatedSwitcher(
      duration: Motion.of(context, Motion.base),
      child: child,
    );
  }
}
