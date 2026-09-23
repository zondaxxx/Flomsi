import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/tokens.dart';
import '../thread/thread_view.dart';

/// A conversation on its own page.
class PhoneThreadScreen extends ConsumerWidget {
  const PhoneThreadScreen({super.key, required this.threadId});
  final int threadId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    backgroundColor: context.s.bg,
    body: SafeArea(
      child: ThreadBody(
        compact: true,
        onBack: () => Navigator.of(context).maybePop(),
      ),
    ),
  );
}
