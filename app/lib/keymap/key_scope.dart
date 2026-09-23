import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'keymap.dart';

typedef ActionHandler = void Function();

/// The start of a key sequence waiting for its next key (`g` of `g i`), for the status line.
final pendingChordProvider = NotifierProvider<PendingChord, String?>(
  PendingChord.new,
);

class PendingChord extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? chord) => state = chord;
}

/// Root key dispatcher. Reads the keymap, collects chords (`g i`), respects the
/// current scope and lets focused text inputs swallow single keys.
class KeyScope extends ConsumerStatefulWidget {
  const KeyScope({super.key, required this.actions, required this.child});
  final Map<String, ActionHandler> actions;
  final Widget child;

  @override
  ConsumerState<KeyScope> createState() => _KeyScopeState();
}

class _KeyScopeState extends ConsumerState<KeyScope> {
  final _pending = <String>[];
  Timer? _timer;
  final _focus = FocusNode(debugLabel: 'KeyScope');

  @override
  void dispose() {
    _timer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  bool _textInputFocused() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText ||
        ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    final keymap = ref.read(keymapProvider).value;
    if (keymap == null) return KeyEventResult.ignored;
    final chords = chordsFor(e);
    if (chords.isEmpty) return KeyEventResult.ignored;

    final inInput = _textInputFocused();
    final hasMod = chords.first.contains('mod+');
    if (inInput &&
        keymap.inputsSwallowSingleKeys &&
        !hasMod &&
        chords.first != 'escape') {
      _pending.clear();
      return KeyEventResult.ignored;
    }

    final scope = ref.read(scopeProvider);
    final scopes = {scope, 'global'};
    if (ref.read(paletteOpenProvider)) scopes.add('palette');

    // The first reading of the key that means something wins: the typed character,
    // then the key's US position (see chordCandidates).
    String? action;
    var prefix = false;
    String? used;
    for (final attempt in [
      if (_pending.isNotEmpty) [..._pending],
      <String>[],
    ]) {
      for (final chord in chords) {
        final (a, p) = keymap.resolve([...attempt, chord], scopes);
        if (a != null || p) {
          (action, prefix) = (a, p);
          _pending
            ..clear()
            ..addAll([...attempt, chord]);
          used = chord;
          break;
        }
      }
      if (used != null) break;
    }
    _timer?.cancel();
    if (action != null) {
      _pending.clear();
      ref.read(pendingChordProvider.notifier).set(null);
      final handler = widget.actions[action];
      if (handler != null) {
        handler();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (prefix) {
      ref.read(pendingChordProvider.notifier).set(_pending.join(' '));
      _timer = Timer(const Duration(milliseconds: 1200), () {
        _pending.clear();
        if (mounted) ref.read(pendingChordProvider.notifier).set(null);
      });
      return KeyEventResult.handled;
    }
    _pending.clear();
    ref.read(pendingChordProvider.notifier).set(null);
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: widget.child,
    );
  }
}

/// Grab keyboard focus back to the app shell (e.g. after Escape in a text field).
void blurTextInput() => FocusManager.instance.primaryFocus?.unfocus();
