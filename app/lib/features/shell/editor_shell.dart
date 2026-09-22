import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../keymap/key_scope.dart';
import '../../state/providers.dart';
import '../../theme/motion.dart';
import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';
import '../accounts/add_account_sheet.dart';
import '../compose/compose_body.dart';
import '../list/thread_list.dart';
import '../palette/command_palette.dart';
import '../sidebar/sidebar_model.dart';
import '../thread/thread_view.dart';
import 'shell_actions.dart';

/// F1 · Editor frame: top bar with the search/command field, sidebar, list, reading pane, status line.
/// Three panes ≥1100px, two ≥700px, one below (list, then push the thread).
class EditorShell extends ConsumerStatefulWidget {
  const EditorShell({super.key});

  @override
  ConsumerState<EditorShell> createState() => _EditorShellState();
}

class _EditorShellState extends ConsumerState<EditorShell> {
  final _listKey = GlobalKey<ThreadListBodyState>();

  void _openOnPhone(BuildContext context) {
    if (MediaQuery.sizeOf(context).width >= 700) return;
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: Motion.of(context, Motion.base),
        pageBuilder: (_, a, _) => FadeTransition(
          opacity: a,
          child: Scaffold(
            body: SafeArea(
              child: ThreadBody(
                compact: true,
                onBack: () => Navigator.of(context).pop(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final actions = ShellActions(
      ref: ref,
      context: context,
      listKey: _listKey,
      onOpen: () => _openOnPhone(context),
    );
    final paletteOpen = ref.watch(paletteOpenProvider);
    final draft = ref.watch(composeProvider);
    return KeyScope(
      actions: actions.keymap(),
      child: Scaffold(
        backgroundColor: s.bg,
        body: Stack(
          children: [
            LayoutBuilder(
              builder: (context, c) {
                final w = c.maxWidth;
                final threePane = w >= 1100;
                final phone = w < 700;
                return Column(
                  children: [
                    _TopBar(listKey: _listKey, compact: phone),
                    const Hairline(),
                    Expanded(
                      child: phone
                          ? ThreadListBody(
                              key: _listKey,
                              onOpen: (_) => _openOnPhone(context),
                            )
                          : Row(
                              children: [
                                if (threePane) ...[
                                  const SizedBox(width: 224, child: _Sidebar()),
                                  const Hairline(vertical: true),
                                ],
                                SizedBox(
                                  width: threePane ? 440 : 380,
                                  child: ThreadListBody(key: _listKey),
                                ),
                                const Hairline(vertical: true),
                                Expanded(
                                  child: draft != null
                                      ? ComposeBody(
                                          key: ValueKey(draft.hashCode),
                                          draft: draft,
                                        )
                                      : const ThreadBody(),
                                ),
                              ],
                            ),
                    ),
                    const Hairline(),
                    const _StatusBar(),
                  ],
                );
              },
            ),
            if (paletteOpen)
              Positioned.fill(
                child: CommandPalette(commands: actions.commands()),
              ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar({required this.listKey, required this.compact});
  final GlobalKey<ThreadListBodyState> listKey;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final query = ref.watch(queryProvider);
    final threads = ref.watch(threadsProvider).asData?.value;
    final unread = threads?.where((t) => t.unread).length ?? 0;
    final total = threads?.length ?? 0;
    final sync = ref.watch(syncStatusProvider);
    final mac = Platform.isMacOS;

    return Container(
      height: 40,
      color: s.bg2,
      padding: EdgeInsets.only(left: mac && !compact ? 80 : 12, right: 12),
      child: Row(
        children: [
          SizedBox(
            width: compact ? null : 150,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  titleForQuery(query),
                  style: ui(context, weight: FontWeight.w500),
                ),
                const SizedBox(width: 8),
                AnimatedSwitcher(
                  duration: Motion.of(context, Motion.fast),
                  child: Text(
                    '$total · $unread new',
                    key: ValueKey('$total-$unread'),
                    style: mono(context, size: 11),
                  ),
                ),
              ],
            ),
          ),
          if (!compact) ...[
            const Spacer(),
            SizedBox(
              width: 520,
              child: QuietField(
                controller: listKey.currentState?.searchController,
                focusNode: listKey.currentState?.searchFocus,
                hint: 'Search mail or run a command',
                height: 28,
                fontSize: 13,
                leading: Icon(CupertinoIcons.search, size: 13, color: s.fg3),
                trailing: const KeyHint('⌘K'),
                onChanged: (v) => listKey.currentState?.onSearchChanged(v),
                onSubmitted: (_) => blurTextInput(),
              ),
            ),
            const Spacer(),
          ] else
            const Spacer(),
          SizedBox(
            width: compact ? null : 220,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: sync.lastError != null ? s.red : s.green,
                        shape: BoxShape.circle,
                      ),
                    )
                    .animate(
                      target: sync.syncing ? 1 : 0,
                      onPlay: (c) => c.repeat(reverse: true),
                    )
                    .fade(begin: 1, end: 0.25, duration: 700.ms),
                const SizedBox(width: 6),
                AnimatedSwitcher(
                  duration: Motion.of(context, Motion.fast),
                  child: Text(
                    sync.syncing
                        ? 'syncing'
                        : (sync.lastError != null
                              ? 'sync failed'
                              : 'synced ${_hhmm(sync.lastOk)}'),
                    key: ValueKey(
                      '${sync.syncing}-${sync.lastError != null}-${sync.lastOk}',
                    ),
                    style: mono(
                      context,
                      size: 11,
                      color: sync.lastError != null ? s.red : s.fg2,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Tooltip(
                  message: 'Keyboard shortcuts',
                  child: HoverRegion(
                    onTap: () => ref.read(paletteOpenProvider.notifier).open(),
                    builder: (context, hovered) => Container(
                      width: 24,
                      height: 24,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border.all(color: s.border),
                        borderRadius: BorderRadius.circular(4),
                        color: hovered ? s.raised : null,
                      ),
                      child: Text(
                        '?',
                        style: mono(context, size: 12, color: s.fg2),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _hhmm(DateTime? d) {
    if (d == null) return '';
    final l = d.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }
}

class _Sidebar extends ConsumerWidget {
  const _Sidebar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final folders =
        ref.watch(foldersProvider).asData?.value ?? const <Folder>[];
    final accounts =
        ref.watch(accountsProvider).asData?.value ?? const <Account>[];
    final labels = ref.watch(labelsProvider).asData?.value ?? const <Label>[];
    final query = ref.watch(queryProvider);
    final entries = buildSidebar(
      folders: folders,
      accounts: accounts,
      labels: labels,
    );
    return ColoredBox(
      color: s.bg2,
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              children: [
                for (final e in entries)
                  if (e.section)
                    SectionLabel(e.label)
                  else
                    _SideRow(
                      entry: e,
                      selected: e.query == query,
                      onTap: () =>
                          ref.read(queryProvider.notifier).set(e.query ?? ''),
                    ),
              ],
            ),
          ),
          HoverRegion(
            onTap: () => showAddAccountSheet(context),
            builder: (context, hovered) => Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.centerLeft,
              child: Text(
                '+ Add account',
                style: ui(context, size: 12.5, color: hovered ? s.fg : s.fg2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SideRow extends StatelessWidget {
  const _SideRow({
    required this.entry,
    required this.selected,
    required this.onTap,
  });
  final SidebarEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final e = entry;
    final Widget lead;
    if (e.icon == CupertinoIcons.circle_fill) {
      lead = Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: e.color, shape: BoxShape.circle),
      );
    } else if (e.icon == CupertinoIcons.tag) {
      lead = Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: e.color ?? s.tagColor(e.label),
          borderRadius: BorderRadius.circular(2),
        ),
      );
    } else {
      lead = Icon(
        e.icon ?? CupertinoIcons.folder,
        size: 14,
        color: selected ? s.fg : s.fg2,
      );
    }
    return HoverRegion(
      onTap: onTap,
      builder: (context, hovered) => AnimatedContainer(
        duration: Motion.of(context, Motion.fast),
        curve: Motion.curve,
        height: 26,
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: selected ? s.raised : (hovered ? s.hover : Colors.transparent),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            SizedBox(width: 14, child: Center(child: lead)),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                e.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ui(context, color: s.fg),
              ),
            ),
            if (e.count > 0) Text('${e.count}', style: mono(context, size: 11)),
          ],
        ),
      ),
    );
  }
}

class _StatusBar extends ConsumerWidget {
  const _StatusBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final query = ref.watch(queryProvider);
    final threads =
        ref.watch(threadsProvider).asData?.value ?? const <Thread>[];
    final selected = ref.watch(selectedThreadIdProvider);
    final accounts =
        ref.watch(accountsProvider).asData?.value ?? const <Account>[];
    final pos = threads.indexWhere((t) => t.id == selected);
    final scope = ref.watch(scopeProvider);
    return Container(
      height: 24,
      color: s.bg2,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Text(
            titleForQuery(query).toUpperCase(),
            style: mono(context, size: 11, color: s.fg),
          ),
          const SizedBox(width: 20),
          AnimatedSwitcher(
            duration: Motion.of(context, Motion.fast),
            child: Text(
              pos >= 0 ? '${pos + 1}/${threads.length}' : '${threads.length}',
              key: ValueKey('$pos-${threads.length}'),
              style: mono(context, size: 11),
            ),
          ),
          const SizedBox(width: 20),
          Text(
            accounts.map((a) => a.short).join(' · '),
            style: mono(context, size: 11),
          ),
          const Spacer(),
          Text(switch (scope) {
            'search' => 'esc back · ↵ search',
            'compose' => '⌘↵ send · esc discard',
            'thread' => 'r reply · e archive · esc back',
            'dialog' => 'esc cancel · ↵ confirm',
            _ => 'j/k move · e archive · r reply · / search · ⌘K commands',
          }, style: mono(context, size: 11)),
        ],
      ),
    );
  }
}
