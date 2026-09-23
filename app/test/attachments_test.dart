import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models.dart';
import 'package:mail_app/features/attachments/attachment_chip.dart';
import 'package:mail_app/features/compose/compose_body.dart';
import 'package:mail_app/theme/tokens.dart';

Widget _host(Widget child) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Scheme.dark),
    home: Scaffold(body: child),
  ),
);

/// A file chip by its whole name (the chip lays out the extension on its own).
Finder fileNamed(String name) =>
    find.byWidgetPredicate((w) => w is Semantics && w.properties.label == name);

void main() {
  test('sizes read like a file manager', () {
    expect(formatBytes(900), '900 B');
    expect(formatBytes(86016), '84 KB');
    expect(formatBytes(12976128), '12 MB');
    expect(formatBytes(3 * 1024 * 1024 + 200 * 1024), '3.2 MB');
  });

  test('file glyphs follow the MIME type, then the extension', () {
    expect(iconForFile('image/png', 'a.png'), CupertinoIcons.photo);
    expect(iconForFile('application/pdf', 'a.pdf'), CupertinoIcons.doc_text);
    expect(
      iconForFile('application/octet-stream', 'x.zip'),
      CupertinoIcons.archivebox,
    );
    expect(iconForFile('message/rfc822', 'Old.eml'), CupertinoIcons.envelope);
    expect(
      iconForFile('application/octet-stream', 'glass.fig'),
      CupertinoIcons.doc,
    );
  });

  testWidgets('composer lists forwarded files and removes them', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    const draft = Draft(
      accountId: 1,
      from: 'me@x.dev',
      subject: 'Fwd: Invoice',
      kind: DraftKind.forward,
      attachments: [
        DraftAttachment(
          name: 'invoice.pdf',
          mime: 'application/pdf',
          size: 86016,
          messageId: 7,
          idx: 1,
        ),
        DraftAttachment(
          name: 'photo.png',
          mime: 'image/png',
          size: 2048,
          path: '/tmp/photo.png',
        ),
      ],
    );
    await tester.pumpWidget(_host(const ComposeBody(draft: draft)));
    await tester.pumpAndSettle();

    expect(fileNamed('invoice.pdf'), findsOneWidget);
    expect(fileNamed('photo.png'), findsOneWidget);
    expect(find.text('2 files · 86 KB'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: fileNamed('photo.png'),
          matching: find.byType(DraftFileChip),
        ),
        matching: find.byIcon(CupertinoIcons.xmark),
      ),
    );
    await tester.pumpAndSettle();
    expect(fileNamed('photo.png'), findsNothing);
    expect(find.text('1 file · 84 KB'), findsOneWidget);
  });

  testWidgets('composer warns before servers refuse a large message', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    const draft = Draft(
      accountId: 1,
      from: 'me@x.dev',
      attachments: [
        DraftAttachment(
          name: 'video.mov',
          mime: 'video/quicktime',
          size: 20 * 1024 * 1024,
          path: '/tmp/video.mov',
        ),
      ],
    );
    await tester.pumpWidget(_host(const ComposeBody(draft: draft)));
    await tester.pumpAndSettle();
    expect(find.textContaining('most servers refuse'), findsOneWidget);
  });

  testWidgets('files dropped on the composer attach; folders are refused', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    final dir = Directory.systemTemp.createTempSync('flomsi-drop');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/report.pdf')
      ..writeAsBytesSync(List.filled(2048, 1));
    await tester.pumpWidget(
      _host(const ComposeBody(draft: Draft(accountId: 1, from: 'me@x.dev'))),
    );
    await tester.pumpAndSettle();

    Future<void> fromPlatform(String method, Object args) =>
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'desktop_drop',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, args),
          ),
          (_) {},
        );
    double hintOpacity() => tester
        .widget<AnimatedOpacity>(
          find.ancestor(
            of: find.text('Drop to attach'),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;

    expect(hintOpacity(), 0);
    await fromPlatform('entered', [500.0, 400.0]);
    await tester.pumpAndSettle();
    expect(hintOpacity(), 1);

    await tester.runAsync(() async {
      await fromPlatform('performOperation_macos', [
        {'path': file.path, 'isDirectory': false},
        {'path': dir.path, 'isDirectory': true},
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(hintOpacity(), 0);
    expect(fileNamed('report.pdf'), findsOneWidget);
    expect(find.text('1 file · 2 KB'), findsOneWidget);
    expect(find.textContaining('Folders can’t be attached'), findsOneWidget);
  });
}
