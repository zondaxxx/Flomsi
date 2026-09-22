import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/shell/notice_host.dart';
import 'package:mail_app/state/providers.dart';
import 'package:mail_app/theme/tokens.dart';

void main() {
  testWidgets('notices show above every route and fade out', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Scheme.dark),
          builder: (context, child) => NoticeHost(child: child!),
          home: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );
    container.read(noticeProvider.notifier).show('Saved to Downloads/a.pdf');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Saved to Downloads/a.pdf'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('Saved to Downloads/a.pdf'), findsNothing);
  });
}
