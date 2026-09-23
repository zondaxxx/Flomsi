import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/mock_repository.dart';
import 'package:mail_app/data/models.dart';
import 'package:mail_app/features/phone/phone_compose_screen.dart';
import 'package:mail_app/platform.dart';
import 'package:mail_app/state/providers.dart';
import 'package:mail_app/theme/app_icons.dart';
import 'package:mail_app/theme/tokens.dart';

const _fresh = Draft(accountId: 1, from: 'dev@gmail.com');

const _reply = Draft(
  accountId: 1,
  from: 'dev@gmail.com',
  to: ['Anna Petrova <anna@studio.dev>'],
  subject: 'Re: Design review',
  text: '\n\n> Moving it to 15:00',
  kind: DraftKind.reply,
);

const _files = [
  DraftAttachment(
    name: 'invoice.pdf',
    mime: 'application/pdf',
    size: 86016,
    messageId: 7,
    idx: 1,
  ),
  DraftAttachment(
    name: 'video.mov',
    mime: 'video/quicktime',
    size: 20 * 1024 * 1024,
    path: '/tmp/video.mov',
  ),
];

/// Stands in for PhoneShell: a draft set in [composeProvider] opens the composer screen.
class _Home extends ConsumerWidget {
  const _Home();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<Draft?>(composeProvider, (prev, next) {
      if (prev == null && next != null) openPhoneCompose(context, ref);
    });
    return const Scaffold(body: SizedBox.expand());
  }
}

