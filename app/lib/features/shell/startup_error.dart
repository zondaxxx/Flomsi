import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';

/// Shown when the mail core cannot start. There is no silent fallback to demo data: a
/// fake mailbox that "sends" nothing is worse than an honest error.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({
    super.key,
    required this.error,
    required this.dataDir,
    required this.onRetry,
  });
  final String error;
  final String? dataDir;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Flomsi',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(Scheme.light),
    darkTheme: buildTheme(Scheme.dark),
    themeMode: ThemeMode.dark,
    home: StartupErrorScreen(error: error, dataDir: dataDir, onRetry: onRetry),
  );
}

class StartupErrorScreen extends StatefulWidget {
  const StartupErrorScreen({
    super.key,
    required this.error,
    required this.dataDir,
    required this.onRetry,
  });
  final String error;
  final String? dataDir;
  final Future<void> Function() onRetry;

  @override
  State<StartupErrorScreen> createState() => _StartupErrorScreenState();
}

class _StartupErrorScreenState extends State<StartupErrorScreen> {
  bool _retrying = false;

  Future<void> _retry() async {
    setState(() => _retrying = true);
    try {
      await widget.onRetry();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final details = [
      widget.error,
      if (widget.dataDir != null) 'data: ${widget.dataDir}',
    ].join('\n');
    return Scaffold(
      backgroundColor: s.bg,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Flomsi could not open its mail database',
                  style: ui(context, size: 16, weight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
                Text(
                  'Nothing was sent or changed. Retry after fixing the cause below, '
                  'for example free disk space or folder permissions.',
                  style: ui(context, color: s.fg2),
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: s.bg2,
                    border: Border.all(color: s.border),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SelectableText(
                    details,
                    style: mono(context, size: 12, color: s.red),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    SmallButton(
                      label: _retrying ? 'Retrying…' : 'Retry',
                      primary: true,
                      height: 30,
                      onPressed: _retrying ? null : _retry,
                    ),
                    const SizedBox(width: 8),
                    SmallButton(
                      label: 'Copy details',
                      height: 30,
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: details)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
