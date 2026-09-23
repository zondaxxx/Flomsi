import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/mock_repository.dart';
import 'package:mail_app/data/models.dart';
import 'package:mail_app/features/accounts/sign_in_again.dart';
import 'package:mail_app/features/onboarding/account_setup_screen.dart';
import 'package:mail_app/features/onboarding/app_gate.dart';
import 'package:mail_app/features/onboarding/welcome_screen.dart';
import 'package:mail_app/features/settings/phone_settings.dart';
import 'package:mail_app/features/settings/settings_sheet.dart';
import 'package:mail_app/platform.dart';
import 'package:mail_app/state/appearance.dart';
import 'package:mail_app/state/providers.dart';
import 'package:mail_app/theme/app_icons.dart';
import 'package:mail_app/theme/tokens.dart';

/// The mock's first account signs in with Google instead of a password.
class _GoogleRepo extends MockRepository {
  @override
  Future<List<Account>> accounts() async => [
    for (final a in await super.accounts())
      a.id != 1
          ? a
          : Account(
              id: a.id,
              email: a.email,
              kind: a.kind,
              color: a.color,
              unread: a.unread,
              displayName: a.displayName,
              signature: a.signature,
              server: a.server,
              problem: a.problem,
              auth: 'xoauth2',
            ),
  ];
}

/// Removing an account takes as long as the test says, and is counted.
class _SlowRemoveRepo extends MockRepository {
  final gate = Completer<void>();
  int removals = 0;

  @override
  Future<void> removeAccount(int id) async {
    removals++;
    await gate.future;
    await super.removeAccount(id);
  }
}

const _refused = Problem(
  kind: 'auth',
  title: 'Gmail needs an app password',
  hint: 'Create an app password at myaccount.google.com/apppasswords.',
  detail: 'auth: NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)',
);

/// Stands in for the mail screen: the two ways into account settings.
class _Mail extends ConsumerWidget {
  const _Mail();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: () => showSettingsSheet(context),
            child: const Text('open settings'),
          ),
          TextButton(
            onPressed: () => openPasswordEntry(
              context,
              ref.read(accountsProvider).value!.first,
            ),
            child: const Text('enter password'),
          ),
        ],
      ),
    ),
  );
}

