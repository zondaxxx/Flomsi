import 'package:flutter/services.dart';
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

  group('keys on other layouts', () {
    List<String> press(
      PhysicalKeyboardKey physical,
      LogicalKeyboardKey logical,
      String? character, {
      bool meta = false,
      bool ctrl = false,
      bool alt = false,
      bool shift = false,
    }) => chordCandidates(
      physical: physical,
      logical: logical,
      character: character,
      meta: meta,
      ctrl: ctrl,
      alt: alt,
      shift: shift,
    );

    test('US layout types what it says', () {
      expect(press(PhysicalKeyboardKey.keyE, LogicalKeyboardKey.keyE, 'e'), [
        'e',
      ]);
      expect(
        press(
          PhysicalKeyboardKey.digit3,
          LogicalKeyboardKey.numberSign,
          '#',
          shift: true,
        ),
        ['#'],
      );
      expect(
        press(
          PhysicalKeyboardKey.keyK,
          LogicalKeyboardKey.keyK,
          'k',
          meta: true,
        ),
        ['mod+k'],
      );
    });

    // macOS "Русская": the E key types у, shift+3 types №, the slash key types a dot;
    // the engine still reports a-z and digits as logical keys.
    test('Russian letters fall back to the key under them', () {
      expect(press(PhysicalKeyboardKey.keyE, LogicalKeyboardKey.keyE, 'у'), [
        'e',
      ]);
      expect(press(PhysicalKeyboardKey.keyJ, LogicalKeyboardKey.keyJ, 'о'), [
        'j',
      ]);
      expect(
        press(
          PhysicalKeyboardKey.digit3,
          LogicalKeyboardKey.digit3,
          '№',
          shift: true,
        ),
        ['#'],
      );
      // A layout that typed plain ASCII meant it: AZERTY's shift+3 is 3, not #, and
      // Dvorak's z on the US slash key is z, not a search.
      expect(
        press(
          PhysicalKeyboardKey.digit3,
          LogicalKeyboardKey.digit3,
          '3',
          shift: true,
        ),
        ['3'],
      );
      expect(press(PhysicalKeyboardKey.slash, LogicalKeyboardKey.keyZ, 'z'), [
        'z',
      ]);
      expect(
        press(
          PhysicalKeyboardKey.comma,
          const LogicalKeyboardKey(0x0431),
          'б',
          meta: true,
        ),
        ['mod+,'],
      );
      expect(
        press(
          PhysicalKeyboardKey.keyK,
          LogicalKeyboardKey.keyK,
          'л',
          meta: true,
        ),
        ['mod+k'],
      );
    });

    test('AltGr types a character, never the letter under it', () {
      // AltGr+E on a German keyboard types €: not a shortcut, and not "e" either.
      expect(
        press(
          PhysicalKeyboardKey.keyE,
          LogicalKeyboardKey.keyE,
          '€',
          ctrl: true,
          alt: true,
        ),
        isEmpty,
      );
      // ⌃⌥E on macOS carries a control character: it stays a shortcut.
      expect(
        press(
          PhysicalKeyboardKey.keyE,
          LogicalKeyboardKey.keyE,
          '\u0005',
          ctrl: true,
          alt: true,
        ),
        ['mod+alt+e'],
      );
    });

    test('AltGr on Windows types a character, not a shortcut', () {
      expect(
        press(
          PhysicalKeyboardKey.keyQ,
          const LogicalKeyboardKey(0x40),
          '@',
          ctrl: true,
          alt: true,
        ),
        ['@'],
      );
      expect(
        press(
          PhysicalKeyboardKey.keyK,
          LogicalKeyboardKey.keyK,
          null,
          ctrl: true,
        ),
        ['mod+k'],
      );
    });

    test('a Russian key resolves through the fallback, sequences too', () {
      final scopes = {'list', 'global'};
      String? first(List<String> pending, List<String> chords) {
        for (final c in chords) {
          final (a, _) = keymap.resolve([...pending, c], scopes);
          if (a != null) return a;
        }
        return null;
      }

      final e = press(PhysicalKeyboardKey.keyE, LogicalKeyboardKey.keyE, 'у');
      expect(first([], e), 'thread.archive');
      final i = press(PhysicalKeyboardKey.keyI, LogicalKeyboardKey.keyI, 'ш');
      expect(first(['g'], i), 'nav.goInbox');
    });
  });

  test('hint renders mac glyphs', () {
    expect(keymap.hint('palette.open'), '⌘K');
    expect(keymap.hint('palette.open', mac: false), 'ctrl+K');
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
