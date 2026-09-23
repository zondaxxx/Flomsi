import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_window_utils/macos_window_utils.dart';

import 'data/mock_repository.dart';
import 'data/repository.dart';
import 'data/rust_repository.dart';
import 'features/notify/new_mail.dart';
import 'features/shell/editor_shell.dart';
import 'features/shell/notice_host.dart';
import 'features/shell/startup_error.dart';
import 'platform.dart';
import 'state/appearance.dart';
import 'state/providers.dart';
import 'theme/tokens.dart';

/// `flutter run --dart-define=MAIL_MOCK=true` keeps the in-memory data for design work.
const _useMock = bool.fromEnvironment('MAIL_MOCK');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // IBM Plex ships under the SIL Open Font License; it shows in the licenses page.
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'IBM Plex',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  if (Platform.isMacOS) {
    // The window chrome is ours: traffic lights sit inside the top bar, no native title.
    await WindowManipulator.initialize();
    await WindowManipulator.makeTitlebarTransparent();
    await WindowManipulator.enableFullSizeContentView();
    await WindowManipulator.hideTitle();
  }
  await _launch();
}

/// Opens the Rust core and runs the app on it. Demo data only with MAIL_MOCK; if the core
/// fails, an error screen says why and offers Retry, instead of a fake mailbox.
Future<void> _launch() async {
  if (_useMock) {
    _run(MockRepository());
    return;
  }
  String? dataDir;
  try {
    dataDir = await RustRepository.defaultDataDir();
    final repo = await RustRepository.open(dataDir: dataDir);
    unawaited(repo.startBackgroundSync());
    _run(repo);
  } catch (e, st) {
    debugPrint('mail core failed to start: $e\n$st');
    runApp(
      StartupErrorApp(error: e.toString(), dataDir: dataDir, onRetry: _launch),
    );
  }
}

void _run(MailRepository repo) {
  final container = ProviderContainer(
    overrides: [repositoryProvider.overrideWithValue(repo)],
  );
  runApp(
    UncontrolledProviderScope(container: container, child: const MailApp()),
  );
  if (repo is RustRepository) unawaited(_announceNewMail(container, repo));
}

/// New mail while Flomsi is not in front becomes a system notification; a tap opens the
/// conversation in the inbox.
Future<void> _announceNewMail(ProviderContainer c, MailRepository repo) async {
  // The shell opens it: selected on a computer, its own page on a phone.
  await MailNotifications.init(
    onOpen: (id) {
      c.read(queryProvider.notifier).set('');
      c.read(openThreadProvider.notifier).open(id);
    },
  );
  await NewMailWatcher(
    repo: repo,
    announce: MailNotifications.announce,
    inFront: () =>
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
  ).start();
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
      // Phones show notices as a pill over every route; desktop uses the status line.
      builder: (context, child) => kTouch
          ? NoticeHost(child: child ?? const SizedBox.shrink())
          : child ?? const SizedBox.shrink(),
      home: const EditorShell(),
    );
  }
}
