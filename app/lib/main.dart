import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_window_utils/macos_window_utils.dart';

import 'data/mock_repository.dart';
import 'data/repository.dart';
import 'data/rust_repository.dart';
import 'features/shell/editor_shell.dart';
import 'state/appearance.dart';
import 'state/providers.dart';
import 'theme/tokens.dart';

/// `flutter run --dart-define=MAIL_MOCK=true` keeps the in-memory data for design work.
const _useMock = bool.fromEnvironment('MAIL_MOCK');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isMacOS) {
    // The window chrome is ours: traffic lights sit inside the top bar, no native title.
    await WindowManipulator.initialize();
    await WindowManipulator.makeTitlebarTransparent();
    await WindowManipulator.enableFullSizeContentView();
    await WindowManipulator.hideTitle();
  }
  MailRepository repo;
  if (_useMock) {
    repo = MockRepository();
  } else {
    try {
      repo = await RustRepository.open();
    } catch (e, st) {
      debugPrint('rust core unavailable, falling back to mock: $e\n$st');
      repo = MockRepository();
    }
  }
  runApp(
    ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(repo)],
      child: const MailApp(),
    ),
  );
}

class MailApp extends ConsumerWidget {
  const MailApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(appearanceProvider);
    return MaterialApp(
      title: 'Flomsi',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Scheme.light),
      darkTheme: buildTheme(Scheme.dark),
      themeMode: mode,
      home: const EditorShell(),
    );
  }
}
