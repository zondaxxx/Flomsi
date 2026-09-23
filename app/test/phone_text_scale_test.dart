import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/mock_repository.dart';
import 'package:mail_app/features/phone/phone_shell.dart';
import 'package:mail_app/features/phone/phone_thread_screen.dart';
import 'package:mail_app/platform.dart';
import 'package:mail_app/theme/surfaces.dart';
import 'package:mail_app/state/providers.dart';
import 'package:mail_app/theme/tokens.dart';

/// Large system text on small phones: nothing on the mail screen may overflow.
void main() {
  setUp(rootBundle.clear);
  tearDown(() => debugTouchOverride = null);

  // The app's own type, so widths are the ones people see.
  setUpAll(() async {
    await (FontLoader(kSans)
          ..addFont(rootBundle.load('assets/fonts/IBMPlexSans-Variable.ttf')))
        .load();
    await (FontLoader(
      kMono,
    )..addFont(rootBundle.load('assets/fonts/IBMPlexMono-Regular.ttf'))).load();
  });

  Future<ProviderContainer> pump(
    WidgetTester tester,
    double width,
    double scale,
  ) async {
    debugTouchOverride = true;
    tester.view.physicalSize = Size(width * 3, 700 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(
      overrides: [repositoryProvider.overrideWithValue(MockRepository())],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildTheme(Scheme.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const PhoneShell(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  // Conversations with attachments, several messages, long names.
  for (final width in [320.0, 390.0]) {
    testWidgets('a conversation at ${width.toInt()} wide and 2x text', (
      tester,
    ) async {
      final c = await pump(tester, width, 2);
      for (final id in [2, 5, 7, 9]) {
        c.read(openThreadProvider.notifier).open(id);
        await tester.pumpAndSettle();
        expect(find.byType(PhoneThreadScreen), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'thread $id');
        await tester.tap(find.text('More'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'thread $id menu');
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      }
      await tester.pump(const Duration(seconds: 3));
    });
  }

  testWidgets('every place on the bottom bar is at least 48 by 48', (
    tester,
  ) async {
    await pump(tester, 320, 1);
    for (final label in ['Mailboxes', 'Search', 'Unread', 'Compose']) {
      final slot = tester.getSize(
        find
            .ancestor(of: find.text(label), matching: find.byType(HoverRegion))
            .first,
      );
      expect(slot.width, greaterThanOrEqualTo(48), reason: label);
      expect(slot.height, greaterThanOrEqualTo(48), reason: label);
    }
    await tester.pump(const Duration(seconds: 3));
  });

  for (final width in [320.0, 390.0]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('${width.toInt()} wide at ${scale}x text', (tester) async {
        debugTouchOverride = true;
        tester.view.physicalSize = Size(width * 3, 700 * 3);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        final c = ProviderContainer(
          overrides: [repositoryProvider.overrideWithValue(MockRepository())],
        );
        addTearDown(c.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: c,
            child: MaterialApp(
              theme: buildTheme(Scheme.light),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: const PhoneShell(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // The account menu, More, the Mailboxes sheet and search.
        await tester.tap(find.textContaining('All accounts'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tapAt(const Offset(4, 400));
        await tester.pumpAndSettle();

        // The tap that closed the menu opened nothing under it.
        expect(find.byType(PhoneThreadScreen), findsNothing);

        await tester.tap(find.byTooltip('More'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tapAt(const Offset(4, 400));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Mailboxes'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Starred'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Search'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 3));
      });
    }
  }
}
