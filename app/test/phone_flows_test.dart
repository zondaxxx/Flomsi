import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/mock_repository.dart';
import 'package:mail_app/data/models.dart';
import 'package:mail_app/features/phone/phone_compose_screen.dart';
import 'package:mail_app/features/phone/phone_shell.dart';
import 'package:mail_app/features/phone/phone_thread_row.dart';
import 'package:mail_app/features/phone/phone_thread_screen.dart';
import 'package:mail_app/features/phone/undo.dart';
import 'package:mail_app/features/shell/editor_shell.dart';
import 'package:mail_app/main.dart';
import 'package:mail_app/platform.dart';
import 'package:mail_app/state/providers.dart';

/// Archiving takes a while, as it does over a slow connection.
class _SlowRepo extends MockRepository {
  @override
  Future<int> archive(int threadId) async {
    await Future<void>.delayed(const Duration(seconds: 2));
    return super.archive(threadId);
  }
}

/// dev@gmail.com signed in with Google, not with a password.
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
              problem: a.problem,
              auth: 'xoauth2',
            ),
  ];
}

/// The whole app on a phone, notices as the bar at the bottom.
void main() {
  late ProviderContainer c;
  late MockRepository repo;
  setUp(rootBundle.clear);
  tearDown(() => debugTouchOverride = null);

  Future<void> start(
    WidgetTester tester, {
    MockRepository? using,
    void Function(ProviderContainer c)? before,
    Size size = const Size(390, 844),
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
    before?.call(c);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: c, child: const MailApp()),
    );
    await tester.pumpAndSettle();
  }

  Future<bool> stored(String subject) async =>
      (await repo.threads('')).any((t) => t.subject == subject);

  Future<void> swipe(WidgetTester tester, String subject) async {
    await tester.drag(find.text(subject), const Offset(300, 0));
    await tester.pumpAndSettle();
  }

  const top = 'Top stories this week';

  testWidgets('Undo on the bar brings it back; once filed, the bar is gone', (
    tester,
  ) async {
    await start(tester);
    await swipe(tester, top);
    expect(find.widgetWithText(SnackBar, 'Archived'), findsOneWidget);
    await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
    await tester.pumpAndSettle();
    expect(find.text(top), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(await stored(top), isTrue);

    await swipe(tester, top);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    // Filed, and no Undo left on screen that could no longer undo it.
    expect(await stored(top), isFalse);
    expect(find.byType(SnackBar), findsNothing);
    expect(c.read(hiddenThreadsProvider), isEmpty);
  });

  testWidgets('going to the background files what waits for Undo', (
    tester,
  ) async {
    await start(tester);
    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    await swipe(tester, top);
    expect(await stored(top), isTrue);
    for (final st in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(st);
    }
    await tester.pump();
    expect(await stored(top), isFalse);
    expect(c.read(pendingFilingProvider), isNull);
    // Back in front: no Undo for what has already been filed.
    for (final st in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(st);
    }
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('quick swipes while a filing is slow are all filed', (
    tester,
  ) async {
    await start(tester, using: _SlowRepo());
    const rows = [
      top,
      'Your invoice for September',
      '3 issues assigned to you',
    ];
    // Each swipe lands while the one before is still being filed (2 s).
    for (final r in rows) {
      await swipe(tester, r);
    }
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pumpAndSettle();
    for (final r in rows) {
      expect(await stored(r), isFalse, reason: r);
    }
    expect(c.read(hiddenThreadsProvider), isEmpty);
  });

  testWidgets('a notification the app was opened from opens its conversation', (
    tester,
  ) async {
    await start(
      tester,
      before: (c) => c.read(openThreadProvider.notifier).open(2),
    );
    expect(find.byType(PhoneThreadScreen), findsOneWidget);
    expect(c.read(openThreadProvider), isNull);
    await tester.pageBack();
    await tester.pumpAndSettle();
    // The same conversation's notification again opens it again.
    c.read(openThreadProvider.notifier).open(2);
    await tester.pumpAndSettle();
    expect(find.byType(PhoneThreadScreen), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets(
    'a notification while writing keeps the draft and opens the mail',
    (tester) async {
      await start(tester);
      await tester.tap(find.text('Compose'));
      await tester.pumpAndSettle();
      expect(find.byType(PhoneComposeScreen), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'bob@x.dev');
      await tester.pump();
      c.read(openThreadProvider.notifier).open(2);
      await tester.pumpAndSettle();
      expect(find.byType(PhoneComposeScreen), findsNothing);
      expect(find.byType(PhoneThreadScreen), findsOneWidget);
      expect(c.read(composeProvider), isNull);
      final drafts = await repo.drafts();
      expect(drafts.any((d) => d.to.contains('bob@x.dev')), isTrue);
      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets('back closes an open menu before anything else', (tester) async {
    await start(tester);
    await tester.tap(find.text('Mailboxes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sent'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Check for new mail'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Check for new mail'), findsNothing);
    expect(c.read(queryProvider), 'in:sent');
    // Then back goes to the Inbox, as before.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(c.read(queryProvider), '');
    expect(find.byType(PhoneShell), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('the long-press menu acts on the row that was pressed', (
    tester,
  ) async {
    await start(tester);
    const invoice = 'Your invoice for September';
    final id = (await repo.threads(''))
        .firstWhere((t) => t.subject == invoice)
        .id;
    await tester.longPress(find.text(invoice));
    await tester.pumpAndSettle();
    // Something else gets selected meanwhile (a notification, a sync).
    c.read(selectedThreadIdProvider.notifier).select(2);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(c.read(pendingFilingProvider)?.threadId, id);
    expect(c.read(pendingFilingProvider)?.kind, FilingKind.trash);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('pressing a row leaves the list where it was', (tester) async {
    await start(tester);
    final list = find.byType(Scrollable).first;
    await tester.drag(list, const Offset(0, -2000));
    await tester.pumpAndSettle();
    ScrollPosition pos() => tester.state<ScrollableState>(list).position;
    final before = pos().pixels;
    expect(before, greaterThan(0));
    await tester.longPress(find.byType(PhoneThreadRow).at(1));
    await tester.pumpAndSettle();
    expect(pos().pixels, before);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(pos().pixels, before);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a draft on a phone is deleted from a menu, not by one tap', (
    tester,
  ) async {
    await start(tester);
    await repo.saveDraft(
      const Draft(
        accountId: 1,
        from: 'dev@gmail.com',
        to: ['ann@x.dev'],
        subject: 'Long letter',
      ),
    );
    await tester.tap(find.text('Mailboxes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Drafts'));
    await tester.pumpAndSettle();
    final count = (await repo.drafts()).length;
    final row = find.ancestor(
      of: find.text('Long letter'),
      matching: find.byType(PhoneDraftRow),
    );
    await tester.tap(
      find.descendant(of: row, matching: find.byTooltip('Draft actions')),
    );
    await tester.pumpAndSettle();
    expect((await repo.drafts()).length, count);
    await tester.tap(find.text('Delete draft'));
    await tester.pumpAndSettle();
    expect((await repo.drafts()).length, count - 1);
    expect(find.text('Long letter'), findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets(
    'screen readers can open a row, act on it, and tell the bar apart',
    (tester) async {
      final handle = tester.ensureSemantics();
      await start(tester);
      final row = tester.getSemantics(find.byType(PhoneThreadRow).first);
      final data = row.getSemanticsData();
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      expect(data.hasAction(SemanticsAction.longPress), isTrue);
      final labels = [
        for (final id in data.customSemanticsActionIds ?? const <int>[])
          CustomSemanticsAction.getAction(id)!.label,
      ];
      expect(
        labels,
        containsAll(['Archive', 'Delete', 'Reply', 'More actions']),
      );

      final search = tester
          .getSemantics(find.bySemanticsLabel('Search'))
          .getSemanticsData();
      expect(search.flagsCollection.isToggled, Tristate.none);
      expect(search.hasAction(SemanticsAction.tap), isTrue);
      final unread = tester
          .getSemantics(find.bySemanticsLabel('Unread'))
          .getSemanticsData();
      expect(unread.flagsCollection.isToggled, Tristate.isFalse);
      handle.dispose();
      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets(
    'a Google account that was signed out signs in again from the list',
    (tester) async {
      await start(
        tester,
        using: _GoogleRepo()
          ..failSignIn(
            1,
            const Problem(kind: 'auth', title: 'Google signed Flomsi out'),
          ),
      );
      expect(find.text('Sign in to dev@gmail.com again'), findsOneWidget);
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(repo.signInHints, ['dev@gmail.com']);
      expect((await repo.accounts()).length, 3);
      expect(repo.problems, isEmpty);
      expect(find.text('Sign in to dev@gmail.com again'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets('a window crossing from phone to tablet size closes compose', (
    tester,
  ) async {
    await start(tester);
    await tester.tap(find.text('Compose'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'bob@x.dev');
    await tester.pump();
    tester.view.physicalSize = const Size(1024, 768) * 3;
    await tester.pumpAndSettle();
    expect(find.byType(EditorShell), findsOneWidget);
    expect(find.byType(PhoneComposeScreen), findsNothing);
    expect(c.read(composeProvider), isNull);
    expect(
      (await repo.drafts()).any((d) => d.to.contains('bob@x.dev')),
      isTrue,
    );

    tester.view.physicalSize = const Size(390, 844) * 3;
    await tester.pumpAndSettle();
    await tester.tap(find.text('Compose'));
    await tester.pumpAndSettle();
    expect(find.byType(PhoneComposeScreen), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('on a tablet the search field has room for its text', (
    tester,
  ) async {
    await start(tester, size: const Size(1024, 768));
    expect(find.byType(EditorShell), findsOneWidget);
    final editable = tester
        .state<EditableTextState>(find.byType(EditableText).first)
        .renderEditable;
    expect(
      editable.size.height,
      greaterThanOrEqualTo(editable.preferredLineHeight),
    );
    await tester.pump(const Duration(seconds: 3));
  });
}
