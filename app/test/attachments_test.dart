import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
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

    expect(find.text('invoice.pdf'), findsOneWidget);
    expect(find.text('photo.png'), findsOneWidget);
    expect(find.text('2 files · 86 KB'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('photo.png'),
          matching: find.byType(DraftFileChip),
        ),
        matching: find.byIcon(CupertinoIcons.xmark),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('photo.png'), findsNothing);
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
}