void main() {
  late ProviderContainer c;
  late MockRepository repo;
  setUp(rootBundle.clear);
  tearDown(() => debugTouchOverride = null);

  Future<void> start(
    WidgetTester tester, {
    MockRepository? using,
    Size size = const Size(390, 844),
    double scale = 1,
  }) async {
    debugTouchOverride = true;
    tester.view.physicalSize = size * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    repo = using ?? MockRepository();
    c = ProviderContainer(
      overrides: [repositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildTheme(Scheme.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const AppGate(shell: _Mail()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.text('open settings'));
    await tester.pumpAndSettle();
  }

  Future<void> openAccount(WidgetTester tester, String email) async {
    await openSettings(tester);
    await tester.tap(find.text(email));
    await tester.pumpAndSettle();
    expect(find.byType(AccountDetailScreen), findsOneWidget);
  }

  /// The password field: the last one on the account screen.
  Finder passwordField() => find
      .descendant(
        of: find.byType(AccountDetailScreen),
        matching: find.byType(TextField),
      )
      .last;

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 9)); // notice timers
    await tester.pumpAndSettle();
  }

  testWidgets(
    'on a phone Settings is a screen: accounts, theme, about, no key presets',
    (tester) async {
      await start(tester);
      await openSettings(tester);
      expect(find.byType(PhoneSettingsScreen), findsOneWidget);
      expect(find.byType(SettingsSheet), findsNothing);
      // The bar's colour runs up under a see-through status bar.
      final bar = tester.widget<AppBar>(
        find.descendant(
          of: find.byType(PhoneSettingsScreen),
          matching: find.byType(AppBar),
        ),
      );
      expect(bar.systemOverlayStyle?.statusBarColor, Colors.transparent);
      expect(bar.systemOverlayStyle?.systemNavigationBarColor, Scheme.dark.bg2);
      for (final t in ['Accounts', 'Appearance', 'About']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      expect(find.text('dev@gmail.com'), findsOneWidget);
      expect(find.text('App password · imap.gmail.com'), findsOneWidget);
      expect(find.text('App password · imap.mail.me.com'), findsOneWidget);
      expect(find.text('Add account'), findsOneWidget);
      expect(find.text('$appVersion ($appBuild)'), findsOneWidget);
      expect(find.text('Open-source licences'), findsOneWidget);
      // Key presets are for keyboards.
      expect(find.text('Keys'), findsNothing);
      expect(find.text('vim'), findsNothing);
      // Rows are finger-sized.
      expect(
        tester
            .getSize(
              find.ancestor(
                of: find.text('dev@gmail.com'),
                matching: find.byType(InkWell),
              ),
            )
            .height,
        greaterThanOrEqualTo(64),
      );

      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      expect(c.read(appearanceProvider), ThemeMode.light);
      expect(await repo.setting('theme'), 'light');

      await tester.tap(find.text('Open-source licences'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(LicensePage), findsOneWidget);
    },
  );

  testWidgets('on an iPhone both screens go back with its own chevron', (
    tester,
  ) async {
    await start(tester);
    await openAccount(tester, 'dev@gmail.com');
    expect(AppIcons.back, CupertinoIcons.chevron_back);
    expect(
      find.descendant(
        of: find.byTooltip('Back'),
        matching: find.byIcon(AppIcons.back),
      ),
      findsOneWidget,
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(AccountDetailScreen), findsNothing);
    expect(find.byIcon(AppIcons.back), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(PhoneSettingsScreen), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
    'Add account opens the setup screen, and the new account lands on all accounts',
    (tester) async {
      await start(tester);
      c.read(queryProvider.notifier).set('account:work@outlook.com');
      await openSettings(tester);
      await tester.tap(find.text('Add account'));
      await tester.pumpAndSettle();
      expect(find.byType(AccountSetupScreen), findsOneWidget);

      await tester.tap(find.text('Continue with Google'));
      await tester.pumpAndSettle();
      expect(repo.signedIn, ['you@gmail.com']);
      expect(find.byType(AccountSetupScreen), findsNothing);
      expect(find.byType(PhoneSettingsScreen), findsNothing);
      expect(c.read(queryProvider), '');
      await settle(tester);
    },
  );

  testWidgets('a tablet keeps the settings sheet', (tester) async {
    await start(tester, size: const Size(1024, 1366) / 1.5);
    await openSettings(tester);
    expect(find.byType(SettingsSheet), findsOneWidget);
    expect(find.byType(PhoneSettingsScreen), findsNothing);
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    await tester.tap(find.text('enter password'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsSheet), findsOneWidget);
    expect(find.byType(AccountDetailScreen), findsNothing);
  });

  testWidgets('name and signature are kept on the way out, with Saved', (
    tester,
  ) async {
    await start(tester);
    await openAccount(tester, 'dev@gmail.com');
    expect(find.text('Gmail · App password'), findsOneWidget);
    expect(find.text('Name shown to recipients'), findsOneWidget);
    expect(find.text('Signature'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Zonda'),
      'Zonda Dev',
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(AccountDetailScreen), findsNothing);
    final a = (await repo.accounts()).first;
    expect(a.displayName, 'Zonda Dev');
    expect(a.signature, 'Zonda\nflomsi.dev');
    expect(c.read(noticeProvider), 'Saved');
    await settle(tester);

    // Nothing changed: nothing said.
    await tester.tap(find.text('dev@gmail.com'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(c.read(noticeProvider), isNull);
  });

  testWidgets('a new password is checked before it is kept', (tester) async {
    await start(tester);
    await openAccount(tester, 'dev@gmail.com');
    expect(find.text('New password'), findsNothing);
    await tester.tap(find.text('Password'));
    await tester.pumpAndSettle();
    expect(find.text('New password'), findsOneWidget);
    FilledButton button() =>
        tester.widget(find.widgetWithText(FilledButton, 'Check and save'));
    expect(button().onPressed, isNull);

    await tester.enterText(passwordField(), 'wrong');
    await tester.pump();
    await tester.tap(find.text('Check and save'));
    await tester.pumpAndSettle();
    expect(
      find.text('The server rejected the name or password'),
      findsOneWidget,
    );

    await tester.enterText(passwordField(), MockRepository.goodPassword);
    await tester.tap(find.text('Check and save'));
    await tester.pumpAndSettle();
    expect(c.read(noticeProvider), 'Signed in to dev@gmail.com');
    expect(find.text('Check and save'), findsNothing);
    await settle(tester);
  });

  testWidgets(
    'a parked account says so, and Enter password opens its screen ready to type',
    (tester) async {
      await start(tester);
      repo.failSignIn(1, _refused);
      await tester.pumpAndSettle();

      await openSettings(tester);
      final note = tester.widget<Text>(find.text('Sign-in needed'));
      expect(note.style?.color, Scheme.dark.red);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('enter password'));
      await tester.pumpAndSettle();
      expect(find.byType(AccountDetailScreen), findsOneWidget);
      expect(find.text('Gmail needs an app password'), findsOneWidget);
      expect(find.text('New app password'), findsOneWidget);
      final field = tester.widget<TextField>(passwordField());
      expect(field.focusNode!.hasFocus, isTrue);

      await tester.ensureVisible(find.text('Try again'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(repo.problems, isEmpty);
      expect(find.text('Gmail needs an app password'), findsNothing);
      await settle(tester);
    },
  );

  testWidgets('an account signed in with Google signs in again there', (
    tester,
  ) async {
    await start(tester, using: _GoogleRepo());
    await openSettings(tester);
    expect(find.text('Google sign-in'), findsOneWidget);
    await tester.tap(find.text('dev@gmail.com'));
    await tester.pumpAndSettle();
    expect(find.text('Gmail · Google sign-in'), findsOneWidget);
    expect(find.text('Signed in with Google'), findsOneWidget);
    expect(find.text('Password'), findsNothing);

    await tester.tap(find.text('Sign in again'));
    await tester.pumpAndSettle();
    // The same account, signed in again: nothing added.
    expect(repo.signInHints, ['dev@gmail.com']);
    expect((await repo.accounts()).length, 3);
    expect(c.read(noticeProvider), 'Signed in as dev@gmail.com');
    await settle(tester);
  });

  testWidgets(
    'removing asks first, then goes back to Settings, and a list on it shows all',
    (tester) async {
      await start(tester);
      c.read(queryProvider.notifier).set('account:work@outlook.com');
      await openAccount(tester, 'work@outlook.com');
      // An edit on the way to removing is not saved over the removal.
      await tester.enterText(find.byType(TextField).first, 'Work');

      await tester.tap(find.text('Remove account'));
      await tester.pumpAndSettle();
      expect(find.text('Remove work@outlook.com?'), findsOneWidget);
      expect(
        find.text(
          'Mail and drafts kept on this phone for this account are deleted. Nothing changes on the server.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect((await repo.accounts()).length, 3);
      expect(find.byType(AccountDetailScreen), findsOneWidget);

      await tester.tap(find.text('Remove account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect((await repo.accounts()).map((a) => a.email), [
        'dev@gmail.com',
        'me@icloud.com',
      ]);
      expect(find.byType(AccountDetailScreen), findsNothing);
      expect(find.byType(PhoneSettingsScreen), findsOneWidget);
      expect(find.text('work@outlook.com'), findsNothing);
      expect(c.read(queryProvider), '');
      await tester.pump(const Duration(seconds: 1));
      expect(c.read(noticeProvider), 'Removed work@outlook.com');
      await settle(tester);
    },
  );

  testWidgets('removing the last account brings back the start screen', (
    tester,
  ) async {
    await start(tester);
    await repo.removeAccount(2);
    await repo.removeAccount(3);
    await tester.pumpAndSettle();
    await openAccount(tester, 'dev@gmail.com');
    await tester.tap(find.text('Remove account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(await repo.accounts(), isEmpty);
    expect(find.byType(WelcomeScreen), findsOneWidget);
    expect(find.byType(PhoneSettingsScreen), findsNothing);
    expect(find.byType(AccountDetailScreen), findsNothing);
    expect(c.read(noticeProvider), 'Removed dev@gmail.com');
    await settle(tester);
  });

  testWidgets(
    'a slow removal: a second tap asks nothing, and leaving meanwhile still resets the list',
    (tester) async {
      final slow = _SlowRemoveRepo();
      await start(tester, using: slow);
      c.read(queryProvider.notifier).set('account:work@outlook.com');
      await openAccount(tester, 'work@outlook.com');
      await tester.tap(find.text('Remove account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(slow.removals, 1);

      // Still going: tapping again does not ask a second time.
      await tester.tap(find.text('Remove account'));
      await tester.pumpAndSettle();
      expect(find.text('Remove work@outlook.com?'), findsNothing);

      // Gone back before it finished: nothing is saved over it, the list still moves
      // off the removed account, and Settings stays.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(AccountDetailScreen), findsNothing);
      slow.gate.complete();
      await tester.pumpAndSettle();
      expect(slow.removals, 1);
      expect(c.read(queryProvider), '');
      expect(c.read(noticeProvider), 'Removed work@outlook.com');
      expect(find.byType(PhoneSettingsScreen), findsOneWidget);
      expect(find.text('work@outlook.com'), findsNothing);
      await settle(tester);
    },
  );

  testWidgets(
    'large text on a small phone: everything fits, and Enter password still has the field ready',
    (tester) async {
      await start(tester, size: const Size(320, 568), scale: 2);
      repo.failSignIn(1, _refused);
      await tester.pumpAndSettle();
      await openSettings(tester);
      expect(tester.takeException(), isNull);
      // Down the list to the theme and the version, built only when they scroll in.
      await tester.scrollUntilVisible(find.text('Open-source licences'), 200);
      await tester.pumpAndSettle();
      expect(find.text('Theme'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pageBack();
      await tester.pumpAndSettle();

      // The field is below the problem, the name and the signature: it is built all
      // the same, takes the focus and is brought into view.
      await tester.tap(find.text('enter password'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final field = tester.widget<TextField>(passwordField());
      expect(field.focusNode!.hasFocus, isTrue);
      final rect = tester.getRect(passwordField());
      expect(rect.top, greaterThan(Touch.appBar));
      expect(rect.bottom, lessThanOrEqualTo(568));
    },
  );
}
