import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/mock_repository.dart';
import 'package:mail_app/features/onboarding/app_gate.dart';
import 'package:mail_app/features/phone/phone_shell.dart';
import 'package:mail_app/features/phone/phone_thread_screen.dart';
import 'package:mail_app/platform.dart';
import 'package:mail_app/state/providers.dart';
import 'package:mail_app/theme/tokens.dart';

void main() {
  late ProviderContainer c;
  late MockRepository repo;
  setUp(rootBundle.clear);
  tearDown(() => debugTouchOverride = null);

  Future<void> start(WidgetTester tester) async {
    debugTouchOverride = true;
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    repo = MockRepository();
    c = ProviderContainer(
      overrides: [repositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildTheme(Scheme.dark),
          home: const AppGate(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The title block's second line.
  Finder line2(String text) => find.textContaining(text);

  testWidgets(
    'a phone gets the phone layout: title, account line, button bar',
    (tester) async {
      await start(tester);
      expect(find.byType(PhoneShell), findsOneWidget);
      expect(find.text('Inbox'), findsOneWidget);
      expect(line2('All accounts'), findsOneWidget);
      for (final b in ['Mailboxes', 'Search', 'Unread', 'Compose']) {
        expect(find.text(b), findsOneWidget, reason: b);
      }
      expect(find.text('Top stories this week'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets('Unread narrows the mailbox and says so; again shows all', (
    tester,
  ) async {
    await start(tester);
    await tester.tap(find.text('Unread'));
    await tester.pumpAndSettle();
    expect(c.read(queryProvider), 'is:unread');
    expect(find.text('Inbox'), findsOneWidget);
    expect(line2('Unread only · All accounts'), findsOneWidget);
    // Read mail is gone from the list.
    expect(find.text('Top stories this week'), findsNothing);
    await tester.tap(find.text('Unread'));
    await tester.pumpAndSettle();
    expect(c.read(queryProvider), '');
    expect(find.text('Top stories this week'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets(
    'the account menu narrows to one account, Mailboxes keeps it, back goes to its Inbox',
    (tester) async {
      await start(tester);
      await tester.tap(line2('All accounts'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('me@icloud.com').last);
      await tester.pumpAndSettle();
      expect(c.read(queryProvider), 'account:me@icloud.com');
      expect(line2('me@icloud.com'), findsOneWidget);
      expect(find.text('Lunch next week?'), findsOneWidget);
      expect(find.text('Top stories this week'), findsNothing);

      await tester.tap(find.text('Mailboxes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sent'));
      await tester.pumpAndSettle();
      expect(c.read(queryProvider), 'account:me@icloud.com in:sent');
      expect(find.text('Sent'), findsOneWidget);

      // Back: the account's Inbox, not out of the app.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(c.read(queryProvider), 'account:me@icloud.com');
      expect(find.byType(PhoneShell), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets('swiping archives with Undo; left alone, it is filed', (
    tester,
  ) async {
    await start(tester);
    const subject = 'Top stories this week';
    await tester.drag(find.text(subject), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(find.text(subject), findsNothing);
    final notice = c.read(noticeProvider.notifier).current!;
    expect(notice.text, 'Archived');
    expect(notice.action, 'Undo');
    // Nothing has reached the repository yet.
    expect((await repo.threads('')).any((t) => t.subject == subject), isTrue);

    notice.onAction!();
    await tester.pumpAndSettle();
    expect(find.text(subject), findsOneWidget);

    await tester.drag(find.text(subject), const Offset(300, 0));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect((await repo.threads('')).any((t) => t.subject == subject), isFalse);
    expect(find.text(subject), findsNothing);
  });

  testWidgets('long press: a menu of actions; Move to goes through a sheet', (
    tester,
  ) async {
    await start(tester);
    const subject = 'Your invoice for September';
    await tester.longPress(find.text(subject));
    await tester.pumpAndSettle();
    for (final item in ['Reply', 'Forward', 'Archive', 'Delete', 'Move to…']) {
      expect(find.text(item), findsOneWidget, reason: item);
    }
    await tester.tap(find.text('Move to…'));
    await tester.pumpAndSettle();
    expect(find.text('Move to'), findsOneWidget);
    await tester.tap(find.text('Receipts'));
    await tester.pumpAndSettle();
    expect(find.text(subject), findsNothing);
    expect(c.read(noticeProvider), 'Moved to Receipts');
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect((await repo.threads('')).any((t) => t.subject == subject), isFalse);
  });

  testWidgets(
    'search: examples first, then what this phone has; back leaves it',
    (tester) async {
      await start(tester);
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();
      expect(find.text('Search mail'), findsOneWidget);
      expect(find.text('from:anna'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'invoice');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.text('On this phone'), findsOneWidget);
      expect(find.text('Your invoice for September'), findsOneWidget);
      expect(find.text('Top stories this week'), findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Search mail'), findsNothing);
      expect(c.read(queryProvider), '');
      expect(find.text('Top stories this week'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets('a tapped notification opens its conversation over the Inbox', (
    tester,
  ) async {
    await start(tester);
    await tester.tap(find.text('Mailboxes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sent'));
    await tester.pumpAndSettle();
    c.read(openThreadProvider.notifier).open(2);
    await tester.pumpAndSettle();
    expect(find.byType(PhoneThreadScreen), findsOneWidget);
    expect(c.read(queryProvider), '');
    expect(c.read(selectedThreadIdProvider), 2);
    await tester.pump(const Duration(seconds: 3));
  });
}
