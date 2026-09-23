import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/mock_repository.dart';
import 'package:mail_app/features/accounts/add_account_sheet.dart';
import 'package:mail_app/features/accounts/problem_note.dart';
import 'package:mail_app/state/providers.dart';
import 'package:mail_app/theme/tokens.dart';

void main() {
  late ProviderContainer c;
  setUp(rootBundle.clear);

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(1280, 820),
  }) async {
    tester.view.physicalSize = size;
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
                onPressed: () => showAddAccountSheet(context),
                child: const Text('add'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('add'));
    await tester.pumpAndSettle();
  }

  Finder field(String hint) => find.widgetWithText(TextField, hint);

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3)); // notice timer
    await tester.pumpAndSettle();
  }

  testWidgets('the add-account sheet owns the dialog scope and gives it back', (
    tester,
  ) async {
    await open(tester);
    expect(find.byType(AddAccountSheet), findsOneWidget);
    expect(c.read(scopeProvider), 'dialog');

    await tester.tapAt(const Offset(8, 8)); // the barrier
    await tester.pumpAndSettle();
    expect(find.byType(AddAccountSheet), findsNothing);
    expect(c.read(scopeProvider), 'list');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a known address fills both servers and says what password to use',
    (tester) async {
      await open(tester);
      await tester.enterText(field('you@example.com'), 'me@yandex.ru');
      await tester.pumpAndSettle();
      expect(
        find.text('IMAP imap.yandex.ru:993 · SMTP smtp.yandex.ru:465'),
        findsOneWidget,
      );
      expect(find.textContaining('id.yandex.ru'), findsOneWidget);

      // Mail.ru family and the Apple and Microsoft aliases are known too.
      await tester.enterText(field('me@yandex.ru'), 'z@bk.ru');
      await tester.pumpAndSettle();
      expect(find.textContaining('smtp.mail.ru:465'), findsOneWidget);
      await tester.enterText(field('z@bk.ru'), 'z@live.com');
      await tester.pumpAndSettle();
      expect(find.textContaining('most likely be refused'), findsOneWidget);

      // Anything else gets a guess the person can see and change.
      await tester.enterText(field('z@live.com'), 'z@example.org');
      await tester.pumpAndSettle();
      expect(
        find.text(
          'IMAP imap.example.org:993 · SMTP smtp.example.org:587 STARTTLS',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('Proton goes through the bridge on this computer with STARTTLS', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(field('you@example.com'), 'z@proton.me');
    await tester.pumpAndSettle();
    expect(
      find.text('IMAP 127.0.0.1:1143 STARTTLS · SMTP 127.0.0.1:1025 STARTTLS'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Proton Bridge must be running'),
      findsOneWidget,
    );
    await tester.tap(find.text('Servers'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('its own certificate is accepted'),
      findsOneWidget,
    );
    // Typing a remote server by hand turns the bridge trust off.
    await tester.enterText(
      find.widgetWithText(TextField, '127.0.0.1').first,
      'imap.example.org',
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('its own certificate is accepted'),
      findsNothing,
    );
  });

  testWidgets(
    'a refused password is explained, the right one adds the account',
    (tester) async {
      await open(tester);
      await tester.enterText(field('you@example.com'), 'new@fastmail.com');
      await tester.enterText(field('App password'), 'my-login-password');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(find.byType(ProblemNote), findsOneWidget);
      expect(
        find.text('Incoming server: The server rejected the name or password'),
        findsOneWidget,
      );
      expect(find.textContaining('app password for mail apps'), findsOneWidget);
      // The server's own words are one click away.
      await tester.tap(find.text('Server reply'));
      await tester.pumpAndSettle();
      expect(find.textContaining('AUTHENTICATIONFAILED'), findsOneWidget);
      expect((await c.read(repositoryProvider).accounts()).length, 3);

      await tester.enterText(
        field('my-login-password'),
        MockRepository.goodPassword,
      );
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(find.byType(AddAccountSheet), findsNothing);
      final emails = [
        for (final a in await c.read(repositoryProvider).accounts()) a.email,
      ];
      expect(emails, contains('new@fastmail.com'));
      expect(c.read(noticeProvider), 'Added new@fastmail.com');
      await settle(tester);
    },
  );

  testWidgets(
    'a blocked SMTP port can be skipped, but only for what was checked',
    (tester) async {
      await open(tester);
      await tester.enterText(field('you@example.com'), 'me@example.org');
      await tester.enterText(
        field('App password'),
        MockRepository.goodPassword,
      );
      await tester.tap(find.text('Servers'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'smtp.example.org'),
        'blocked.example.org',
      );
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(
        find.text('Outgoing server: Nothing answers on that port'),
        findsOneWidget,
      );
      expect(find.text('Add anyway'), findsOneWidget);

      // Changing anything means the check no longer covers it.
      await tester.enterText(
        find.widgetWithText(TextField, MockRepository.goodPassword),
        'another',
      );
      await tester.pumpAndSettle();
      expect(find.text('Add anyway'), findsNothing);
      await tester.enterText(
        find.widgetWithText(TextField, 'another'),
        MockRepository.goodPassword,
      );
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add anyway'));
      await tester.pumpAndSettle();
      expect(find.byType(AddAccountSheet), findsNothing);
      expect([
        for (final a in await c.read(repositoryProvider).accounts()) a.email,
      ], contains('me@example.org'));
      await settle(tester);
    },
  );

  testWidgets('Microsoft country domains get the Outlook note', (tester) async {
    await open(tester);
    await tester.enterText(field('you@example.com'), 'z@hotmail.co.uk');
    await tester.pumpAndSettle();
    expect(find.textContaining('most likely be refused'), findsOneWidget);
    expect(find.textContaining('outlook.office365.com:993'), findsOneWidget);
  });

  testWidgets('adding an address twice is refused and keeps the first', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(field('you@example.com'), 'Dev@Gmail.com');
    await tester.enterText(field('App password'), MockRepository.goodPassword);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('This address is already added'), findsOneWidget);
    expect(find.byType(AddAccountSheet), findsOneWidget);
    expect((await c.read(repositoryProvider).accounts()).length, 3);
  });

  testWidgets('empty fields are named before anything goes to a server', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Enter the full address, name@domain'), findsOneWidget);
    await tester.enterText(field('you@example.com'), 'z@example.org');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Enter the password'), findsOneWidget);
  });

  testWidgets('on a phone the sheet stays above the keyboard', (tester) async {
    await open(tester, size: const Size(390, 844));
    tester.view.viewInsets = const FakeViewPadding(bottom: 336);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'you@example.com'),
      'z@example.org',
    );
    await tester.tap(find.text('Servers'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final sheet = tester.getRect(find.byType(AddAccountSheet));
    expect(sheet.width, lessThanOrEqualTo(390 - 32));
    // The Add button can be scrolled above the keyboard.
    await tester.scrollUntilVisible(
      find.text('Add').last,
      100,
      scrollable: find
          .ancestor(
            of: find.byType(AddAccountSheet),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(
      tester.getRect(find.text('Add').last).bottom,
      lessThanOrEqualTo(844 - 336),
    );
  });
}
