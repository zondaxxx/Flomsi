import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/mock_repository.dart';
import 'package:mail_app/features/shell/editor_shell.dart';
import 'package:mail_app/platform.dart';
import 'package:mail_app/state/providers.dart';
import 'package:mail_app/theme/tokens.dart';

class _Counting extends MockRepository {
  int syncs = 0;
  @override
  Future<void> sync() {
    syncs++;
    return super.sync();
  }
}

void main() {
  setUp(rootBundle.clear);
  tearDown(() => debugTouchOverride = null);

  testWidgets('pulling the list down on a phone syncs now', (tester) async {
    debugTouchOverride = true;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = _Counting();
    final c = ProviderContainer(
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

    await tester.fling(find.byType(AnimatedList), const Offset(0, 400), 1000);
    await tester.pump();
    await tester.pump(
      const Duration(seconds: 1),
    ); // the indicator arms and fires
    await tester.pump(const Duration(seconds: 1)); // the mock sync finishes
    await tester.pumpAndSettle();
    expect(repo.syncs, 1);
  });
}
