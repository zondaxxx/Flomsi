import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/mock_repository.dart';
import 'package:mail_app/data/models.dart';
import 'package:mail_app/features/onboarding/app_gate.dart';
import 'package:mail_app/features/onboarding/app_password_screen.dart';
import 'package:mail_app/features/onboarding/provider_picker.dart';
import 'package:mail_app/features/onboarding/welcome_screen.dart';
import 'package:mail_app/platform.dart';
import 'package:mail_app/state/providers.dart';
import 'package:mail_app/theme/tokens.dart';

/// A sign-in page that stays open until [done] completes.
class _HeldRepo extends MockRepository {
  _HeldRepo() : super(empty: true);
  final done = Completer<void>();

  @override
  Future<Account> signIn(
    String provider, {
    String? loginHint,
    void Function()? onReturned,
  }) async {
    await done.future;
    return super.signIn(provider, loginHint: loginHint, onReturned: onReturned);
  }
}

void main() {
  late ProviderContainer c;
  late MockRepository repo;
  setUp(rootBundle.clear);
  tearDown(() => debugTouchOverride = null);

  /// The start screen on a phone, unless [touch] is false (a computer).
  Future<void> start(
    WidgetTester tester, {
    List<String>? providers,
    bool touch = true,
    MockRepository? using,
  }) async {
    debugTouchOverride = touch;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    repo = using ?? MockRepository(empty: true);
    if (providers != null) repo.providers = providers;
    c = ProviderContainer(
      overrides: [repositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildTheme(Scheme.dark),
          home: const AppGate(shell: Text('MAIL')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('no account: the start screen, and Google signs in to the mail', (
    tester,
  ) async {
    await start(tester);
    expect(find.byType(WelcomeScreen), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Other email account'), findsOneWidget);
    await tester.tap(find.text('Continue with Google'));
    await tester.pumpAndSettle();
    expect(repo.signedIn, ['you@gmail.com']);
    expect(find.text('MAIL'), findsOneWidget);
    expect(c.read(noticeProvider), 'Signed in as you@gmail.com');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets(
    'a closed Google page shows nothing and offers the app password',
    (tester) async {
      await start(tester);
      repo.signInFails = const Problem(
        kind: 'cancelled',
        title: 'Sign-in cancelled',
      );
      await tester.tap(find.text('Continue with Google'));
      await tester.pumpAndSettle();
      expect(find.text('Sign-in cancelled'), findsNothing);
      await tester.tap(find.text('Use a Gmail app password instead'));
      await tester.pumpAndSettle();
      expect(find.byType(AppPasswordScreen), findsOneWidget);
      expect(find.textContaining('2-Step Verification'), findsWidgets);
    },
  );

  testWidgets('a refusal is named above the buttons', (tester) async {
    await start(tester);
    repo.signInFails = const Problem(
      kind: 'scope',
      title: 'Mail access wasn’t allowed',
      hint: 'Keep the Gmail box ticked.',
    );
    await tester.tap(find.text('Continue with Google'));
    await tester.pumpAndSettle();
    expect(find.text('Mail access wasn’t allowed'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Mail access wasn’t allowed'), findsNothing);
  });

  testWidgets('without Google sign-in: one button to every provider', (
    tester,
  ) async {
    await start(tester, providers: const []);
    expect(find.text('Continue with Google'), findsNothing);
    await tester.tap(find.text('Add an email account'));
    await tester.pumpAndSettle();
    expect(find.byType(ProviderPicker), findsOneWidget);
    expect(find.text('Gmail'), findsOneWidget);
    // Yandex: steps with its pages, then the address and the app password.
    await tester.tap(find.text('Yandex Mail'));
    await tester.pumpAndSettle();
    expect(find.text('Open app passwords'), findsOneWidget);
    final signIn = find.widgetWithText(FilledButton, 'Sign in');
    expect(tester.widget<FilledButton>(signIn).onPressed, isNull);
    await tester.enterText(find.byType(TextField).at(0), 'z@yandex.ru');
    await tester.enterText(find.byType(TextField).at(1), 'app-password');
    await tester.pumpAndSettle();
    await tester.tap(signIn);
    await tester.pumpAndSettle();
    // Added: back to the first route, which now shows the mail.
    expect(find.text('MAIL'), findsOneWidget);
    expect(c.read(noticeProvider), 'Added z@yandex.ru');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('every control on the start screen is at least 48 tall', (
    tester,
  ) async {
    await start(tester, providers: const ['google', 'microsoft']);
    for (final label in [
      'Continue with Google',
      'Sign in with Microsoft',
      'Other email account',
    ]) {
      final box = tester.getSize(
        find
            .ancestor(of: find.text(label), matching: find.byType(InkWell))
            .first,
      );
      expect(box.height, greaterThanOrEqualTo(48), reason: label);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'while Google\'s page is open: a phone waits, a computer can cancel',
    (tester) async {
      for (final touch in [true, false]) {
        final held = _HeldRepo();
        await start(tester, using: held, touch: touch);
        await tester.tap(find.text('Continue with Google'));
        await tester.pump();
        if (touch) {
          expect(find.text('Opening Google…'), findsOneWidget);
          expect(find.text('Cancel'), findsNothing);
        } else {
          expect(
            find.text('Finish signing in in your browser…'),
            findsOneWidget,
          );
          expect(find.text('Cancel'), findsOneWidget);
        }
        held.done.complete();
        await tester.pumpAndSettle();
        expect(find.text('MAIL'), findsOneWidget);
        await tester.pump(const Duration(seconds: 3));
      }
    },
  );

  testWidgets('Proton Mail Bridge is offered on a computer, not on a phone', (
    tester,
  ) async {
    for (final touch in [true, false]) {
      await start(tester, touch: touch);
      await tester.tap(find.text('Other email account'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Proton Mail'), 100);
      await tester.tap(find.text('Proton Mail'));
      await tester.pumpAndSettle();
      expect(
        find.byType(ProviderPicker),
        touch ? findsOneWidget : findsNothing,
        reason: 'touch: $touch',
      );
    }
  });
}
