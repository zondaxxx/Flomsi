import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/mock_repository.dart';
import 'package:mail_app/data/models.dart';
import 'package:mail_app/features/attachments/attachment_chip.dart';
import 'package:mail_app/features/onboarding/app_gate.dart';
import 'package:mail_app/features/phone/phone_route.dart';
import 'package:mail_app/features/phone/phone_shell.dart';
import 'package:mail_app/features/phone/phone_thread_screen.dart';
import 'package:mail_app/features/phone/undo.dart';
import 'package:mail_app/features/thread/thread_view.dart';
import 'package:mail_app/platform.dart';
import 'package:mail_app/state/providers.dart';
import 'package:mail_app/theme/app_icons.dart';
import 'package:mail_app/theme/surfaces.dart';
import 'package:mail_app/theme/tokens.dart';

const _filler =
    'The glass prototype needs one more pass on the sidebar over bright wallpapers.';

/// Mail with what the page has to handle: several recipients, blocked images in more
/// than one message, a long first message; loading that can be held back or fail once.
class _Repo extends MockRepository {
  int htmlFetches = 0;
  int opened = 0;
  Completer<void>? hold;
  bool failOnce = false;

  @override
  Future<List<Message>> messages(int threadId) async {
    await hold?.future;
    if (failOnce) {
      failOnce = false;
      throw Exception('database is locked');
    }
    if (threadId != 5) return super.messages(threadId);
    final now = DateTime.now();
    return [
      Message(
        id: 501,
        threadId: 5,
        fromName: 'Linear',
        fromAddr: 'notifications@linear.app',
        to: ['me', 'Boris Ivanov', 'carol@example.com'],
        date: now.subtract(const Duration(hours: 3)),
        text: List.filled(30, _filler).join('\n\n'),
        blockedImages: 2,
      ),
      Message(
        id: 502,
        threadId: 5,
        fromName: 'Boris Ivanov',
        fromAddr: 'boris@studio.dev',
        to: ['me', 'Anna Sokolova'],
        date: now.subtract(const Duration(hours: 1)),
        text: 'Taking MAIL-121.',
        blockedImages: 1,
      ),
    ];
  }

  @override
  Future<String?> messageHtml(
    int messageId, {
    bool remoteImages = false,
  }) async {
    if (!remoteImages) return null;
    htmlFetches++;
    return '<p>With pictures $messageId</p>'
        '${List.filled(30, '<p>$_filler</p>').join()}';
  }

  @override
  Future<String> openAttachment(Attachment a) async {
    opened++;
    return '/tmp/${a.name}';
  }
}

