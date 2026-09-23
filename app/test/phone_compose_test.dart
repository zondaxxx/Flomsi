import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/compose/compose_body.dart';
import 'package:mail_app/features/shell/editor_shell.dart';
import 'package:mail_app/theme/tokens.dart';

void main() {
  testWidgets('phones open the composer in its own route and close it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Scheme.dark),
          home: const EditorShell(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ComposeBody), findsNothing);

    await tester.tap(find.byIcon(CupertinoIcons.square_pencil));
    await tester.pumpAndSettle();
    expect(find.byType(ComposeBody), findsOneWidget);
    expect(find.text('New message'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(ComposeBody),
        matching: find.byIcon(CupertinoIcons.xmark),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ComposeBody), findsNothing);

    // Android's back button instead of ×: the next New message still opens.
    await tester.tap(find.byIcon(CupertinoIcons.square_pencil));
    await tester.pumpAndSettle();
    expect(find.byType(ComposeBody), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ComposeBody), findsNothing);
    await tester.tap(find.byIcon(CupertinoIcons.square_pencil));
    await tester.pumpAndSettle();
    expect(find.byType(ComposeBody), findsOneWidget);
  });
}
