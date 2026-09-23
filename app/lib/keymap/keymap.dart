import 'dart:convert';

import 'package:flutter/services.dart';

/// One action bound to one or more key sequences, active in the given scopes.
class Binding {
  const Binding({
    required this.action,
    required this.keys,
    required this.scopes,
  });
  final String action;
  final List<String> keys; // "e", "g i", "mod+k"
  final Set<String> scopes;

  factory Binding.fromJson(Map<String, dynamic> j) => Binding(
    action: j['action'] as String,
    keys: (j['keys'] as List).cast<String>(),
    scopes: (j['scope'] as List).cast<String>().toSet(),
  );
}

class Keymap {
  const Keymap({
    required this.name,
    required this.inputsSwallowSingleKeys,
    required this.bindings,
  });
  final String name;
  final bool inputsSwallowSingleKeys;
  final List<Binding> bindings;

  static Future<Keymap> loadAsset(String name) async {
    final raw = await rootBundle.loadString('assets/keymaps/$name.json');
    return Keymap.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  factory Keymap.fromJson(Map<String, dynamic> j) => Keymap(
    name: j['name'] as String,
    inputsSwallowSingleKeys: (j['inputsSwallowSingleKeys'] as bool?) ?? true,
    bindings: (j['bindings'] as List)
        .map((b) => Binding.fromJson(b as Map<String, dynamic>))
        .toList(),
  );

  /// Human hint for an action, e.g. "e" or "⌘K".
  String? hint(String action, {bool mac = true}) {
    final b = bindings.where((b) => b.action == action).firstOrNull;
    if (b == null || b.keys.isEmpty) return null;
    return prettyChord(b.keys.first, mac: mac);
  }

  /// Readable name of an action for hints: `nav.goInbox` → `inbox`.
  static String describe(String action) =>
      const {
        'nav.goInbox': 'inbox',
        'nav.goArchive': 'archive',
        'nav.goStarred': 'starred',
        'nav.goSent': 'sent',
        'nav.goDrafts': 'drafts',
      }[action] ??
      action.split('.').last.replaceFirst(RegExp('^go'), '').toLowerCase();

  /// What can follow a started sequence ([prefix] = `g`) in [scopes]: (`g i`, action).
  List<(String, String)> continuations(String prefix, Set<String> scopes) => [
    for (final b in bindings)
      if (b.scopes.any(scopes.contains))
        for (final k in b.keys)
          if (k.startsWith('$prefix ')) (prettyChord(k), b.action),
  ];

  static String prettyChord(String chord, {bool mac = true}) => chord
      .split(' ')
      .map(
        (part) => part
            .split('+')
            .map(
              // With a modifier a letter is written as on the key cap: ⌘K.
              (k) => switch (k) {
                _ when part.contains('+') && RegExp(r'^[a-z]$').hasMatch(k) =>
                  k.toUpperCase(),
                'mod' => mac ? '⌘' : 'ctrl',
                'shift' => '⇧',
                'alt' => mac ? '⌥' : 'alt',
                'enter' => '↵',
                'escape' => 'esc',
                'arrowup' => '↑',
                'arrowdown' => '↓',
                _ => k,
              },
            )
            .join(mac ? '' : '+'),
      )
      .join(' ');

  /// Resolve a pending chord sequence against the active scopes.
  /// Returns (action, isPrefixOfLonger).
  (String?, bool) resolve(List<String> pending, Set<String> scopes) {
    final seq = pending.join(' ');
    String? hit;
    var prefix = false;
    for (final b in bindings) {
      if (!b.scopes.any(scopes.contains)) continue;
      for (final k in b.keys) {
        if (k == seq) hit ??= b.action;
        if (k != seq && k.startsWith('$seq ')) prefix = true;
      }
    }
    return (hit, prefix);
  }
}

/// What the key at each position types on a US layout, unshifted and shifted. Letters are
/// left out: the engine already reports a-z as logical keys on every layout.
final Map<PhysicalKeyboardKey, (String, String)> _usPunctuation = {
  PhysicalKeyboardKey.digit1: ('1', '!'),
  PhysicalKeyboardKey.digit2: ('2', '@'),
  PhysicalKeyboardKey.digit3: ('3', '#'),
  PhysicalKeyboardKey.digit4: ('4', r'$'),
  PhysicalKeyboardKey.digit5: ('5', '%'),
  PhysicalKeyboardKey.digit6: ('6', '^'),
  PhysicalKeyboardKey.digit7: ('7', '&'),
  PhysicalKeyboardKey.digit8: ('8', '*'),
  PhysicalKeyboardKey.digit9: ('9', '('),
  PhysicalKeyboardKey.digit0: ('0', ')'),
  PhysicalKeyboardKey.minus: ('-', '_'),
  PhysicalKeyboardKey.equal: ('=', '+'),
  PhysicalKeyboardKey.bracketLeft: ('[', '{'),
  PhysicalKeyboardKey.bracketRight: (']', '}'),
  PhysicalKeyboardKey.backslash: (r'\', '|'),
  PhysicalKeyboardKey.semicolon: (';', ':'),
  PhysicalKeyboardKey.quote: ("'", '"'),
  PhysicalKeyboardKey.backquote: ('`', '~'),
  PhysicalKeyboardKey.comma: (',', '<'),
  PhysicalKeyboardKey.period: ('.', '>'),
  PhysicalKeyboardKey.slash: ('/', '?'),
};

final _letters = {
  for (var c = 0x61; c <= 0x7a; c++)
    LogicalKeyboardKey(LogicalKeyboardKey.keyA.keyId + c - 0x61):
        String.fromCharCode(c),
};

final _named = {
  LogicalKeyboardKey.enter: 'enter',
  LogicalKeyboardKey.numpadEnter: 'enter',
  LogicalKeyboardKey.escape: 'escape',
  LogicalKeyboardKey.space: 'space',
  LogicalKeyboardKey.backspace: 'backspace',
  LogicalKeyboardKey.tab: 'tab',
  LogicalKeyboardKey.arrowUp: 'arrowup',
  LogicalKeyboardKey.arrowDown: 'arrowdown',
  LogicalKeyboardKey.arrowLeft: 'arrowleft',
  LogicalKeyboardKey.arrowRight: 'arrowright',
};

final _modifierKeys = {
  LogicalKeyboardKey.metaLeft,
  LogicalKeyboardKey.metaRight,
  LogicalKeyboardKey.controlLeft,
  LogicalKeyboardKey.controlRight,
  LogicalKeyboardKey.shiftLeft,
  LogicalKeyboardKey.shiftRight,
  LogicalKeyboardKey.altLeft,
  LogicalKeyboardKey.altRight,
  LogicalKeyboardKey.altGraph,
};

bool _ascii(String s) => s.codeUnits.every((c) => c >= 0x21 && c < 0x7f);

/// Chord tokens for one key press, best first: `e`, `#`, `mod+k`, `g`.
///
/// The typed character comes first, so a layout's own `/` or `#` works wherever it sits.
/// When the layout types something else (Cyrillic `у` on the E key, `№` on shift+3), the
/// key's place on a US keyboard follows, so the shortcuts keep working on the macOS
/// "Русская" layout without switching. On Windows AltGr arrives as ctrl+alt: a character
/// typed that way counts as a character, not as a shortcut.
List<String> chordCandidates({
  required PhysicalKeyboardKey physical,
  required LogicalKeyboardKey logical,
  required String? character,
  required bool meta,
  required bool ctrl,
  required bool alt,
  required bool shift,
}) {
  if (_modifierKeys.contains(logical)) return const [];
  final named = _named[logical];
  final printable =
      character != null && character.isNotEmpty && character.trim().isNotEmpty;
  // Windows reports AltGr as ctrl+alt. A real AltGr character is printable; macOS gives
  // ⌃⌥E a control character (0x05), which stays a shortcut.
  final altGr =
      ctrl &&
      alt &&
      !meta &&
      printable &&
      character.codeUnits.every((c) => c >= 0x20);

  if (named == null && printable && (!meta && !ctrl && !alt || altGr)) {
    final out = <String>[];
    void add(String c) {
      if (!out.contains(c)) out.add(c);
    }

    if (character.length == 1 && RegExp(r'[A-Za-z]').hasMatch(character)) {
      add(character.toLowerCase());
    } else if (_ascii(character)) {
      add(character);
    }
    // What the key would mean on a US keyboard, only when this layout typed something
    // no binding can name (у, №). A layout that typed a real ASCII character (AZERTY's
    // shift+3 is 3, Dvorak's z sits on the US slash) meant that character; falling
    // through to # or / would delete or search by surprise. AltGr characters are what
    // they are, too.
    if (!altGr && !_ascii(character)) {
      final letter = _letters[logical];
      if (letter != null) add(letter);
      final us = _usPunctuation[physical];
      if (us != null) add(shift ? us.$2 : us.$1);
    }
    return out;
  }

  final base =
      named ??
      _letters[logical] ??
      _usPunctuation[physical]?.$1 ??
      logical.keyLabel.toLowerCase();
  if (base.isEmpty) return const [];
  final mods = <String>[];
  if (meta || ctrl) mods.add('mod');
  if (alt) mods.add('alt');
  if (shift && base.length > 1) mods.add('shift');
  return [
    [...mods, base].join('+'),
  ];
}

/// Chord tokens for a key event with the keyboard's current modifiers.
List<String> chordsFor(KeyEvent e) {
  if (e is! KeyDownEvent) return const [];
  final k = HardwareKeyboard.instance;
  return chordCandidates(
    physical: e.physicalKey,
    logical: e.logicalKey,
    character: e.character,
    meta: k.isMetaPressed,
    ctrl: k.isControlPressed,
    alt: k.isAltPressed,
    shift: k.isShiftPressed,
  );
}