void main() {
  late ProviderContainer c;
  late _Repo repo;
  setUp(rootBundle.clear);
  tearDown(() => debugTouchOverride = null);

  /// A phone with the list underneath and conversation [id] pushed over it, opened from
  /// the mailbox [query].
  Future<void> open(
    WidgetTester tester,
    int id, {
    String query = '',
    void Function(_Repo repo)? setup,
    bool settle = true,
  }) async {
    // A second page in the same test starts from nothing.
    await tester.pumpWidget(const SizedBox());
    debugTouchOverride = true;
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    repo = _Repo();
    setup?.call(repo);
    c = ProviderContainer(
      overrides: [repositoryProvider.overrideWithValue(repo)],
      retry: (_, _) => null,
    );
    addTearDown(c.dispose);
    c.read(queryProvider.notifier).set(query);
    c.read(selectedThreadIdProvider.notifier).select(id);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          navigatorKey: nav,
          theme: buildTheme(Scheme.dark),
          home: const Scaffold(body: Text('The list')),
        ),
      ),
    );
    unawaited(
      nav.currentState!.push(phonePage((_) => PhoneThreadScreen(threadId: id))),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  Finder page() => find.byType(PhoneThreadScreen);
  TextStyle style(WidgetTester tester, Finder f) =>
      tester.widget<Text>(f).style!;
  Finder menuItem(String title) => find.widgetWithText(MenuItemButton, title);

  /// The messages' own scroll view (HTML mail may hold more of them).
  Finder messages() => find
      .descendant(
        of: find.byType(ThreadContent),
        matching: find.byType(Scrollable),
      )
      .first;

  Future<void> more(WidgetTester tester) async {
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
  }

  /// Takes back the filing or snooze the notice offers, and lets its timers run out.
  Future<void> undo(WidgetTester tester) async {
    c.read(noticeProvider.notifier).current?.onAction?.call();
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  }

  testWidgets('the star toggles in the top bar; back closes the page', (
    tester,
  ) async {
    await open(tester, 7);
    expect(find.byIcon(AppIcons.back), findsOneWidget);
    await tester.tap(find.byTooltip('Star'));
    await tester.pumpAndSettle();
    expect((await repo.thread(7))!.starred, isTrue);
    expect(find.byTooltip('Remove star'), findsOneWidget);
    expect(find.byIcon(AppIcons.starOn), findsOneWidget);
    await tester.tap(find.byTooltip('Remove star'));
    await tester.pumpAndSettle();
    expect((await repo.thread(7))!.starred, isFalse);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(page(), findsNothing);
    expect(find.text('The list'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('phone reading sizes; the sender’s address always shows', (
    tester,
  ) async {
    await open(tester, 1);
    final subject = style(
      tester,
      find.text('[mail-client] PR #42 · feat(sync): incremental IMAP fetch'),
    );
    expect(subject.fontSize, 21);
    expect(subject.fontWeight, FontWeight.w600);
    final name = style(tester, find.text('GitHub'));
    expect(name.fontSize, 16);
    expect(name.fontWeight, FontWeight.w600);
    final address = style(tester, find.text('github@example.com'));
    expect(address.fontFamily, kMono);
    expect(address.fontSize, 13);
    final body = style(
      tester,
      find.text('anna approved these changes · 3 files changed, +212 −48'),
    );
    expect(body.fontSize, 16);
    expect(body.height, 1.55);
    // The desktop's header block and quick reply are not here.
    expect(find.text('from'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets(
    'the subject line: labels, message count, account; "to me, Boris" opens to the list and date',
    (tester) async {
      await open(tester, 5);
      expect(find.text('2 messages'), findsOneWidget);
      expect(find.text('work'), findsOneWidget);
      // Three accounts: the conversation says which one it is in.
      expect(find.text('in dev@gmail.com'), findsOneWidget);

      const short = 'to me, Boris, carol@example.com';
      const full = 'me, Boris Ivanov, carol@example.com';
      expect(find.text(short), findsOneWidget);
      expect(find.text(full), findsNothing);
      await tester.tap(find.text(short));
      await tester.pumpAndSettle();
      expect(find.text(full), findsOneWidget);
      expect(find.text('date'), findsOneWidget);
      await tester.tap(find.text(short));
      await tester.pumpAndSettle();
      expect(find.text(full), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets('the last row replies to the sender, address included', (
    tester,
  ) async {
    await open(tester, 7);
    final row = find.text('Reply to Hetzner <billing@hetzner.com>');
    await tester.scrollUntilVisible(row, 300, scrollable: messages());
    await tester.pumpAndSettle();
    expect(
      tester
          .getSize(
            find.ancestor(of: row, matching: find.byType(HoverRegion)).first,
          )
          .height,
      greaterThanOrEqualTo(52),
    );
    await tester.tap(row);
    await tester.pumpAndSettle();
    final draft = c.read(composeProvider)!;
    expect(draft.kind, DraftKind.reply);
    expect(draft.to, ['Hetzner <billing@hetzner.com>']);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('Archive closes the page and files the conversation with Undo', (
    tester,
  ) async {
    await open(tester, 7);
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    expect(page(), findsNothing);
    final p = c.read(pendingFilingProvider)!;
    expect(p.threadId, 7);
    expect(p.kind, FilingKind.archive);
    final notice = c.read(noticeProvider.notifier).current!;
    expect(notice.text, 'Archived');
    expect(notice.action, 'Undo');
    await undo(tester);
    expect(c.read(pendingFilingProvider), isNull);
    expect(await repo.thread(7), isNotNull);
  });

  testWidgets(
    'a page files its own conversation, whatever was selected since',
    (tester) async {
      await open(tester, 7);
      // A page pushed on top (a tapped notification) selected another one.
      c.read(selectedThreadIdProvider.notifier).select(3);
      await tester.pump();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(page(), findsNothing);
      expect(c.read(pendingFilingProvider)?.threadId, 7);
      expect(c.read(pendingFilingProvider)?.kind, FilingKind.trash);
      expect(c.read(noticeProvider), 'Deleted');
      await undo(tester);
    },
  );

  testWidgets('outside the Inbox, Archive becomes Move, through the sheet', (
    tester,
  ) async {
    await open(tester, 7, query: 'account:dev@gmail.com in:archive');
    expect(find.text('Archive'), findsNothing);
    await tester.tap(find.text('Move'));
    await tester.pumpAndSettle();
    expect(find.text('Move to'), findsOneWidget);
    await tester.tap(find.text('Receipts'));
    await tester.pumpAndSettle();
    expect(page(), findsNothing);
    expect(c.read(pendingFilingProvider)?.kind, FilingKind.move);
    expect(c.read(noticeProvider), 'Moved to Receipts');
    await undo(tester);
  });

  testWidgets('in Trash, Delete is off (the Unread filter aside)', (
    tester,
  ) async {
    await open(tester, 7, query: 'in:trash is:unread');
    // The same view, narrowed to unread mail.
    c.read(listFilterProvider.notifier).set('unread');
    await tester.pumpAndSettle();
    expect(find.text('Move'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(page(), findsOneWidget);
    expect(c.read(pendingFilingProvider), isNull);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets(
    'More: Reply all only for several recipients; Mark as unread closes the page',
    (tester) async {
      await open(tester, 7);
      await more(tester);
      expect(menuItem('Reply all'), findsNothing);
      for (final item in ['Mark as unread', 'Move to…', 'Snooze…']) {
        expect(menuItem(item), findsOneWidget, reason: item);
      }
      await tester.tap(menuItem('Mark as unread'));
      await tester.pumpAndSettle();
      expect(page(), findsNothing);
      expect((await repo.thread(7))!.unread, isTrue);
      expect(c.read(noticeProvider), 'Marked as unread');
      await tester.pump(const Duration(seconds: 3));

      // The last message of 5 went to two people.
      await open(tester, 5);
      await more(tester);
      await tester.tap(menuItem('Reply all'));
      await tester.pumpAndSettle();
      final draft = c.read(composeProvider)!;
      expect(draft.to, ['Boris Ivanov <boris@studio.dev>']);
      expect(draft.cc, ['Anna Sokolova']);
      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets(
    'Move to… from More picks a folder in a sheet and closes the page',
    (tester) async {
      await open(tester, 7);
      await more(tester);
      await tester.tap(menuItem('Move to…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Travel'));
      await tester.pumpAndSettle();
      expect(page(), findsNothing);
      expect(c.read(pendingFilingProvider)?.folderName, 'Travel');
      expect(c.read(noticeProvider), 'Moved to Travel');
      await undo(tester);
    },
  );

  testWidgets(
    'Snooze… closes the page with Undo; a snoozed one offers Unsnooze',
    (tester) async {
      await open(tester, 7);
      await more(tester);
      await tester.tap(menuItem('Snooze…'));
      await tester.pumpAndSettle();
      expect(find.text('Snooze until'), findsOneWidget);
      await tester.tap(find.text('Next week'));
      await tester.pumpAndSettle();
      expect(page(), findsNothing);
      expect((await repo.thread(7))!.snoozed, isTrue);
      expect(c.read(noticeProvider.notifier).current?.action, 'Undo');
      await undo(tester);
      expect((await repo.thread(7))!.snoozed, isFalse);

      await open(
        tester,
        7,
        setup: (r) => r.snooze(7, DateTime.now().add(const Duration(days: 2))),
      );
      await more(tester);
      expect(menuItem('Snooze…'), findsNothing);
      await tester.tap(menuItem('Unsnooze'));
      await tester.pumpAndSettle();
      expect((await repo.thread(7))!.snoozed, isFalse);
      expect(c.read(noticeProvider), 'Back in the inbox');
      expect(page(), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets('blocked images: a full-size button loads that message’s', (
    tester,
  ) async {
    await open(tester, 7);
    expect(find.text('1 image blocked'), findsOneWidget);
    final load = find.widgetWithText(TextButton, 'Load images');
    expect(tester.getSize(load).height, greaterThanOrEqualTo(48));
    await tester.tap(load);
    await tester.pumpAndSettle();
    expect(repo.htmlFetches, 1);
    expect(find.text('1 image blocked'), findsNothing);
    expect(
      find.textContaining('With pictures 701', findRichText: true),
      findsWidgets,
    );
    // Nothing left to load: More no longer offers it.
    await more(tester);
    expect(menuItem('Load images'), findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('Load images in More loads every message’s, further down too', (
    tester,
  ) async {
    await open(tester, 5);
    // The second message is too far down to be built yet.
    expect(find.text('Boris Ivanov'), findsNothing);
    await more(tester);
    await tester.tap(menuItem('Load images'));
    await tester.pumpAndSettle();
    expect(repo.htmlFetches, 1);
    expect(find.text('2 images blocked'), findsNothing);

    await tester.scrollUntilVisible(
      find.text('Boris Ivanov'),
      400,
      scrollable: messages(),
    );
    await tester.pumpAndSettle();
    expect(repo.htmlFetches, 2);
    expect(find.text('1 image blocked'), findsNothing);
    expect(
      find.textContaining('With pictures 502', findRichText: true),
      findsWidgets,
    );
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('the top bar gets a hairline once the messages scroll', (
    tester,
  ) async {
    await open(tester, 5);
    ShapeBorder? line() => tester.widget<AppBar>(find.byType(AppBar)).shape;
    expect(line(), isNull);
    await tester.drag(find.byType(ThreadContent), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(line(), isA<Border>());
    await tester.drag(find.byType(ThreadContent), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(line(), isNull);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('files are 56 rows; one that can run code asks before sharing', (
    tester,
  ) async {
    await open(tester, 7);
    expect(find.byType(AttachmentChip), findsNothing);
    final name = find.text('invoice-2026-09');
    expect(name, findsOneWidget);
    expect(find.text('.pdf'), findsOneWidget);
    expect(find.text('84 KB'), findsOneWidget);
    expect(
      tester
          .getSize(
            find.ancestor(of: name, matching: find.byType(HoverRegion)).first,
          )
          .height,
      greaterThanOrEqualTo(56),
    );
    await tester.pump(const Duration(seconds: 3));

    await open(tester, 9);
    await tester.tap(find.text('Mail-Glass-export'));
    await tester.pumpAndSettle();
    expect(find.text('This is a .svg file'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repo.opened, 0);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('an unread conversation is marked read after a moment', (
    tester,
  ) async {
    await open(tester, 1, settle: false);
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byType(ThreadContent), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    expect((await repo.thread(1))!.unread, isTrue);
    await tester.pump(const Duration(milliseconds: 500));
    expect((await repo.thread(1))!.unread, isFalse);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a spinner only after 300 ms; a failure offers Try again', (
    tester,
  ) async {
    await open(tester, 7, settle: false, setup: (r) => r.hold = Completer());
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    repo.hold!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Your invoice for September'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));

    await open(tester, 7, setup: (r) => r.failOnce = true);
    expect(find.text('Couldn’t open this message'), findsOneWidget);
    // Nothing to act on yet.
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    expect(page(), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Your invoice for September'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('Mark as unread just after opening leaves it unread', (
    tester,
  ) async {
    await open(tester, 1, settle: false);
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byType(ThreadContent), findsOneWidget);
    // At 750 ms the page starts to go; 900 ms falls while it is still going.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('More'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(menuItem('Mark as unread'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(page(), findsOneWidget);
    await tester.pumpAndSettle();
    expect(page(), findsNothing);
    expect((await repo.thread(1))!.unread, isTrue);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a conversation deleted elsewhere while open says so', (
    tester,
  ) async {
    await open(tester, 7);
    await repo.trash(7);
    await tester.pumpAndSettle();
    expect(find.text('This conversation is no longer here'), findsOneWidget);
    // Nothing left to act on.
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    expect(page(), findsOneWidget);
    expect(c.read(pendingFilingProvider), isNull);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('on iOS the back button names the mailbox underneath', (
    tester,
  ) async {
    await open(tester, 7, query: 'is:unread');
    // The Inbox, narrowed to unread mail.
    c.read(listFilterProvider.notifier).set('unread');
    await tester.pumpAndSettle();
    expect(find.byIcon(AppIcons.back), findsOneWidget);
    expect(find.text('Inbox'), findsOneWidget);
    await tester.tap(find.text('Inbox'));
    await tester.pumpAndSettle();
    expect(page(), findsNothing);
    await tester.pump(const Duration(seconds: 3));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
    'from the list: Archive on the page, back on the list with Undo',
    (tester) async {
      debugTouchOverride = true;
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final mock = MockRepository();
      c = ProviderContainer(
        overrides: [repositoryProvider.overrideWithValue(mock)],
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
      const subject = 'Your invoice for September';
      await tester.tap(find.text(subject));
      await tester.pumpAndSettle();
      expect(page(), findsOneWidget);
      await tester.tap(find.text('Archive'));
      await tester.pumpAndSettle();
      expect(page(), findsNothing);
      expect(find.byType(PhoneShell), findsOneWidget);
      expect(find.text(subject), findsNothing);
      expect(c.read(noticeProvider), 'Archived');
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(await mock.thread(7), isNull);
      await tester.pump(const Duration(seconds: 3));
    },
  );
}
