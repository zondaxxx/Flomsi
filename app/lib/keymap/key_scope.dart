import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'keymap.dart';

typedef ActionHandler = void Function();

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
    final keymap = ref.read(keymapProvider).asData?.value;
    if (keymap == null) return KeyEventResult.ignored;
    final chord = chordFor(e);
    if (chord == null) return KeyEventResult.ignored;

    final inInput = _textInputFocused();
    final hasMod = chord.contains('mod+');
    if (inInput &&
        keymap.inputsSwallowSingleKeys &&
        !hasMod &&
        chord != 'escape') {
      _pending.clear();
      return KeyEventResult.ignored;
    }

    final scope = ref.read(scopeProvider);
    final scopes = {scope, 'global'};
    if (ref.read(paletteOpenProvider)) scopes.add('palette');

    _pending.add(chord);
    var (action, prefix) = keymap.resolve(_pending, scopes);
    if (action == null && !prefix && _pending.length > 1) {
      // Sequence broke: retry with the last chord alone.
      _pending
        ..clear()
        ..add(chord);
      (action, prefix) = keymap.resolve(_pending, scopes);
    }
    _timer?.cancel();
    if (action != null) {
      _pending.clear();
      final handler = widget.actions[action];
      if (handler != null) {
        handler();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (prefix) {
      _timer = Timer(
        const Duration(milliseconds: 1200),
        () => _pending.clear(),
      );
      return KeyEventResult.handled;
    }
    _pending.clear();
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
