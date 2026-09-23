import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/mock_repository.dart';
import 'package:mail_app/data/models.dart';
import 'package:mail_app/features/attachments/attachment_chip.dart';
import 'package:mail_app/features/shell/editor_shell.dart';
import 'package:mail_app/features/thread/mail_colours.dart';
import 'package:mail_app/state/providers.dart';
import 'package:mail_app/theme/tokens.dart';

/// Counts what the chip asks of the repository.
class _Watching extends MockRepository {
  int opened = 0;
  @override
  Future<String> openAttachment(a) async {
    opened++;
    return '/tmp/${a.name}';
  }
}

/// Thread 2 with a later message from someone with a long name and a long address.
class _LongSender extends _Watching {
  @override
  Future<List<Message>> messages(int threadId) async {
    final all = await super.messages(threadId);
    if (threadId != 2) return all;
    final last = all.last;
    return [
      ...all.take(all.length - 1),
      Message(
        id: last.id,
        threadId: last.threadId,
        fromName: 'Anastasia Petrova-Vodkina Sokolova-Smirnova',
        fromAddr: 'anastasia.petrova.sokolova@company-example-longdomain.com',
        to: ['Zondaxxx Developer', 'Anna Sokolova'],
        date: last.date,
        text: last.text,
      ),
    ];
  }
}

void main() {
  late ProviderContainer c;
  late _Watching repo;
  setUp(rootBundle.clear);

  Future<void> open(WidgetTester tester, int threadId) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    repo = _Watching();
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
    c.read(selectedThreadIdProvider.notifier).select(threadId);
    await tester.pumpAndSettle();
  }

  /// The page styled mail sits on (a message's own white table has no rounded border).
  Finder paper() => find.byWidgetPredicate(
    (w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        (w.decoration! as BoxDecoration).color == const Color(0xFFFFFFFF) &&
        (w.decoration! as BoxDecoration).borderRadius ==
            BorderRadius.circular(4),
  );

  testWidgets('a newsletter with its own colours is shown on paper', (
    tester,
  ) async {
    await open(tester, 8); // dark text on white
    expect(paper(), findsOneWidget);
    expect(
      find.textContaining('Top stories', findRichText: true),
      findsWidgets,
    );
    await open(tester, 9); // white text on a dark table
    expect(paper(), findsOneWidget);
  });

  testWidgets('plain mail keeps the theme', (tester) async {
    await open(tester, 7);
    expect(
      find.textContaining('your invoice for', findRichText: true),
      findsWidgets,
    );
    expect(paper(), findsNothing);
    expect(find.byType(SelectionArea), findsOneWidget);
  });

  testWidgets('a file that can run code asks first and never opens', (
    tester,
  ) async {
    await open(tester, 9);
    // The extension after the name, and the red tag.
    expect(find.text('.svg'), findsNWidgets(2));
    await tester.tap(find.byType(AttachmentChip));
    await tester.pumpAndSettle();
    expect(find.text('This is a .svg file'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('This is a .svg file'), findsNothing);
    expect(repo.opened, 0);

    // An ordinary file has no tag.
    await open(tester, 7);
    expect(find.text('.pdf'), findsOneWidget);
  });

  Finder hint(String text) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.hintText == text,
  );

  testWidgets('the quick reply says who it goes to, address included', (
    tester,
  ) async {
    await open(tester, 7);
    expect(hint('Reply to Hetzner <billing@hetzner.com>'), findsOneWidget);
    // The last message is ours: the reply goes to its recipients, as the core sends it.
    await open(tester, 2);
    expect(hint('Reply to Anna Sokolova'), findsOneWidget);
  });

  testWidgets('a long sender line fits a phone without hiding the address', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    repo = _LongSender();
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
    // A phone opens the thread on its own page when its row is tapped.
    await tester.tap(
      find.textContaining('Design review Thursday', findRichText: true).first,
    );
    await tester.pumpAndSettle();
    final address = find.textContaining('<anastasia.petrova');
    expect(address, findsOneWidget);
    expect(tester.getRect(address).right, lessThanOrEqualTo(375));
    expect(tester.takeException(), isNull);
  });

  test('long names are cut in the middle, never at the extension', () {
    const disguised = 'invoice-2026-09-final-final-version.pdf.exe';
    final short = middleEllipsis(disguised);
    expect(short.length, lessThanOrEqualTo(34));
    expect(short, endsWith('.exe'));
    expect(short, contains('…'));
    expect(middleEllipsis('report.pdf'), 'report.pdf');
    // Whole characters only: an emoji is never cut in half.
    final emoji = middleEllipsis(
      'Q3 report final 📊📊📊📊📊📊📊📊 v2 approved and signed.pdf',
    );
    expect(emoji, endsWith('.pdf'));
    expect(emoji.runes.every((r) => r < 0xD800 || r > 0xDFFF), isTrue);
    expect(emoji.characters.length, lessThanOrEqualTo(34));
  });

  test('mail colours are read the way the reading pane needs them', () {
    expect(htmlColour('#FFF'), '#fff');
    expect(htmlColour('336699'), '#336699');
    expect(htmlColour('Navy'), 'navy');
    expect(htmlColour('red" onclick="x'), isNull);
    expect(
      styleValue('color: #333; background: #000', 'background-color'),
      '#000',
    );
    expect(styleValue('background-color:navy', 'background-color'), 'navy');
    expect(styleValue('font-size: 12px', 'color'), isNull);
    expect(isDarkColour('#000'), isTrue);
    expect(isDarkColour('navy'), isTrue);
    expect(isDarkColour('rgb(20, 20, 20)'), isTrue);
    expect(isDarkColour('#f4f4f4'), isFalse);
    expect(isDarkColour('white'), isFalse);
    expect(isDarkColour('linear-gradient(red, blue)'), isFalse);
  });
}
