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

  static String prettyChord(String chord, {bool mac = true}) => chord
      .split(' ')
      .map(
        (part) => part
            .split('+')
            .map(
              (k) => switch (k) {
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

/// Normalize a key event into a chord token like "e", "#", "mod+k", "g".
String? chordFor(KeyEvent e) {
  if (e is! KeyDownEvent) return null;
  final pressed = HardwareKeyboard.instance;
  final meta = pressed.isMetaPressed;
  final ctrl = pressed.isControlPressed;
  final alt = pressed.isAltPressed;
  final shift = pressed.isShiftPressed;
  final key = e.logicalKey;

  if (key == LogicalKeyboardKey.metaLeft ||
      key == LogicalKeyboardKey.metaRight ||
      key == LogicalKeyboardKey.controlLeft ||
      key == LogicalKeyboardKey.controlRight ||
      key == LogicalKeyboardKey.shiftLeft ||
      key == LogicalKeyboardKey.shiftRight ||
      key == LogicalKeyboardKey.altLeft ||
      key == LogicalKeyboardKey.altRight) {
    return null;
  }

  String base;
  if (key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter) {
    base = 'enter';
  } else if (key == LogicalKeyboardKey.escape) {
    base = 'escape';
  } else if (key == LogicalKeyboardKey.space) {
    base = 'space';
  } else if (key == LogicalKeyboardKey.backspace) {
    base = 'backspace';
  } else if (key == LogicalKeyboardKey.tab) {
    base = 'tab';
  } else if (key == LogicalKeyboardKey.arrowUp) {
    base = 'arrowup';
  } else if (key == LogicalKeyboardKey.arrowDown) {
    base = 'arrowdown';
  } else if (key == LogicalKeyboardKey.arrowLeft) {
    base = 'arrowleft';
  } else if (key == LogicalKeyboardKey.arrowRight) {
    base = 'arrowright';
  } else {
    final ch = e.character;
    if (ch != null &&
        ch.isNotEmpty &&
        !meta &&
        !ctrl &&
        !alt &&
        ch.trim().isNotEmpty) {
      // Printable: keep the produced character so "#", "*", "/" and "?" work on any layout.
      return ch.length == 1 && RegExp(r'[A-Za-z]').hasMatch(ch)
          ? ch.toLowerCase()
          : ch;
    }
    base = key.keyLabel.toLowerCase();
    if (base.isEmpty) return null;
  }
  final mods = <String>[];
  if (meta || ctrl) mods.add('mod');
  if (alt) mods.add('alt');
  if (shift && base.length > 1) mods.add('shift');
  return [...mods, base].join('+');
}
