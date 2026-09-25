import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/mock_repository.dart';
import 'package:mail_app/data/models.dart';
import 'package:mail_app/features/palette/command_palette.dart';
import 'package:mail_app/features/phone/phone_thread_screen.dart';
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

  const invoice = 'Your invoice for September';

  Future<int> idOf(String subject) async =>
      (await repo.threads('')).firstWhere((t) => t.subject == subject).id;

  /// Wait out the notice so no timer is left running.
  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
  }

  group('on a computer', () {
    Future<void> shell(WidgetTester tester, String query) async {
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
      c.read(queryProvider.notifier).set(query);
      await tester.pumpAndSettle();
    }

    Finder tool(String label) => find.byWidgetPredicate(
      (w) => w is Tooltip && (w.message ?? '').startsWith(label),
    );

    testWidgets('in Trash, Delete asks first, then deletes for good', (
      tester,
    ) async {
      await shell(tester, 'in:trash');
      final id = await idOf(invoice);
      c.read(selectedThreadIdProvider.notifier).select(id);
      await tester.pumpAndSettle();
      await tester.tap(tool('Delete Forever'));
      await tester.pumpAndSettle();
      expect(find.text('Delete forever?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repo.deletedForever, isEmpty);

      await tester.tap(tool('Delete Forever'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete Forever').last);
      await tester.pumpAndSettle();
      expect(repo.deletedForever, [id]);
      expect(c.read(noticeProvider), 'Deleted forever');
      expect(c.read(selectedThreadIdProvider), isNot(id));
      await settle(tester);
    });

    testWidgets('Delete Forever on mail outside the bins asks nothing', (
      tester,
    ) async {
      await shell(tester, '');
      c.read(selectedThreadIdProvider.notifier).select(await idOf(invoice));
      await tester.pumpAndSettle();
      repo.foreverCount = 0;
      c.read(paletteOpenProvider.notifier).open();
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(CommandPalette),
          matching: find.byType(TextField),
        ),
        'delete forever',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete Forever'));
      await tester.pumpAndSettle();
      expect(find.text('Delete forever?'), findsNothing);
      expect(repo.deletedForever, isEmpty);
      expect(
        c.read(noticeProvider),
        'Only mail in Trash or Junk can be deleted forever',
      );
      await settle(tester);
    });

    testWidgets('outside Trash, Delete still moves to Trash', (tester) async {
      await shell(tester, '');
      c.read(selectedThreadIdProvider.notifier).select(await idOf(invoice));
      await tester.pumpAndSettle();
      expect(tool('Delete Forever'), findsNothing);
      expect(find.text('Empty Trash'), findsNothing);
      await tester.tap(tool('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete forever?'), findsNothing);
      expect(repo.deletedForever, isEmpty);
      expect(c.read(noticeProvider), 'Deleted');
      await settle(tester);
    });

    testWidgets('Empty Trash over the list empties the account on screen', (
      tester,
    ) async {
      await shell(tester, 'account:dev@gmail.com in:trash');
      await tester.tap(find.text('Empty Trash'));
      await tester.pumpAndSettle();
      expect(find.text('Empty Trash?'), findsOneWidget);
      expect(find.textContaining('on dev@gmail.com'), findsOneWidget);
      await tester.tap(find.text('Empty Trash').last);
      await tester.pumpAndSettle();
      // Read again first, emptied after the yes.
      expect(repo.calls, ['refresh 1', 'empty 1']);
      expect(repo.emptied, [(FolderRole.trash, 1)]);
      expect(c.read(noticeProvider), 'Trash emptied');
      await settle(tester);
    });

    testWidgets(
      'what checking turned up is in the question; a failed account is left',
      (tester) async {
        await shell(tester, 'account:.com in:trash');
        repo.binNotes[1] = [
          'Could not finish moving a message to Keep: the server says it does not exist',
        ];
        repo.binFails[3] = const Problem(
          kind: 'network',
          title: 'No connection',
        );
        await tester.tap(find.text('Empty Trash'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('on dev@gmail.com, me@icloud.com is deleted'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Could not finish moving a message to Keep'),
          findsOneWidget,
        );
        expect(
          find.textContaining('work@outlook.com: No connection'),
          findsOneWidget,
        );
        await tester.tap(find.text('Empty Trash').last);
        await tester.pumpAndSettle();
        expect(repo.emptied, [(FolderRole.trash, 1), (FolderRole.trash, 2)]);
        await settle(tester);
      },
    );

    testWidgets('the final word names what was emptied and what was not', (
      tester,
    ) async {
      await shell(tester, 'account:.com in:trash');
      repo.emptyFails[2] = const Problem(
        kind: 'changed',
        title: 'Trash changed since it was checked',
      );
      await tester.tap(find.text('Empty Trash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Empty Trash').last);
      await tester.pumpAndSettle();
      expect(
        c.read(noticeProvider),
        'Trash emptied on dev@gmail.com, work@outlook.com. Not emptied: '
        'me@icloud.com: Trash changed since it was checked',
      );
      await settle(tester);
    });

    testWidgets('over a search typed in Trash there is no Empty strip', (
      tester,
    ) async {
      await shell(tester, 'account:dev@gmail.com in:trash');
      expect(find.text('Empty Trash'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'invoice');
      await tester.pumpAndSettle();
      expect(find.text('Empty Trash'), findsNothing);
      await settle(tester);
    });

    testWidgets('nothing is asked or emptied when no bin could be read', (
      tester,
    ) async {
      await shell(tester, 'account:dev@gmail.com in:trash');
      repo.binFails[1] = const Problem(kind: 'network', title: 'No connection');
      await tester.tap(find.text('Empty Trash'));
      await tester.pumpAndSettle();
      expect(find.text('Empty Trash?'), findsNothing);
      expect(repo.emptied, isEmpty);
      expect(c.read(noticeProvider), contains('No connection'));
      await settle(tester);
    });

    testWidgets('part of an address empties the accounts it shows, no more', (
      tester,
    ) async {
      await shell(tester, 'account:.com in:trash');
      await tester.tap(find.text('Empty Trash'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'on dev@gmail.com, me@icloud.com, work@outlook.com',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Empty Trash').last);
      await tester.pumpAndSettle();
      expect(repo.emptied, [
        (FolderRole.trash, 1),
        (FolderRole.trash, 2),
        (FolderRole.trash, 3),
      ]);
      await settle(tester);

      repo.emptied.clear();
      c.read(queryProvider.notifier).set('account:icloud in:trash');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Empty Trash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Empty Trash').last);
      await tester.pumpAndSettle();
      expect(repo.emptied, [(FolderRole.trash, 2)]);
      await settle(tester);
    });

    testWidgets('the palette empties Junk on every account', (tester) async {
      await shell(tester, '');
      c.read(paletteOpenProvider.notifier).open();
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(CommandPalette),
          matching: find.byType(TextField),
        ),
        'empty junk',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Empty Junk'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'on dev@gmail.com, me@icloud.com, work@outlook.com',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Empty Junk').last);
      await tester.pumpAndSettle();
      expect(repo.emptied, [
        (FolderRole.junk, 1),
        (FolderRole.junk, 2),
        (FolderRole.junk, 3),
      ]);
      await settle(tester);
    });
  });

  group('on a phone', () {
    Future<void> start(WidgetTester tester, String query) async {
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
      c.read(queryProvider.notifier).set(query);
      await tester.pumpAndSettle();
    }

    testWidgets('Trash: More empties it, a row deletes forever', (
      tester,
    ) async {
      await start(tester, 'in:trash');
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Empty Trash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Empty Trash').last);
      await tester.pumpAndSettle();
      expect(repo.emptied, [
        (FolderRole.trash, 1),
        (FolderRole.trash, 2),
        (FolderRole.trash, 3),
      ]);
      await settle(tester);

      final id = await idOf(invoice);
      await tester.longPress(find.text(invoice));
      await tester.pumpAndSettle();
      // In Trash, Delete would have nowhere to go: the menu offers only this.
      expect(find.text('Delete'), findsNothing);
      await tester.tap(find.text('Delete forever'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete Forever'));
      await tester.pumpAndSettle();
      expect(repo.deletedForever, [id]);
      expect(c.read(noticeProvider), 'Deleted forever');
      await settle(tester);
    });

    testWidgets(
      'a restore still held for Undo is sent before Trash is emptied',
      (tester) async {
        await start(tester, 'in:trash');
        final id = await idOf(invoice);
        await tester.longPress(find.text(invoice));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Move to…'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('INBOX').last);
        await tester.pumpAndSettle();
        // Waiting for Undo: nothing has reached the repository yet.
        expect(repo.calls, isEmpty);
        await tester.tap(find.byTooltip('More'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Empty Trash'));
        await tester.pumpAndSettle();
        expect(repo.calls.first, 'move $id');
        await tester.tap(find.text('Empty Trash').last);
        await tester.pumpAndSettle();
        expect(
          repo.calls.indexOf('move $id'),
          lessThan(repo.calls.indexOf('empty 1')),
        );
        await settle(tester);
      },
    );

    testWidgets('nothing can be touched while Trash is being checked', (
      tester,
    ) async {
      await start(tester, 'in:trash');
      repo.binGate = Completer<void>();
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Empty Trash'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Checking Trash with the server…'), findsOneWidget);
      await tester.longPress(find.text(invoice), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Move to…'), findsNothing);
      // A page opened over it meanwhile (a notification) is not what closes.
      unawaited(
        tester
            .state<NavigatorState>(find.byType(Navigator).first)
            .push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('on top')),
              ),
            ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      repo.binGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Checking Trash with the server…'), findsNothing);
      expect(find.text('on top', skipOffstage: false), findsOneWidget);
      expect(find.text('Empty Trash?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repo.emptied, isEmpty);
      await settle(tester);
    });

    testWidgets('the Inbox offers neither', (tester) async {
      await start(tester, '');
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      expect(find.text('Empty Trash'), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.longPress(find.text(invoice));
      await tester.pumpAndSettle();
      expect(find.text('Delete'), findsOneWidget);
      expect(find.text('Delete forever'), findsNothing);
      await tester.binding.handlePopRoute();
      await settle(tester);
    });

    testWidgets('a Junk conversation is deleted forever from its page', (
      tester,
    ) async {
      await start(tester, 'in:junk');
      final id = await idOf(invoice);
      await tester.tap(find.text(invoice));
      await tester.pumpAndSettle();
      expect(find.byType(PhoneThreadScreen), findsOneWidget);
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete forever'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete Forever'));
      await tester.pumpAndSettle();
      expect(repo.deletedForever, [id]);
      expect(find.byType(PhoneThreadScreen), findsNothing);
      await settle(tester);
    });
  });
}
