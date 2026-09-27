import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/mock_repository.dart';
import 'package:mail_app/data/models.dart';
import 'package:mail_app/features/list/thread_list.dart';
import 'package:mail_app/features/palette/command_palette.dart';
import 'package:mail_app/features/sidebar/sidebar_model.dart';
import 'package:mail_app/features/shell/editor_shell.dart';
import 'package:mail_app/main.dart';
import 'package:mail_app/platform.dart';
import 'package:mail_app/state/providers.dart';
import 'package:mail_app/theme/tokens.dart';

void main() {
  late ProviderContainer c;
  late MockRepository repo;
  setUp(rootBundle.clear);
  tearDown(() => debugTouchOverride = null);

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
  }

  group('on a computer', () {
    Future<void> shell(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 820);
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
      await tester.pumpAndSettle();
    }

    testWidgets(
      'the sidebar lists your folders; one opened the first time is read',
      (tester) async {
        await shell(tester);
        expect(find.text('FOLDERS'), findsOneWidget);
        expect(find.text('Projects / Flomsi'), findsOneWidget);
        // Never opened: read from the server while the list already shows it.
        repo.binGate = Completer<void>();
        await tester.tap(find.text('Receipts'));
        await tester.pump();
        expect(c.read(queryProvider), 'folder:105');
        expect(c.read(openingFolderProvider), 105);
        expect(repo.openedFolders, [105]);
        repo.binGate!.complete();
        await tester.pumpAndSettle();
        expect(c.read(openingFolderProvider), isNull);
        // The title names the folder.
        expect(find.text('RECEIPTS'), findsWidgets);
        await settle(tester);
      },
    );

    testWidgets('a folder synced already opens without a trip to the server', (
      tester,
    ) async {
      await shell(tester);
      await tester.tap(find.text('Projects / Flomsi'));
      await tester.pumpAndSettle();
      expect(c.read(queryProvider), 'folder:104');
      expect(repo.openedFolders, isEmpty);
      await settle(tester);
    });

    testWidgets('Move to… from a folder offers every other folder', (
      tester,
    ) async {
      await shell(tester);
      await tester.tap(find.text('Travel'));
      await tester.pumpAndSettle();
      final t = (await repo.threads('folder:106')).first;
      c.read(selectedThreadIdProvider.notifier).select(t.id);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Move  l'));
      await tester.pumpAndSettle();
      final picker = find.byType(CommandPalette);
      expect(
        find.descendant(of: picker, matching: find.text('Receipts')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: picker, matching: find.text('Travel')),
        findsNothing,
      );
      // Moved out of the folder on screen (on Gmail: out of that label).
      await tester.tap(
        find.descendant(of: picker, matching: find.text('Receipts')),
      );
      await tester.pumpAndSettle();
      expect(repo.movedFrom, [106]);
      await settle(tester);
    });

    testWidgets(
      'a folder opened from the drawer finishes after the drawer closed',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 820);
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
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Folders and accounts'));
        await tester.pumpAndSettle();
        repo.binGate = Completer<void>();
        await tester.tap(find.text('Travel'));
        await tester.pumpAndSettle();
        expect(c.read(openingFolderProvider), 106);
        repo.binGate!.complete();
        await tester.pumpAndSettle();
        expect(c.read(openingFolderProvider), isNull);
        expect(tester.takeException(), isNull);
        await settle(tester);
      },
    );

    test('a folder view offers older mail, not a server search', () {
      expect(MoreFromServer.folderView('folder:106'), isTrue);
      expect(MoreFromServer.searching('folder:106'), isFalse);
      expect(MoreFromServer.searching('folder:106 invoice'), isTrue);
    });

    test('another account from a folder view starts at its Inbox', () {
      expect(
        mailboxQuery(FolderRole.other, 'me@icloud.com'),
        'account:me@icloud.com',
      );
      expect(mailboxQuery(FolderRole.other, null), '');
    });

    testWidgets('a folder that cannot be read says so', (tester) async {
      await shell(tester);
      final fail = _FailingRepo();
      repo = fail;
      c = ProviderContainer(
        overrides: [repositoryProvider.overrideWithValue(fail)],
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
      await tester.pumpAndSettle();
      await tester.tap(find.text('Travel'));
      await tester.pumpAndSettle();
      expect(c.read(noticeProvider), 'Could not read Travel: No connection');
      expect(c.read(openingFolderProvider), isNull);
      await settle(tester);
    });
  });

  group('on a phone', () {
    Future<void> start(WidgetTester tester) async {
      debugTouchOverride = true;
      tester.view.physicalSize = const Size(390, 844) * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      repo = MockRepository();
      c = ProviderContainer(
        overrides: [repositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(container: c, child: const MailApp()),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('Mailboxes lists your folders; a new one reads, then shows', (
      tester,
    ) async {
      await start(tester);
      await tester.tap(find.text('Mailboxes'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Travel'),
        100,
        scrollable: find
            .descendant(
              of: find.byType(DraggableScrollableSheet),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('Folders'), findsOneWidget);
      repo.binGate = Completer<void>();
      await tester.tap(find.text('Travel'));
      await tester.pumpAndSettle();
      expect(c.read(queryProvider), 'folder:106');
      expect(find.text('Travel'), findsWidgets);
      repo.binGate!.complete();
      await tester.pumpAndSettle();
      expect(repo.openedFolders, [106]);
      await settle(tester);
    });
  });
}

/// A folder that cannot be read: the connection is down.
class _FailingRepo extends MockRepository {
  @override
  Future<void> openFolder(Folder folder) async =>
      throw const Problem(kind: 'network', title: 'No connection');
}
