import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../theme/tokens.dart';
import 'sign_in_panel.dart';

/// "Add account" once there is mail: the start screen's ways in, under a title.
class AccountSetupScreen extends StatelessWidget {
  const AccountSetupScreen({super.key, this.onAdded});

  /// Called with the new account once this screen has closed.
  final void Function(Account account)? onAdded;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Scaffold(
      backgroundColor: s.bg,
      appBar: AppBar(
        backgroundColor: s.bg,
        surfaceTintColor: Colors.transparent,
        title: Text(
          'Add account',
          style: ui(context, size: 17, weight: FontWeight.w600),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 448),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              children: [
                SignInPanel(
                  onAdded: (a) {
                    if (context.mounted) {
                      Navigator.of(context).popUntil((r) => r.isFirst);
                    }
                    onAdded?.call(a);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
