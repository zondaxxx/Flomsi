// The phone screens the website shows, rendered with the app's own fonts and the iOS icons
// into PNGs (390 x 844 points at 2x). Runs only when asked; scripts/site_shots.sh turns them
// into the site's WebP files:
//
//   SITE_SHOTS=/some/dir flutter test test/site_shots_test.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/mock_repository.dart';
import 'package:mail_app/main.dart';
import 'package:mail_app/platform.dart';
import 'package:mail_app/state/providers.dart';

final _out = Platform.environment['SITE_SHOTS'];

Future<void> _font(String family, List<Future<ByteData>> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(f);
  }
  await loader.load();
}

Future<ByteData> _file(String path) async =>
    ByteData.sublistView(await File(path).readAsBytes());

void main() {
  setUpAll(() async {
    if (_out == null) return;
    TestWidgetsFlutterBinding.ensureInitialized();
    await _font('IBM Plex Sans', [
      rootBundle.load('assets/fonts/IBMPlexSans-Variable.ttf'),
      rootBundle.load('assets/fonts/IBMPlexSans-Italic-Variable.ttf'),
    ]);
    await _font('IBM Plex Mono', [
      rootBundle.load('assets/fonts/IBMPlexMono-Regular.ttf'),
      rootBundle.load('assets/fonts/IBMPlexMono-Medium.ttf'),
      rootBundle.load('assets/fonts/IBMPlexMono-SemiBold.ttf'),
    ]);
    await _font('packages/cupertino_icons/CupertinoIcons', [
      rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
    ]);
    final flutter = Platform.environment['FLUTTER_ROOT'];
    if (flutter != null) {
      await _font('MaterialIcons', [
        _file(
          '$flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ),
      ]);
    }
  });

  tearDown(() => debugTouchOverride = null);

  /// The app on an iPhone-sized screen in [brightness], after [steps], saved as [name].
  Future<void> shot(
    WidgetTester tester,
    String name,
    Brightness brightness, {
    MockRepository? repo,
    Future<void> Function(WidgetTester tester)? steps,
  }) async {
    debugTouchOverride = true;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    tester.view.physicalSize = const Size(390, 844) * 2;
    tester.view.devicePixelRatio = 2;
    tester.view.padding = const FakeViewPadding(top: 47 * 2, bottom: 34 * 2);
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final c = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repo ?? MockRepository()),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: c, child: const MailApp()),
    );
    await tester.pumpAndSettle();
    // Images decode off the fake clock.
    await tester.runAsync(() async {
      final context = tester.element(find.byType(MailApp));
      await precacheImage(
        const AssetImage('assets/brand/flomsi_mark.png'),
        context,
      );
    });
    await tester.pumpAndSettle();
    // Checked once, so the bar says when ("Updated 09:42"), as it does in use.
    if (repo == null || (await repo.accounts()).isNotEmpty) {
      unawaited(c.read(repositoryProvider).sync());
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
    }
    await steps?.call(tester);
    await tester.pumpAndSettle();
    final bytes = await tester.runAsync(() async {
      final image = await captureImage(tester.element(find.byType(MailApp)));
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    });
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    File('$_out/phone-$name-$mode.png').writeAsBytesSync(bytes!);
    // Let notices and Undo timers run out before the next screen.
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    // Checked before tear-down runs: put the platform back here.
    debugDefaultTargetPlatformOverride = null;
  }

  for (final b in Brightness.values) {
    testWidgets('welcome ${b.name}', skip: _out == null, (tester) async {
      // What the downloads offer: Google, and any other account with a password.
      final repo = MockRepository(empty: true)..providers = const ['google'];
      await shot(tester, 'welcome', b, repo: repo);
    });
    testWidgets('inbox ${b.name}', skip: _out == null, (tester) async {
      await shot(tester, 'inbox', b);
    });
    testWidgets('menu ${b.name}', skip: _out == null, (tester) async {
      await shot(
        tester,
        'menu',
        b,
        steps: (t) => t.longPress(find.text('Your invoice for September')),
      );
    });
    testWidgets('mailboxes ${b.name}', skip: _out == null, (tester) async {
      await shot(
        tester,
        'mailboxes',
        b,
        steps: (t) => t.tap(find.text('Mailboxes')),
      );
    });
    testWidgets('thread ${b.name}', skip: _out == null, (tester) async {
      await shot(
        tester,
        'thread',
        b,
        steps: (t) => t.tap(find.text('Re: Design review Thursday')),
      );
    });
  }
}
