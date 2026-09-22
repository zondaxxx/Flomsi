import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/models.dart';
import 'package:mail_app/keymap/keymap.dart';

void main() {
  final keymap = Keymap.fromJson({
    'name': 'test',
    'inputsSwallowSingleKeys': true,
    'bindings': [
      {
        'action': 'thread.archive',
        'keys': ['e'],
        'scope': ['list', 'thread'],
      },
      {
        'action': 'nav.goInbox',
        'keys': ['g i'],
        'scope': ['global'],
      },
      {
        'action': 'nav.goArchive',
        'keys': ['g a'],
        'scope': ['global'],
      },
      {
        'action': 'palette.open',
        'keys': ['mod+k'],
        'scope': ['global'],
      },
      {
        'action': 'compose.send',
        'keys': ['mod+enter'],
        'scope': ['compose'],
      },
    ],
  });

  group('Keymap.resolve', () {
    test('single key in scope', () {
      expect(keymap.resolve(['e'], {'list', 'global'}), (
        'thread.archive',
        false,
      ));
    });
    test('single key out of scope', () {
      expect(keymap.resolve(['e'], {'compose', 'global'}), (null, false));
    });
    test('chord prefix waits', () {
      expect(keymap.resolve(['g'], {'list', 'global'}), (null, true));
      expect(keymap.resolve(['g', 'i'], {'list', 'global'}), (
        'nav.goInbox',
        false,
      ));
      expect(keymap.resolve(['g', 'x'], {'list', 'global'}), (null, false));
    });
    test('modifier chord', () {
      expect(keymap.resolve(['mod+k'], {'thread', 'global'}), (
        'palette.open',
        false,
      ));
    });
  });

  test('hint renders mac glyphs', () {
    expect(keymap.hint('palette.open'), '⌘k');
    expect(keymap.hint('compose.send', mac: false), 'ctrl+↵');
    expect(keymap.hint('nav.goInbox'), 'g i');
  });

  test('formatWhen buckets', () {
    final now = DateTime(2026, 9, 22, 14, 0);
    expect(formatWhen(DateTime(2026, 9, 22, 9, 5), now: now), '09:05');
    expect(formatWhen(DateTime(2026, 9, 21, 9, 5), now: now), 'yesterday');
    expect(formatWhen(DateTime(2026, 9, 19, 9, 5), now: now), 'sat');
    expect(formatWhen(DateTime(2026, 8, 1), now: now), '1 aug');
  });
}
