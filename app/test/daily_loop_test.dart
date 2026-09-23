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
    await tester.enterText(
      find.widgetWithText(TextField, 'Reply to ${first.participants.first}'),
      'half-written',
    );

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
    await tester.enterText(
      find.widgetWithText(TextField, 'Reply to ${all[0].participants.first}'),
      'for the first thread',
    );
    c.read(selectedThreadIdProvider.notifier).select(all[1].id);
    await tester.pumpAndSettle();
    expect(find.text('for the first thread'), findsNothing);
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
