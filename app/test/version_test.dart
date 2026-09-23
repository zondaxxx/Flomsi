import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/settings/phone_settings.dart';

/// Settings shows the version from a constant; it has to move with pubspec.yaml.
void main() {
  test('the version Settings shows is the one in pubspec.yaml', () {
    final line = File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('version:'));
    expect(line.substring(8).trim(), '$appVersion+$appBuild');
  });
}
