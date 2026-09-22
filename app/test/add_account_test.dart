import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/accounts/add_account_sheet.dart';
import 'package:mail_app/state/providers.dart';
import 'package:mail_app/theme/tokens.dart';

void main() {
  testWidgets('the add-account sheet owns the dialog scope and gives it back', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildTheme(Scheme.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAddAccountSheet(context),
                child: const Text('add'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('add'));
    await tester.pumpAndSettle();
    expect(find.byType(AddAccountSheet), findsOneWidget);
    expect(c.read(scopeProvider), 'dialog');

    await tester.tapAt(const Offset(8, 8)); // the barrier
    await tester.pumpAndSettle();
    expect(find.byType(AddAccountSheet), findsNothing);
    expect(c.read(scopeProvider), 'list');
    expect(tester.takeException(), isNull);
  });
}
