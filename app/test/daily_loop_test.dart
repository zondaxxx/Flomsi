import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/mock_repository.dart';
import 'package:mail_app/features/list/thread_list.dart';
import 'package:mail_app/features/palette/command_palette.dart';
import 'package:mail_app/features/shell/editor_shell.dart';
import 'package:mail_app/keymap/key_scope.dart';
import 'package:mail_app/state/providers.dart';
import 'package:mail_app/theme/tokens.dart';

/// The quick-reply field, whoever it names.
Finder replyField() => find.byWidgetPredicate(
  (w) =>
      w is TextField &&
      (w.decoration?.hintText?.startsWith('Reply to') ?? false),
);

void main() {
  late ProviderContainer c;
  late MockRepository repo;
  setUp(rootBundle.clear);

  Future<void> shell(
    WidgetTester tester, {
    Size size = const Size(1280, 820),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
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
          home: const EditorShell(),
        ),
      ),
    );
    // The keymap is an asset: give the bundle real time, then settle.
    for (var i = 0; i < 50 && !c.read(keymapProvider).hasValue; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  /// One key as the macOS "Русская" layout reports it: the Latin logical key, the
  /// Cyrillic character.
  Future<void> russian(
    WidgetTester tester,
    LogicalKeyboardKey logical,
    PhysicalKeyboardKey physical,
    String character,
  ) async {
    await tester.sendKeyDownEvent(
      logical,
      physicalKey: physical,
      character: character,
    );
    await tester.sendKeyUpEvent(logical, physicalKey: physical);
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3)); // notice timer
    await tester.pumpAndSettle();
  }

  testWidgets('shortcuts work on the Russian layout without switching', (
    tester,
  ) async {
    await shell(tester);
    final first = (await repo.threads('')).first;
    c.read(selectedThreadIdProvider.notifier).select(first.id);
    await tester.pumpAndSettle();

    // E types у; it still archives.
    await russian(
      tester,
      LogicalKeyboardKey.keyE,
      PhysicalKeyboardKey.keyE,
      'у',
    );
    await tester.pumpAndSettle();
    expect(
      (await repo.threads('')).map((t) => t.id),
      isNot(contains(first.id)),
    );

    // g, then the key under I (ш): the status line lists what can follow g.
    c.read(queryProvider.notifier).set('is:starred');
    await tester.pumpAndSettle();
    await russian(
      tester,
      LogicalKeyboardKey.keyG,
      PhysicalKeyboardKey.keyG,
      'п',
    );
    expect(c.read(pendingChordProvider), 'g');
    expect(find.textContaining('g i inbox'), findsOneWidget);
    await russian(
      tester,
      LogicalKeyboardKey.keyI,
      PhysicalKeyboardKey.keyI,
      'ш',
    );
    await tester.pumpAndSettle();
    expect(c.read(queryProvider), '');
    expect(c.read(pendingChordProvider), isNull);
    await settle(tester);
  });

  testWidgets('a sync event does not blank the list or the open thread', (
    tester,
  ) async {
    await shell(tester);
    final first = (await repo.threads('')).first;
    c.read(selectedThreadIdProvider.notifier).select(first.id);
    await tester.pumpAndSettle();
    final rows = find.byType(ThreadRow).evaluate().length;
    expect(rows, greaterThan(3));
    await tester.enterText(replyField(), 'half-written');

    final sync = repo.sync(); // SyncStarted now, SyncFinished later
    await tester.pump(); // the frame right after the event
    expect(find.byType(ThreadRow).evaluate().length, rows);
    expect(find.text(first.subject), findsWidgets);
    expect(find.text('half-written'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await sync;
    await tester.pumpAndSettle();
    expect(find.byType(ThreadRow).evaluate().length, rows);
    expect(find.text('half-written'), findsOneWidget);
  });

  testWidgets('j keeps the selected row inside the list', (tester) async {
    await shell(tester, size: const Size(1280, 420));
    final all = await repo.threads('');
    c.read(selectedThreadIdProvider.notifier).select(all.first.id);
    await tester.pumpAndSettle();
    for (var i = 1; i < all.length; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.pumpAndSettle();
    }
    expect(c.read(selectedThreadIdProvider), all.last.id);
    final list = tester.getRect(find.byType(AnimatedList));
    final row = tester.getRect(
      find.byWidgetPredicate((w) => w is ThreadRow && w.selected),
    );
    expect(row.bottom, lessThanOrEqualTo(list.bottom + 0.5));
    expect(row.top, greaterThanOrEqualTo(list.top));
  });

  testWidgets('k with nothing selected shows the last row', (tester) async {
    await shell(tester, size: const Size(1280, 420));
    final all = await repo.threads('');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.pumpAndSettle();
    expect(c.read(selectedThreadIdProvider), all.last.id);
    final list = tester.getRect(find.byType(AnimatedList));
    final row = tester.getRect(
      find.byWidgetPredicate((w) => w is ThreadRow && w.selected),
    );
    expect(row.top, greaterThanOrEqualTo(list.top));
    expect(row.bottom, lessThanOrEqualTo(list.bottom + 0.5));
  });

  testWidgets('another folder starts at its top, not where the last one was', (
    tester,
  ) async {
    await shell(tester, size: const Size(1280, 420));
    await tester.drag(find.byType(AnimatedList), const Offset(0, -600));
    await tester.pumpAndSettle();
    final list = tester.getRect(find.byType(AnimatedList));
    expect(
      tester.getRect(find.byType(ThreadRow).first).top,
      lessThan(list.top),
    );

    // The mock answers in:archive with every thread, so a list that kept its scroll
    // offset would still start above the top.
    c.read(queryProvider.notifier).set('in:archive');
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byType(ThreadRow).first).top,
      greaterThanOrEqualTo(list.top),
    );
  });

  testWidgets('a half-written reply stays with its thread', (tester) async {
    await shell(tester);
    final all = await repo.threads('');
    c.read(selectedThreadIdProvider.notifier).select(all[0].id);
    await tester.pumpAndSettle();
    await tester.enterText(replyField(), 'for the first thread');
    c.read(selectedThreadIdProvider.notifier).select(all[1].id);
    await tester.pumpAndSettle();
    expect(find.text('for the first thread'), findsNothing);
  });

  testWidgets(
    'archive without an Archive folder asks, creates it and files the thread',
    (tester) async {
      await shell(tester);
      final all = await repo.threads('');
      final first = all[0];
      repo.noArchive.add(first.accountId);
      c.read(selectedThreadIdProvider.notifier).select(first.id);
      await tester.pumpAndSettle();

      // Declined: nothing moves and the thread stays selected.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await tester.pumpAndSettle();
      expect(find.text('No Archive folder'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect((await repo.threads('')).map((t) => t.id), contains(first.id));
      expect(c.read(selectedThreadIdProvider), first.id);

      // Accepted: the folder is made and the thread archived; the next one is selected.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create Archive'));
      await tester.pumpAndSettle();
      expect(repo.noArchive, isEmpty);
      expect(
        (await repo.threads('')).map((t) => t.id),
        isNot(contains(first.id)),
      );
      expect(c.read(selectedThreadIdProvider), all[1].id);
      await settle(tester);
    },
  );

  for (final size in [const Size(900, 700), const Size(390, 800)]) {
    testWidgets('folders are one tap away at ${size.width.toInt()} px', (
      tester,
    ) async {
      await shell(tester, size: size);
      expect(find.byType(Drawer), findsNothing);
      await tester.tap(find.byIcon(CupertinoIcons.sidebar_left));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsOneWidget);
      await tester.tap(
        find.descendant(of: find.byType(Drawer), matching: find.text('Sent')),
      );
      await tester.pumpAndSettle();
      expect(c.read(queryProvider), 'in:sent');
      expect(find.byType(Drawer), findsNothing, reason: 'closed after a pick');
      expect(tester.takeException(), isNull);
    });
  }

  for (final w in <double>[360, 480, 700, 820, 1024, 1100, 1280, 1600]) {
    testWidgets('nothing overflows at ${w.toInt()} px', (tester) async {
      await shell(tester, size: Size(w, 760));
      final all = await repo.threads('');
      c.read(selectedThreadIdProvider.notifier).select(all[1].id);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('older mail and server search sit at the foot of the list', (
    tester,
  ) async {
    await shell(tester);
    repo.olderOnServer = 5;
    expect(find.text('Load older mail'), findsOneWidget);
    await tester.tap(find.text('Load older mail'));
    await tester.pumpAndSettle();
    expect(c.read(noticeProvider), '5 older messages');
    expect(find.text('All mail is here'), findsOneWidget);

    c.read(queryProvider.notifier).set('from:anna invoice');
    await tester.pumpAndSettle();
    expect(find.text('Search on the server'), findsOneWidget);
    await tester.tap(find.text('Search on the server'));
    await tester.pumpAndSettle();
    expect(c.read(noticeProvider), 'Nothing more on the server');

    // Kept on this device: nothing to fetch.
    for (final q in ['in:snoozed', '#work']) {
      c.read(queryProvider.notifier).set(q);
      await tester.pumpAndSettle();
      expect(find.byType(MoreFromServer), findsNothing, reason: q);
    }
    await settle(tester);
  });

  testWidgets('a filter narrows the folder instead of leaving it', (
    tester,
  ) async {
    await shell(tester);
    Finder chip(String label) => find.descendant(
      of: find.byType(ThreadListBody),
      matching: find.text(label),
    );
    c.read(queryProvider.notifier).set('in:archive');
    await tester.pumpAndSettle();
    await tester.tap(chip('Unread'));
    await tester.pumpAndSettle();
    expect(c.read(queryProvider), 'in:archive is:unread');
    await tester.tap(chip('All'));
    await tester.pumpAndSettle();
    expect(c.read(queryProvider), 'in:archive');
    // Another folder from elsewhere: the filter that belonged to the last one goes.
    await tester.tap(chip('Starred'));
    await tester.pumpAndSettle();
    c.read(queryProvider.notifier).set('in:sent');
    await tester.pumpAndSettle();
    await tester.tap(chip('Unread'));
    await tester.pumpAndSettle();
    expect(c.read(queryProvider), 'in:sent is:unread');
  });

  testWidgets('a wide window shows the sidebar itself', (tester) async {
    await shell(tester);
    expect(find.byIcon(CupertinoIcons.sidebar_left), findsNothing);
  });

  testWidgets('the palette takes at most 60% of the window', (tester) async {
    await shell(tester, size: const Size(1280, 500));
    c.read(paletteOpenProvider.notifier).open();
    await tester.pumpAndSettle();
    final box = tester.getRect(
      find
          .descendant(
            of: find.byType(CommandPalette),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(box.height, lessThanOrEqualTo(500 * 0.6 + 0.5));
    expect(tester.takeException(), isNull);
  });
}
