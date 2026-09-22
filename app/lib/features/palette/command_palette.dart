import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../theme/motion.dart';
import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';

class Command {
  const Command({
    required this.id,
    required this.title,
    required this.group,
    this.detail,
    this.hint,
    required this.run,
  });
  final String id;
  final String title;
  final String group;
  final String? detail;
  final String? hint;
  final VoidCallback run;
}

/// A one-off choice shown in the palette's popover ("Move to…", "Snooze until…").
class Picker {
  const Picker({required this.hint, required this.items});
  final String hint;
  final List<Command> items;
}

final pickerProvider = NotifierProvider<PickerController, Picker?>(
  PickerController.new,
);

class PickerController extends Notifier<Picker?> {
  @override
  Picker? build() => null;
  void open(Picker p) => state = p;
  void close() => state = null;
}

/// ⌘K: Zed-style popover at the top, grouped, arrow keys + return. The same popover shows
/// pickers, with their own placeholder and close action.
class CommandPalette extends ConsumerStatefulWidget {
  const CommandPalette({
    super.key,
    required this.commands,
    this.hint = 'Search mail or run a command',
    this.onClose,
  });
  final List<Command> commands;
  final String hint;

  /// Defaults to closing the command palette.
  final VoidCallback? onClose;

  @override
  ConsumerState<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends ConsumerState<CommandPalette> {
  final _ctl = TextEditingController();
  final _focus = FocusNode(debugLabel: 'palette');
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<Command> get _matches {
    final q = _ctl.text.trim().toLowerCase();
    if (q.isEmpty) return widget.commands;
    return widget.commands
        .where(
          (c) =>
              c.title.toLowerCase().contains(q) ||
              (c.detail?.toLowerCase().contains(q) ?? false),
        )
        .toList();
  }

  void _close() =>
      (widget.onClose ?? ref.read(paletteOpenProvider.notifier).close)();

  void _run(Command c) {
    _close();
    c.run();
  }

  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final m = _matches;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _index = m.isEmpty ? 0 : (_index + 1) % m.length);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(
        () => _index = m.isEmpty ? 0 : (_index - 1 + m.length) % m.length,
      );
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.enter) {
      if (m.isNotEmpty) _run(m[_index.clamp(0, m.length - 1)]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final matches = _matches;
    final groups = <String, List<Command>>{};
    for (final c in matches) {
      groups.putIfAbsent(c.group, () => []).add(c);
    }
    var flat = 0;
    final q = _ctl.text.trim();

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: _close,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: Motion.of(context, Motion.fast),
              builder: (context, t, _) => ColoredBox(
                color: Colors.black.withValues(
                  alpha: (s.isDark ? 0.4 : 0.15) * t,
                ),
              ),
            ),
          ),
        ),
        Align(
          alignment: const Alignment(0, -0.6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Appear(
                duration: Motion.fast,
                dy: -6,
                child: Focus(
                  onKeyEvent: _onKey,
                  child: Container(
                    decoration: BoxDecoration(
                      color: s.bg2,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: s.border),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: s.isDark ? 0.55 : 0.2,
                          ),
                          blurRadius: 32,
                          offset: const Offset(0, 14),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            height: 42,
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(color: s.border),
                              ),
                            ),
                            child: Material(
                              type: MaterialType.transparency,
                              child: TextField(
                                controller: _ctl,
                                focusNode: _focus,
                                style: ui(context, size: 14),
                                cursorColor: s.fg,
                                cursorWidth: 1.5,
                                decoration: InputDecoration(
                                  isDense: true,
                                  border: InputBorder.none,
                                  hintText: widget.hint,
                                  hintStyle: ui(
                                    context,
                                    size: 14,
                                    color: s.fg3,
                                  ),
                                ),
                                onChanged: (_) => setState(() => _index = 0),
                              ),
                            ),
                          ),
                          Flexible(
                            child: ListView(
                              shrinkWrap: true,
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              children: [
                                if (matches.isEmpty)
                                  Padding(
                                    padding: const EdgeInsets.all(14),
                                    child: Text(
                                      'No matches',
                                      style: ui(context, color: s.fg3),
                                    ),
                                  ),
                                for (final g in groups.entries) ...[
                                  SectionLabel(
                                    g.key,
                                    padding: const EdgeInsets.fromLTRB(
                                      14,
                                      8,
                                      14,
                                      2,
                                    ),
                                  ),
                                  for (final c in g.value)
                                    _Row(
                                      command: c,
                                      query: q,
                                      selected: (flat++) == _index,
                                      onTap: () => _run(c),
                                    ),
                                ],
                              ],
                            ),
                          ),
                          Container(
                            height: 30,
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            decoration: BoxDecoration(
                              border: Border(top: BorderSide(color: s.border)),
                            ),
                            child: Row(
                              children: [
                                Text(
                                  '↑↓ navigate   ↵ run   esc close',
                                  style: mono(
                                    context,
                                    size: 10.5,
                                    color: s.fg3,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  '${matches.length} results',
                                  style: mono(
                                    context,
                                    size: 10.5,
                                    color: s.fg3,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.command,
    required this.query,
    required this.selected,
    required this.onTap,
  });
  final Command command;
  final String query;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final c = command;
    return HoverRegion(
      onTap: onTap,
      builder: (context, hovered) => AnimatedContainer(
        duration: Motion.of(context, Motion.fast),
        height: 30,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: selected
              ? s.selected
              : (hovered ? s.hover : Colors.transparent),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            Expanded(child: _highlight(context, c.title, query)),
            if (c.detail != null)
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Text(
                  c.detail!,
                  style: mono(context, size: 11, color: s.fg3),
                ),
              ),
            if (c.hint != null)
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: KeyHint(c.hint!, color: s.fg2),
              ),
          ],
        ),
      ),
    );
  }

  Widget _highlight(BuildContext context, String text, String q) {
    final s = context.s;
    final i = q.isEmpty ? -1 : text.toLowerCase().indexOf(q.toLowerCase());
    if (i < 0) {
      return Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: ui(context),
      );
    }
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: text.substring(0, i)),
          TextSpan(
            text: text.substring(i, i + q.length),
            style: ui(context, weight: FontWeight.w600, color: s.blue),
          ),
          TextSpan(text: text.substring(i + q.length)),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: ui(context),
    );
  }
}
