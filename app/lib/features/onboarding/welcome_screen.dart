import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'sign_in_panel.dart';

/// The first screen: what Flomsi is, and the ways in. A full screen on a phone, a column
/// in the middle of the window elsewhere.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Scaffold(
      backgroundColor: s.bg,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, c) => SingleChildScrollView(
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: c.maxHeight,
                  maxWidth: 400 + 48,
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
                  child: IntrinsicHeight(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Spacer(flex: 2),
                        Align(
                          alignment: Alignment.centerLeft,
                          // The mark is a dark tile: on the dark page a hairline
                          // keeps its edge.
                          child: DecoratedBox(
                            position: DecorationPosition.foreground,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: s.isDark
                                    ? s.fg3.withValues(alpha: 0.5)
                                    : Colors.transparent,
                              ),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.asset(
                                'assets/brand/flomsi_mark.png',
                                width: 56,
                                height: 56,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'Flomsi',
                          style: ui(
                            context,
                            size: 30,
                            weight: FontWeight.w600,
                            letterSpacing: -0.4,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Your mail, straight from your provider. No Flomsi server in between.',
                          style: ui(
                            context,
                            size: 16,
                            color: s.fg2,
                            height: 1.4,
                          ),
                        ),
                        const Spacer(flex: 3),
                        const SizedBox(height: 32),
                        const SignInPanel(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
