import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/shell/startup_error.dart';

void main() {
  testWidgets('a core that fails to start shows why and can be retried', (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      StartupErrorApp(
        error: 'database: disk I/O error',
        dataDir: '/Users/z/.mail_',
        onRetry: () async => retries++,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Flomsi could not open its mail database'),
      findsOneWidget,
    );
    expect(
      find.textContaining('database: disk I/O error\ndata: /Users/z/.mail_'),
      findsOneWidget,
    );
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(retries, 1);
    expect(find.text('Retry'), findsOneWidget);
  });
}
