import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models.dart';
import 'package:mail_app/features/compose/compose_body.dart';
import 'package:mail_app/features/list/thread_list.dart';
import 'package:mail_app/features/shell/editor_shell.dart';
import 'package:mail_app/state/providers.dart';
import 'package:mail_app/theme/tokens.dart';

Widget _app(ProviderContainer c, Widget home) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(theme: buildTheme(Scheme.dark), home: home),
);

Widget _composer(Draft d) => Scaffold(body: ComposeBody(draft: d));

const _fresh = Draft(accountId: 1, from: 'me@x.dev');

void main() {
  late ProviderContainer c;
  setUp(() => c = ProviderContainer());
  tearDown(() => c.dispose());

  /// Let the notice fade out so no timer outlives the test.
  Future<void> settleNotices(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 3));

  Future<List<Draft>> stored() => c.read(repositoryProvider).drafts();

  Future<void> typeRecipient(WidgetTester tester, String to) async {
    await tester.enterText(find.byType(TextField).first, to);
    await tester.pump(const Duration(milliseconds: 800)); // autosave pause
    await tester.pumpAndSettle();
  }

  testWidgets('typing autosaves and closing keeps the draft', (tester) async {
    final before = (await stored()).length;
    await tester.pumpWidget(_app(c, _composer(_fresh)));
    await tester.pumpAndSettle();

    await typeRecipient(tester, 'anna@studio.dev');
    final drafts = await stored();
    expect(drafts.length, before + 1);
    expect(drafts.first.to, ['anna@studio.dev']);
    expect(find.textContaining('saved '), findsOneWidget);

    await tester.tap(find.byIcon(CupertinoIcons.xmark));
    await tester.pumpAndSettle();
    expect(c.read(noticeProvider), 'Draft saved');
    expect((await stored()).length, before + 1);
    await settleNotices(tester);
  });

  testWidgets('an untouched reply leaves nothing behind', (tester) async {
    final before = (await stored()).length;
    const reply = Draft(
      accountId: 1,
      from: 'me@x.dev',
      to: ['anna@studio.dev'],
      subject: 'Re: Design review',
      text: '\n\n> Moving it to 15:00',
      kind: DraftKind.reply,
    );
    await tester.pumpWidget(_app(c, _composer(reply)));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byIcon(CupertinoIcons.xmark));
    await tester.pumpAndSettle();
    expect((await stored()).length, before);
    expect(c.read(noticeProvider), isNull);
  });

  testWidgets('discard deletes the stored draft', (tester) async {
    final before = (await stored()).length;
    await tester.pumpWidget(_app(c, _composer(_fresh)));
    await tester.pumpAndSettle();
    await typeRecipient(tester, 'bob@x.dev');
    expect((await stored()).length, before + 1);

    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect((await stored()).length, before);
    expect(c.read(noticeProvider), 'Draft discarded');
    await settleNotices(tester);
  });

  testWidgets('sending removes the stored draft', (tester) async {
    final before = (await stored()).length;
    await tester.pumpWidget(_app(c, _composer(_fresh)));
    await tester.pumpAndSettle();
    await typeRecipient(tester, 'bob@x.dev');
    expect((await stored()).length, before + 1);

    await tester.tap(find.text('Send'));
    await tester.pump(
      const Duration(milliseconds: 600),
    ); // the mock's send delay
    await tester.pumpAndSettle();
    expect((await stored()).length, before);
    expect(c.read(noticeProvider), 'Sent to bob@x.dev');
    await settleNotices(tester);
  });

  testWidgets('the Drafts mailbox lists saved drafts and reopens them', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(c, const EditorShell()));
    await tester.pumpAndSettle();
    c.read(queryProvider.notifier).set('in:drafts');
    await tester.pumpAndSettle();

    expect(find.byType(DraftRow), findsOneWidget);
    expect(
      find.text('Sidebar contrast numbers'),
      findsNothing,
    ); // subject is a span
    await tester.tap(find.byType(DraftRow));
    await tester.pumpAndSettle();
    expect(find.byType(ComposeBody), findsOneWidget);
    final subject = tester
        .widgetList<TextField>(
          find.descendant(
            of: find.byType(ComposeBody),
            matching: find.byType(TextField),
          ),
        )
        .map((f) => f.controller?.text)
        .toList();
    expect(subject, contains('Sidebar contrast numbers'));
  });
}
