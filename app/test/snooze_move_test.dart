import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/list/thread_list.dart';
import 'package:mail_app/features/palette/command_palette.dart';
import 'package:mail_app/features/shell/editor_shell.dart';
import 'package:mail_app/features/thread/snooze.dart';
import 'package:mail_app/state/providers.dart';
import 'package:mail_app/theme/tokens.dart';

void main() {
  group('snooze presets', () {
    test('a weekday morning offers the whole set', () {
      final wed = DateTime(2026, 9, 23, 10, 5); // Wednesday
      final c = snoozeChoices(wed);
      expect(c.map((e) => e.$1), [
        'Later today',
        'Tomorrow',
        'This weekend',
        'Next week',
      ]);
      expect(c[0].$2, DateTime(2026, 9, 23, 18));
      expect(c[1].$2, DateTime(2026, 9, 24, 8));
      expect(c[2].$2, DateTime(2026, 9, 26, 9)); // Saturday
      expect(c[3].$2, DateTime(2026, 9, 28, 8)); // Monday
    });

    test('late on a Saturday skips today and the weekend', () {
      final sat = DateTime(2026, 9, 26, 22, 30);
      final c = snoozeChoices(sat);
      expect(c.map((e) => e.$1), ['Tomorrow', 'Next week']);
      expect(c.last.$2, DateTime(2026, 9, 28, 8));
    });

    test('labels read like a calendar', () {
      final now = DateTime(2026, 9, 23, 10);
      expect(snoozeLabel(DateTime(2026, 9, 23, 18), now), 'today 18:00');
      expect(snoozeLabel(DateTime(2026, 9, 24, 8), now), 'tomorrow 08:00');
      expect(snoozeLabel(DateTime(2026, 9, 26, 9), now), 'Sat 26 Sep 09:00');
    });
  });

  group('thread actions', () {
    late ProviderContainer c;
    setUp(rootBundle.clear);

    Future<void> shell(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      c = ProviderContainer();
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

    Future<List<String>> inbox() async => [
      for (final t in await c.read(repositoryProvider).threads('')) t.subject,
    ];

    Future<void> openThread(WidgetTester tester, String subject) async {
      final t = (await c.read(repositoryProvider).threads(''))
          .firstWhere((t) => t.subject == subject);
      c.read(selectedThreadIdProvider.notifier).select(t.id);
      await tester.pumpAndSettle();
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3)); // notice timer
      await tester.pumpAndSettle();
    }

    testWidgets(
      'snooze hides a thread until its time, unsnooze brings it back',
      (tester) async {
        await shell(tester);
        await openThread(tester, 'Your invoice for September');
        await tester.tap(find.byTooltip('Snooze  h'));
        await tester.pumpAndSettle();
        expect(find.byType(CommandPalette), findsOneWidget);
        expect(find.text('Tomorrow'), findsOneWidget);

        await tester.tap(find.text('Tomorrow'));
        await tester.pumpAndSettle();
        expect(await inbox(), isNot(contains('Your invoice for September')));
        expect(
          c.read(noticeProvider),
          startsWith('Snoozed until tomorrow 08:00'),
        );

        c.read(queryProvider.notifier).set('in:snoozed');
        await tester.pumpAndSettle();
        expect(find.byType(ThreadRow), findsOneWidget);
        expect(find.textContaining('tomorrow 08:00'), findsWidgets);

        await openThread2(tester, c, 'in:snoozed');
        await tester.tap(find.byTooltip('Snoozed  h'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Unsnooze'));
        await tester.pumpAndSettle();
        expect(await inbox(), contains('Your invoice for September'));
        await settle(tester);
      },
    );

    testWidgets('move offers the account folders and takes the thread away', (
      tester,
    ) async {
      await shell(tester);
      await openThread(tester, 'Your invoice for September');
      await tester.tap(find.byTooltip('Move  l'));
      await tester.pumpAndSettle();
      expect(find.text('Receipts'), findsOneWidget);
      final picker = find.byType(CommandPalette);
      // Sent copies never move; the sidebar's own "Sent" does not count.
      expect(
        find.descendant(of: picker, matching: find.text('Sent')),
        findsNothing,
      );

      await tester.tap(find.text('Receipts'));
      await tester.pumpAndSettle();
      expect(await inbox(), isNot(contains('Your invoice for September')));
      expect(c.read(noticeProvider), 'Moved to Receipts');
      await settle(tester);
    });
  });
}

/// Select the only thread listed by [query].
Future<void> openThread2(
  WidgetTester tester,
  ProviderContainer c,
  String query,
) async {
  final t = (await c.read(repositoryProvider).threads(query)).single;
  c.read(selectedThreadIdProvider.notifier).select(t.id);
  await tester.pumpAndSettle();
}
