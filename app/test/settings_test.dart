import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/settings/settings_sheet.dart';
import 'package:mail_app/state/appearance.dart';
import 'package:mail_app/state/providers.dart';
import 'package:mail_app/theme/tokens.dart';

void main() {
  late ProviderContainer c;

  // rootBundle caches load futures; one started in an earlier test's fake clock never
  // completes in the next test, so start each test with an empty cache.
  setUp(rootBundle.clear);

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(
      1280,
      1800,
    ); // the whole sheet, no scrolling
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
  }

  /// Keymaps come from the asset bundle, which answers with real I/O: give it real time,
  /// then pump until the provider has a value.
  Future<void> loadKeymap(WidgetTester tester) async {
    for (var i = 0; i < 50 && !c.read(keymapProvider).hasValue; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5)); // notices and confirm timers
    await tester.pumpAndSettle();
  }

  testWidgets('profiles save on demand', (tester) async {
    await open(tester);
    expect(find.byType(SettingsSheet), findsOneWidget);
    expect(c.read(scopeProvider), 'dialog');
    expect(find.text('dev@gmail.com'), findsOneWidget);
    expect(find.text('IMAP imap.gmail.com:993'), findsOneWidget);

    final nameField = find.widgetWithText(TextField, 'Zonda');
    await tester.enterText(nameField, 'Zonda Dev');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save').first);
    await tester.pumpAndSettle();
    final account = (await c.read(repositoryProvider).accounts()).first;
    expect(account.displayName, 'Zonda Dev');
    expect(account.signature, 'Zonda\nflomsi.dev');
    expect(c.read(noticeProvider), 'Saved dev@gmail.com');
    await settle(tester);
  });

  testWidgets('removing an account takes a second, explicit click', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('Remove…').last);
    await tester.pumpAndSettle();
    expect((await c.read(repositoryProvider).accounts()).length, 3);
    await tester.tap(find.text('Remove account and its mail here'));
    await tester.pumpAndSettle();
    final left = await c.read(repositoryProvider).accounts();
    expect(left.map((a) => a.email), ['dev@gmail.com', 'me@icloud.com']);
    expect(find.text('work@outlook.com'), findsNothing);
    await settle(tester);
  });

  testWidgets('key preset and theme are stored', (tester) async {
    await open(tester);
    await loadKeymap(tester);
    expect(find.textContaining('archive e'), findsOneWidget);

    await tester.tap(find.text('gmail'));
    await tester.pumpAndSettle();
    expect(await c.read(repositoryProvider).setting('keymap'), 'gmail');
    await loadKeymap(tester);
    expect(c.read(keymapProvider).value?.name, 'gmail');
    expect(find.textContaining('archive '), findsOneWidget);

    await tester.tap(find.text('light'));
    await tester.pumpAndSettle();
    expect(c.read(appearanceProvider), ThemeMode.light);
    expect(await c.read(repositoryProvider).setting('theme'), 'light');

    await tester.tapAt(const Offset(4, 4)); // outside the sheet
    await tester.pumpAndSettle();
    expect(find.byType(SettingsSheet), findsNothing);
    expect(c.read(scopeProvider), 'list');
  });
}
