import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../keymap/key_scope.dart';
import '../../state/appearance.dart';
import '../../state/providers.dart';
import '../../theme/motion.dart';
import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';
import '../accounts/add_account_sheet.dart';
import '../compose/compose_body.dart';
import '../list/thread_list.dart';
import '../palette/command_palette.dart';
import '../settings/settings_sheet.dart';
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

  /// Phones have no reading pane to host the composer, so it gets its own route, which
  /// closes itself when the compose state clears (sent, discarded, closed).
  void _openComposeOnPhone(BuildContext context) {
    if (MediaQuery.sizeOf(context).width >= 700) return;
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: Motion.of(context, Motion.base),
        reverseTransitionDuration: Motion.of(context, Motion.fast),
        pageBuilder: (_, a, _) => FadeTransition(
          opacity: a,
          child: SlideTransition(
            position: Tween(
              begin: const Offset(0, 0.03),
              end: Offset.zero,
            ).animate(CurvedAnimation(parent: a, curve: Motion.curve)),
            child: const _PhoneCompose(),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    ref.listen<Draft?>(composeProvider, (prev, next) {
      if (prev == null && next != null) _openComposeOnPhone(context);
    });
    final actions = ShellActions(
      ref: ref,
      context: context,
      listKey: _listKey,
      onOpen: () => _openOnPhone(context),
    );
    final paletteOpen = ref.watch(paletteOpenProvider);
    final picker = ref.watch(pickerProvider);
    final draft = ref.watch(composeProvider);
    final touch = Platform.isIOS || Platform.isAndroid;
    return KeyScope(
      actions: actions.keymap(),
      child: Scaffold(
        backgroundColor: s.bg,
        body: SafeArea(
          top: touch,
          bottom: touch,
          child: Stack(
            children: [
              LayoutBuilder(
                builder: (context, c) {
                  final w = c.maxWidth;
                  final threePane = w >= 1100;
                  final phone = w < 700;
                  return Column(
                    children: [
                      _TopBar(
                        listKey: _listKey,
                        compact: phone,
                        actions: actions,
                      ),
                      const Hairline(),
                      Expanded(
                        child: phone
                            ? ThreadListBody(
                                key: _listKey,
                                showSearch: true,
                                onOpen: (_) => _openOnPhone(context),
                              )
                            : Row(
                                children: [
                                  if (threePane) ...[
                                    const SizedBox(
                                      width: 224,
                                      child: _Sidebar(),
                                    ),
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
              if (picker != null && !paletteOpen)
                Positioned.fill(
                  child: CommandPalette(
                    key: ObjectKey(picker),
                    commands: picker.items,
                    hint: picker.hint,
                    onClose: ref.read(pickerProvider.notifier).close,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar({
    required this.listKey,
    required this.compact,
    required this.actions,
  });
  final GlobalKey<ThreadListBodyState> listKey;
  final bool compact;
  final ShellActions actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final query = ref.watch(queryProvider);
    final drafts = query.trim() == 'in:drafts'
        ? ref.watch(draftsProvider).asData?.value.length ?? 0
        : null;
    final threads = ref.watch(threadsProvider).asData?.value;
    final unread = threads?.where((t) => t.unread).length ?? 0;
    final total = threads?.length ?? 0;
    final count = drafts != null
        ? '$drafts ${drafts == 1 ? 'draft' : 'drafts'}'
        : '$total · $unread new';
    final sync = ref.watch(syncStatusProvider);
    final accounts = ref.watch(accountsProvider).value;
    final signIn = accounts?.any((a) => a.needsPassword) ?? false;
    final none = accounts != null && accounts.isEmpty;
    // With no accounts left, old errors are about mail that is gone.
    final alarm = !none && (sync.lastError != null || signIn);
    // Say what is true: no accounts, never synced, a password to enter.
    final syncText = sync.syncing
        ? 'syncing'
        : none
        ? 'no accounts'
        : signIn
        ? 'sign-in needed'
        : sync.lastError != null
        ? 'sync failed'
        : sync.lastOk == null
        ? 'not synced yet'
        : 'synced ${_hhmm(sync.lastOk)}';
    final mac = Platform.isMacOS;

    // Long titles (an account address, a search) ellipsize; the count stays whole.
    final titleArea = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Flexible(
          child: Text(
            titleForQuery(query),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ui(context, weight: FontWeight.w500),
          ),
        ),
        const SizedBox(width: 8),
        AnimatedSwitcher(
          duration: Motion.of(context, Motion.fast),
          child: Text(
            count,
            key: ValueKey(count),
            style: mono(context, size: 11),
          ),
        ),
      ],
    );

    return Container(
      height: 40,
      color: s.bg2,
      padding: EdgeInsets.only(left: mac && !compact ? 80 : 12, right: 12),
      child: Row(
        children: [
          if (compact)
            Expanded(child: titleArea)
          else
            SizedBox(width: 150, child: titleArea),
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
          ],
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: alarm
                          ? s.red
                          : (sync.lastOk == null ? s.fg3 : s.green),
                      shape: BoxShape.circle,
                    ),
                  )
                  .animate(
                    target: sync.syncing ? 1 : 0,
                    onPlay: (c) => c.repeat(reverse: true),
                  )
                  .fade(begin: 1, end: 0.25, duration: 700.ms),
              if (!compact) ...[
                const SizedBox(width: 6),
                AnimatedSwitcher(
                  duration: Motion.of(context, Motion.fast),
                  child: Text(
                    syncText,
                    key: ValueKey(syncText),
                    style: mono(
                      context,
                      size: 11,
                      color: alarm ? s.red : s.fg2,
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
              ] else ...[
                const SizedBox(width: 10),
                IconBtn(
                  icon: CupertinoIcons.square_pencil,
                  label: 'New message',
                  size: 18,
                  onTap: actions.openNew,
                ),
                IconBtn(
                  icon: CupertinoIcons.ellipsis,
                  label: 'More',
                  size: 18,
                  onTap: () => _showMenu(context, ref),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showMenu(BuildContext context, WidgetRef ref) async {
    final s = context.s;
    final repo = ref.read(repositoryProvider);
    final choice = await showMenu<String>(
      context: context,
      position: const RelativeRect.fromLTRB(1000, 40, 8, 0),
      color: s.bg2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: s.border),
      ),
      items: [
        PopupMenuItem(
          value: 'sync',
          height: 36,
          child: Text('Sync now', style: ui(context)),
        ),
        PopupMenuItem(
          value: 'add',
          height: 36,
          child: Text('Add account…', style: ui(context)),
        ),
        PopupMenuItem(
          value: 'theme',
          height: 36,
          child: Text('Appearance', style: ui(context)),
        ),
        PopupMenuItem(
          value: 'settings',
          height: 36,
          child: Text('Settings…', style: ui(context)),
        ),
      ],
    );
    if (!context.mounted) return;
    switch (choice) {
      case 'sync':
        await repo.sync();
      case 'add':
        await showAddAccountSheet(context);
      case 'theme':
        ref.read(appearanceProvider.notifier).cycle();
      case 'settings':
        await showSettingsSheet(context);
    }
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
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
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
          Row(
            children: [
              Expanded(
                child: HoverRegion(
                  onTap: () => showAddAccountSheet(context),
                  builder: (context, hovered) => Container(
                    height: 34,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '+ Add account',
                      style: ui(
                        context,
                        size: 12.5,
                        color: hovered ? s.fg : s.fg2,
                      ),
                    ),
                  ),
                ),
              ),
              IconBtn(
                icon: CupertinoIcons.gear,
                label: 'Settings  ⌘,',
                size: 14,
                onTap: () => showSettingsSheet(context),
              ),
              const SizedBox(width: 8),
            ],
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
            if (e.warning != null)
              Tooltip(
                message: e.warning!,
                child: Icon(
                  CupertinoIcons.exclamationmark_circle_fill,
                  size: 12,
                  color: s.red,
                ),
              )
            else if (e.count > 0)
              Text('${e.count}', style: mono(context, size: 11)),
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
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final drafts = query.trim() == 'in:drafts'
        ? ref.watch(draftsProvider).asData?.value.length
        : null;
    final pos = threads.indexWhere((t) => t.id == selected);
    final position = drafts != null
        ? '$drafts'
        : (pos >= 0 ? '${pos + 1}/${threads.length}' : '${threads.length}');
    final scope = ref.watch(scopeProvider);
    final notice = ref.watch(noticeProvider);
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
              position,
              key: ValueKey(position),
              style: mono(context, size: 11),
            ),
          ),
          const SizedBox(width: 20),
          // Narrow windows ellipsize the account list and the hints instead of overflowing.
          Flexible(
            flex: 2,
            child: Text(
              accounts.map((a) => a.short).join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono(context, size: 11),
            ),
          ),
          const SizedBox(width: 16),
          // Desktop: notices take the key-hint slot for a moment. Phones get NoticeHost's pill.
          if (Platform.isIOS || Platform.isAndroid)
            const Spacer()
          else
            Expanded(
              flex: 3,
              child: Align(
                alignment: Alignment.centerRight,
                child: AnimatedSwitcher(
                  duration: Motion.of(context, Motion.base),
                  switchInCurve: Motion.curve,
                  transitionBuilder: (child, a) => FadeTransition(
                    opacity: a,
                    child: SlideTransition(
                      position: Tween(
                        begin: const Offset(0, 0.4),
                        end: Offset.zero,
                      ).animate(a),
                      child: child,
                    ),
                  ),
                  child: notice != null
                      ? Text(
                          notice,
                          key: ValueKey('notice:$notice'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: mono(context, size: 11, color: s.fg),
                        )
                      : Text(
                          switch (scope) {
                            'search' => 'esc back · ↵ search',
                            'compose' => '⌘↵ send · ⌘⇧A attach · esc close',
                            'thread' => 'r reply · e archive · esc back',
                            'dialog' => 'esc cancel · ↵ confirm',
                            _ => 'j/k move · e archive · r reply · / search · ⌘K commands',
                          },
                          key: ValueKey('hints:$scope'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: mono(context, size: 11),
                        ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PhoneCompose extends ConsumerWidget {
  const _PhoneCompose();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<Draft?>(composeProvider, (prev, next) {
      if (next == null && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
    final draft = ref.watch(composeProvider);
    return Scaffold(
      backgroundColor: context.s.bg,
      body: SafeArea(
        child: draft == null
            ? const SizedBox.shrink()
            : ComposeBody(
                key: ValueKey(draft.hashCode),
                draft: draft,
                compact: true,
              ),
      ),
    );
  }
}