void main() {
  late ProviderContainer c;
  late MockRepository repo;
  tearDown(() => debugTouchOverride = null);

  // The app's own type, so widths are the ones people see (labels that fit or break).
  setUpAll(() async {
    await (FontLoader(kSans)
          ..addFont(rootBundle.load('assets/fonts/IBMPlexSans-Variable.ttf')))
        .load();
    await (FontLoader(
      kMono,
    )..addFont(rootBundle.load('assets/fonts/IBMPlexMono-Regular.ttf'))).load();
  });

  /// The stand-in list screen, with nothing open over it yet.
  Future<void> start(
    WidgetTester tester, {
    MockRepository? using,
    double textScale = 1,
  }) async {
    debugTouchOverride = true;
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
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
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const _Home(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(
    WidgetTester tester, {
    Draft draft = _fresh,
    MockRepository? using,
    double textScale = 1,
  }) async {
    await start(tester, using: using, textScale: textScale);
    c.read(composeProvider.notifier).open(draft);
    await tester.pumpAndSettle();
  }

  /// The row that [label] names, and the field in it.
  Finder row(String label) =>
      find.ancestor(of: find.text(label), matching: find.byType(Row)).first;
  Finder field(String label) =>
      find.descendant(of: row(label), matching: find.byType(TextField));
  Finder body() => find.byType(TextField).last;
  TextField widgetOf(WidgetTester tester, Finder f) =>
      tester.widget<TextField>(f);

  Finder sendButton() => find.byType(FilledButton);
  Finder iconButton(IconData icon) =>
      find.ancestor(of: find.byIcon(icon), matching: find.byType(IconButton));

  /// The accessory bar over the keyboard.
  Finder accessoryBar() => find
      .ancestor(
        of: find.byTooltip('Attach files'),
        matching: find.byWidgetPredicate(
          (w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color == Scheme.dark.bg2,
        ),
      )
      .first;
  bool sendEnabled(WidgetTester tester) =>
      tester.widget<FilledButton>(sendButton()).enabled;

  Future<List<Draft>> stored() => repo.drafts();

  /// Type into a field and wait out the autosave pause.
  Future<void> type(WidgetTester tester, Finder f, String text) async {
    await tester.enterText(f, text);
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'a new message: its title, From with several accounts, fields that tell the keyboard what they hold',
    (tester) async {
      await open(tester);
      expect(find.text('New message'), findsOneWidget);
      // The system bars match the page: its status bar, and bg2 under the accessory bar.
      final style = tester
          .widget<AppBar>(find.byType(AppBar))
          .systemOverlayStyle!;
      expect(style.statusBarColor, Colors.transparent);
      expect(style.systemNavigationBarColor, Scheme.dark.bg2);
      expect(find.text('From'), findsOneWidget);
      expect(
        find.descendant(of: row('From'), matching: find.text('dev@gmail.com')),
        findsOneWidget,
      );
      // Read-only: nothing to type in.
      expect(
        find.descendant(of: row('From'), matching: find.byType(TextField)),
        findsNothing,
      );

      final to = widgetOf(tester, field('To'));
      expect(to.keyboardType, TextInputType.emailAddress);
      expect(to.textInputAction, TextInputAction.next);
      expect(to.focusNode!.hasFocus, isTrue);
      final subject = widgetOf(tester, field('Subject'));
      expect(subject.textCapitalization, TextCapitalization.sentences);
      expect(subject.textInputAction, TextInputAction.next);
      final text = widgetOf(tester, body());
      expect(text.maxLines, isNull);
      expect(text.enableSuggestions, isTrue);
      expect(text.style!.fontSize, 16);
      expect(text.style!.height, 1.55);

      // Next goes down the fields, past the Cc button.
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pump();
      expect(widgetOf(tester, field('Subject')).focusNode!.hasFocus, isTrue);
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pump();
      expect(widgetOf(tester, body()).focusNode!.hasFocus, isTrue);
    },
  );

  testWidgets('with one account there is no From row', (tester) async {
    await open(tester, using: _OneAccount());
    expect(find.text('From'), findsNothing);
    expect(find.text('To'), findsOneWidget);
  });

  testWidgets('Send waits for an address; 36 to see, 48 to press', (
    tester,
  ) async {
    await open(tester);
    expect(sendEnabled(tester), isFalse);
    await tester.enterText(field('To'), 'anna');
    await tester.pump();
    expect(sendEnabled(tester), isFalse);
    await tester.enterText(field('To'), 'anna@studio.dev');
    await tester.pump();
    expect(sendEnabled(tester), isTrue);

    expect(tester.getSize(sendButton()).height, 48);
    final visual = find.descendant(
      of: sendButton(),
      matching: find.byType(Material),
    );
    expect(tester.getSize(visual.first).height, 36);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('Cc slides in under To and takes the focus', (tester) async {
    await open(tester);
    expect(find.text('Cc'), findsOneWidget); // the button
    await tester.tap(find.widgetWithText(TextButton, 'Cc'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final size = tester.widget<SizeTransition>(
      find.ancestor(of: row('Cc'), matching: find.byType(SizeTransition)),
    );
    expect(size.sizeFactor.value, inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextButton, 'Cc'), findsNothing);
    final cc = widgetOf(tester, field('Cc'));
    expect(cc.focusNode!.hasFocus, isTrue);
    expect(cc.keyboardType, TextInputType.emailAddress);
    // Next from To now goes to Cc.
    widgetOf(tester, field('To')).focusNode!.requestFocus();
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    expect(widgetOf(tester, field('Cc')).focusNode!.hasFocus, isTrue);
  });

  testWidgets('a reply: its title, and the cursor at the top of the body', (
    tester,
  ) async {
    await open(tester, draft: _reply);
    expect(find.text('Reply'), findsOneWidget);
    expect(sendEnabled(tester), isTrue);
    final text = widgetOf(tester, body());
    expect(text.focusNode!.hasFocus, isTrue);
    expect(
      text.controller!.selection,
      const TextSelection.collapsed(offset: 0),
    );
  });

  testWidgets(
    'Close keeps what was typed and says so; untouched, it just closes',
    (tester) async {
      await open(tester);
      final before = (await stored()).length;
      await type(tester, field('To'), 'bob@x.dev');
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(PhoneComposeScreen), findsNothing);
      expect(c.read(composeProvider), isNull);
      expect(c.read(noticeProvider), 'Draft saved');
      expect((await stored()).length, before + 1);
      expect((await stored()).first.to, ['bob@x.dev']);
      await tester.pump(const Duration(seconds: 3));

      c.read(composeProvider.notifier).open(_reply);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(PhoneComposeScreen), findsNothing);
      expect(c.read(noticeProvider), isNull);
      expect((await stored()).length, before + 1);
    },
  );

  testWidgets('Android back closes it the same way', (tester) async {
    await open(tester);
    await tester.enterText(field('Subject'), 'Plans');
    await tester.pump(); // no autosave pause: back saves it
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(PhoneComposeScreen), findsNothing);
    expect(c.read(noticeProvider), 'Draft saved');
    expect((await stored()).first.subject, 'Plans');
    await tester.pump(const Duration(seconds: 3));

    // The next new message still opens.
    c.read(composeProvider.notifier).open(_fresh);
    await tester.pumpAndSettle();
    expect(find.byType(PhoneComposeScreen), findsOneWidget);
  });

  testWidgets('a draft that cannot be saved does not close', (tester) async {
    final full = _CannotSave();
    await open(tester, using: full);
    await type(tester, field('To'), 'bob@x.dev');
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(PhoneComposeScreen), findsOneWidget);
    expect(find.textContaining('Draft not saved'), findsOneWidget);
    full.failing = false; // the page is taken down with the test and saves then
  });

  testWidgets('Send: Sending… while it goes, then the page closes', (
    tester,
  ) async {
    await open(tester);
    final before = (await stored()).length;
    await type(tester, field('To'), 'bob@x.dev');
    expect((await stored()).length, before + 1);
    await tester.tap(sendButton());
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Sending…'), findsOneWidget);
    expect(sendEnabled(tester), isFalse);
    // Nothing to discard while it is on its way.
    expect(
      tester.widget<IconButton>(iconButton(AppIcons.delete)).onPressed,
      isNull,
    );
    // Close and back wait for it too: leaving now would hide whether it went.
    expect(
      tester.widget<IconButton>(iconButton(AppIcons.close)).onPressed,
      isNull,
    );
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(PhoneComposeScreen), findsOneWidget);
    expect(c.read(noticeProvider), isNull);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.byType(PhoneComposeScreen), findsNothing);
    expect(c.read(noticeProvider), 'Sent to bob@x.dev');
    expect((await stored()).length, before);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets(
    'a failed send stays, says why on one line, until the next edit',
    (tester) async {
      await open(tester, using: _Refused());
      await tester.enterText(field('To'), 'bob@x.dev');
      await tester.pump();
      await tester.tap(sendButton());
      await tester.pumpAndSettle();
      expect(find.byType(PhoneComposeScreen), findsOneWidget);
      const why = 'Could not reach the server: Connection refused';
      expect(find.text(why), findsOneWidget);
      expect(find.byIcon(AppIcons.error), findsOneWidget);
      expect(sendEnabled(tester), isTrue);
      // Its own line above the bar; the bar stays 48.
      expect(tester.getSize(accessoryBar()).height, Touch.target);
      expect(
        tester.getBottomLeft(find.text(why)).dy,
        lessThanOrEqualTo(tester.getTopLeft(accessoryBar()).dy),
      );

      await tester.enterText(field('Subject'), 'Again');
      await tester.pumpAndSettle();
      expect(find.text(why), findsNothing);
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets('Discard asks first; then the draft is gone', (tester) async {
    await open(tester);
    final before = (await stored()).length;
    await type(tester, field('To'), 'bob@x.dev');
    expect((await stored()).length, before + 1);

    await tester.tap(find.byTooltip('Discard draft'));
    await tester.pumpAndSettle();
    expect(find.text('Discard this draft?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.byType(PhoneComposeScreen), findsOneWidget);
    expect((await stored()).length, before + 1);

    await tester.tap(find.byTooltip('Discard draft'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.byType(PhoneComposeScreen), findsNothing);
    expect((await stored()).length, before);
    expect(c.read(noticeProvider), 'Draft discarded');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a draft that cannot be discarded stays, and says so', (
    tester,
  ) async {
    await open(tester, using: _CannotDelete());
    await type(tester, field('To'), 'bob@x.dev');
    await tester.tap(find.byTooltip('Discard draft'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.byType(PhoneComposeScreen), findsOneWidget);
    expect(find.textContaining('Draft not discarded'), findsOneWidget);

    // Close still works, and keeps it.
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(PhoneComposeScreen), findsNothing);
    expect(c.read(noticeProvider), 'Draft saved');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('Close finishing under the Discard question takes both away', (
    tester,
  ) async {
    final slow = _SlowSave();
    await open(tester, using: slow);
    await tester.enterText(field('To'), 'bob@x.dev');
    await tester.pump();
    slow.gate = Completer();
    await tester.tap(find.byTooltip('Close')); // saving, slowly
    await tester.pump();
    await tester.tap(find.byTooltip('Discard draft'));
    await tester.pumpAndSettle();
    expect(find.text('Discard this draft?'), findsOneWidget);

    slow.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Discard this draft?'), findsNothing);
    expect(find.byType(PhoneComposeScreen), findsNothing);
    expect(c.read(composeProvider), isNull);
    expect(c.read(noticeProvider), 'Draft saved');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('taken away from elsewhere, it leaves the page under it', (
    tester,
  ) async {
    await start(tester);
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('A conversation')),
      ),
    );
    await tester.pumpAndSettle();
    c.read(composeProvider.notifier).open(_reply);
    await tester.pumpAndSettle();
    expect(find.byType(PhoneComposeScreen), findsOneWidget);

    // Something pops the composer without asking it (a tapped notification, say).
    nav.pop();
    await tester.pumpAndSettle();
    expect(find.byType(PhoneComposeScreen), findsNothing);
    expect(c.read(composeProvider), isNull);
    expect(find.text('A conversation'), findsOneWidget);
  });

  for (final scale in [1.3, 2.0]) {
    testWidgets('at ${scale}x text nothing overflows and no label breaks', (
      tester,
    ) async {
      const all = Draft(
        accountId: 1,
        from: 'dev@gmail.com',
        to: ['anna@studio.dev'],
        cc: ['lee@studio.dev'],
        subject: 'Fwd: Invoice',
        kind: DraftKind.forward,
        attachments: _files,
      );
      await open(tester, draft: all, textScale: scale);
      expect(tester.takeException(), isNull);
      final line = 15 * scale * 1.45;
      for (final label in ['From', 'To', 'Cc', 'Subject']) {
        expect(
          tester.getSize(find.text(label)).height,
          lessThan(line * 1.5),
          reason: '$label on one line',
        );
      }
      await tester.pump(const Duration(seconds: 1));
    });
  }

  testWidgets('"Saved" once a pause in typing is stored, gone while typing', (
    tester,
  ) async {
    await open(tester);
    double saved() => tester
        .widget<AnimatedOpacity>(
          find.ancestor(
            of: find.text('Saved'),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;
    expect(saved(), 0);
    await type(tester, field('To'), 'bob@x.dev');
    expect(saved(), 1);
    await tester.enterText(field('Subject'), 'Hi');
    await tester.pump();
    expect(saved(), 0);
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    expect(saved(), 1);
  });

  testWidgets('files are rows with their size; the 25 MB warning', (
    tester,
  ) async {
    const forward = Draft(
      accountId: 1,
      from: 'dev@gmail.com',
      subject: 'Fwd: Invoice',
      kind: DraftKind.forward,
      attachments: _files,
    );
    await open(tester, draft: forward);
    expect(find.text('Forward'), findsOneWidget);
    expect(find.text('invoice.pdf'), findsOneWidget);
    expect(find.text('84 KB'), findsOneWidget);
    expect(find.text('video.mov'), findsOneWidget);
    expect(find.text('20 MB'), findsOneWidget);
    expect(find.textContaining('most servers refuse'), findsOneWidget);
    final rowHeight = tester
        .getSize(
          find
              .ancestor(
                of: find.text('invoice.pdf'),
                matching: find.byType(Row),
              )
              .first,
        )
        .height;
    expect(rowHeight, greaterThanOrEqualTo(56));

    await tester.tap(find.byTooltip('Remove video.mov'));
    await tester.pumpAndSettle();
    expect(find.text('video.mov'), findsNothing);
    expect(find.textContaining('most servers refuse'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
    'the title is centred on iOS and follows Close on Android',
    (tester) async {
      await open(tester, draft: _reply);
      final title = find.text('Reply');
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        expect(tester.getCenter(title).dx, moreOrLessEquals(195, epsilon: 1));
      } else {
        // After the 56 of Close and the toolbar's 16.
        expect(tester.getTopLeft(title).dx, 72);
      }
      expect(find.byIcon(AppIcons.close), findsOneWidget);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );
}

class _OneAccount extends MockRepository {
  @override
  Future<List<Account>> accounts() async => [(await super.accounts()).first];
}

class _Refused extends MockRepository {
  @override
  Future<String?> send(Draft draft) async => throw const Problem(
    kind: 'net',
    title: 'Could not reach the server',
    detail: 'Connection refused',
  );
}

class _CannotSave extends MockRepository {
  bool failing = true;

  @override
  Future<int> saveDraft(Draft draft) async =>
      failing ? throw StateError('disk full') : super.saveDraft(draft);
}

class _CannotDelete extends MockRepository {
  @override
  Future<void> deleteDraft(int localId) async => throw StateError('disk full');
}

/// Saves wait for [gate] while one is set.
class _SlowSave extends MockRepository {
  Completer<void>? gate;

  @override
  Future<int> saveDraft(Draft draft) async {
    await gate?.future;
    return super.saveDraft(draft);
  }
}
