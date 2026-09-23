import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/mock_repository.dart';
import 'package:mail_app/data/models.dart';
import 'package:mail_app/features/list/thread_list.dart';
import 'package:mail_app/features/settings/settings_sheet.dart';
import 'package:mail_app/features/shell/editor_shell.dart';
import 'package:mail_app/state/providers.dart';
import 'package:mail_app/theme/tokens.dart';

/// A fresh install: no accounts, no mail.
class _Empty extends MockRepository {
  @override
  Future<List<Account>> accounts() async => const [];
  @override
  Future<List<Thread>> threads(String query, {int limit = 100}) async =>
      const [];
}

const _gmailRefused = Problem(
  kind: 'auth',
  title: 'Gmail needs an app password',
  hint: 'Create an app password at myaccount.google.com/apppasswords.',
  detail: 'auth: NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)',
);

void main() {
  late ProviderContainer c;
  setUp(rootBundle.clear);

  Future<void> shell(WidgetTester tester, {MockRepository? repo}) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    c = ProviderContainer(
      overrides: [if (repo != null) repositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildTheme(Scheme.dark),
          home: const EditorShell(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3)); // notice timer
    await tester.pumpAndSettle();
  }

  testWidgets('a fresh install says there are no accounts and offers one', (
    tester,
  ) async {
    await shell(tester, repo: _Empty());
    expect(find.byType(FirstRun), findsOneWidget);
    expect(find.text('No accounts yet'), findsOneWidget);
    expect(find.textContaining('app password'), findsOneWidget);
    expect(find.text('no accounts'), findsOneWidget);
    expect(find.textContaining('synced'), findsNothing);

    await tester.tap(find.text('Add account').last);
    await tester.pumpAndSettle();
    expect(find.text('Add Account'), findsOneWidget);
  });

  testWidgets('the status line never shows a sync that did not happen', (
    tester,
  ) async {
    await shell(tester);
    expect(find.text('not synced yet'), findsOneWidget);
    // The mock sync waits on the test clock: start it, then let the clock run.
    final done = c.read(repositoryProvider).sync();
    await tester.pump(const Duration(seconds: 1));
    await done;
    await tester.pumpAndSettle();
    expect(find.textContaining(RegExp(r'^synced \d\d:\d\d$')), findsOneWidget);
  });

  testWidgets('a refused password parks the account until a new one works', (
    tester,
  ) async {
    final repo = MockRepository();
    await shell(tester, repo: repo);
    repo.failSignIn(1, _gmailRefused);
    await tester.pumpAndSettle();

    // Said where it matters: the list, the sidebar and the status line.
    expect(
      find.text('dev@gmail.com: Gmail needs an app password'),
      findsOneWidget,
    );
    expect(
      find.byTooltip('Needs password: Gmail needs an app password'),
      findsOneWidget,
    );
    expect(find.text('sign-in needed'), findsOneWidget);

    await tester.tap(find.text('Enter password'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsSheet), findsOneWidget);
    expect(find.text('needs password'), findsOneWidget);
    expect(find.textContaining('Syncing is paused'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'New app password'),
      'still-wrong',
    );
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(
      find.text('The server rejected the name or password'),
      findsOneWidget,
    );
    expect(repo.problems.containsKey(1), isTrue);

    await tester.enterText(
      find.widgetWithText(TextField, 'still-wrong'),
      MockRepository.goodPassword,
    );
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(repo.problems, isEmpty);
    expect(find.text('needs password'), findsNothing);
    expect(c.read(noticeProvider), 'Signed in to dev@gmail.com');
    await settle(tester);
  });

  testWidgets('a removed account takes its sign-in problem with it', (
    tester,
  ) async {
    final repo = MockRepository();
    await shell(tester, repo: repo);
    repo.failSignIn(3, _gmailRefused);
    await tester.pumpAndSettle();
    expect(find.text('sign-in needed'), findsOneWidget);
    await repo.removeAccount(3);
    await tester.pumpAndSettle();
    expect(repo.problems, isEmpty);
    expect(find.text('sign-in needed'), findsNothing);
    expect(find.textContaining('work@outlook.com:'), findsNothing);
  });

  testWidgets('any account can take a new password without being removed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildTheme(Scheme.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showSettingsSheet(context),
                child: const Text('settings'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('settings'));
    await tester.pumpAndSettle();
    expect(find.text('IMAP imap.gmail.com:993'), findsOneWidget);

    await tester.tap(find.text('Password…').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'New password'),
      MockRepository.goodPassword,
    );
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(c.read(noticeProvider), 'Signed in to dev@gmail.com');
    expect(find.widgetWithText(TextField, 'New password'), findsNothing);
    expect((await c.read(repositoryProvider).accounts()).length, 3);
    await settle(tester);
  });
}
