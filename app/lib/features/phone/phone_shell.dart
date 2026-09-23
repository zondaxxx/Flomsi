import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../state/providers.dart';
import '../../theme/app_icons.dart';
import '../../theme/motion.dart';
import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';
import '../list/thread_list.dart';
import '../onboarding/account_setup_screen.dart';
import '../settings/settings_sheet.dart';
import '../shell/shell_actions.dart';
import '../sidebar/sidebar_model.dart';
import 'phone_bars.dart';
import 'phone_compose_screen.dart';
import 'phone_route.dart';
import 'phone_thread_screen.dart';
import 'sheets.dart';
import 'undo.dart';

/// The mail on a phone: the mailbox's name and account on top, the conversations, and a
/// bar of buttons at the bottom: Mailboxes, Search, Unread, Compose.
class PhoneShell extends ConsumerStatefulWidget {
  const PhoneShell({super.key});

  @override
  ConsumerState<PhoneShell> createState() => _PhoneShellState();
}

class _PhoneShellState extends ConsumerState<PhoneShell> {
  final _listKey = GlobalKey<ThreadListBodyState>();
  final _refreshKey = GlobalKey<RefreshIndicatorState>();
  final _rowMenu = MenuController();
  final _menuArea = GlobalKey();

  /// The conversation whose long-press menu is open.
  Thread? _menuThread;
  bool _searching = false;
  bool _scrolled = false;
  Timer? _typing;

  @override
  void dispose() {
    _typing?.cancel();
    super.dispose();
  }

  ShellActions _actions(BuildContext context) =>
      ShellActions(ref: ref, context: context, listKey: _listKey);

  /// The mailbox shown, without the Unread filter (and without a search being typed).
  String get _base =>
      _listKey.currentState?.base ??
      withoutFilter(ref.read(queryProvider), ref.read(listFilterProvider));

  String? get _scope => parseMailbox(_base)?.scope;

  void _openThread(int id) {
    ref.read(selectedThreadIdProvider.notifier).select(id);
    Navigator.of(context)
        .push(phonePage((_) => PhoneThreadScreen(threadId: id)));
  }

  /// Show [query] from its top, leaving search.
  void _goTo(String query) {
    if (_searching) _leaveSearch();
    ref.read(queryProvider.notifier).set(query);
    _listKey.currentState?.scrollToTop();
  }

  void _enterSearch() {
    if (_searching) {
      _listKey.currentState?.focusSearch();
      return;
    }
    setState(() => _searching = true);
  }

  void _leaveSearch() {
    if (!_searching) return;
    _typing?.cancel();
    final list = _listKey.currentState;
    list?.searchController.clear();
    list?.onSearchChanged('');
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _searching = false);
  }

  void _typed(String v) {
    _typing?.cancel();
    _typing = Timer(const Duration(milliseconds: 200), () {
      _listKey.currentState?.onSearchChanged(v);
    });
    setState(() {});
  }

  void _searchNow(String v) {
    _typing?.cancel();
    _listKey.currentState?.onSearchChanged(v);
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _mailboxes() {
    _leaveSearch();
    showMailboxSheet(
      context,
      onPick: _goTo,
      onAddAccount: _addAccount,
      onSettings: _settings,
    );
  }

  void _compose() {
    _leaveSearch();
    final accounts = ref.read(accountsProvider).value ?? const <Account>[];
    final scoped = accounts.where((a) => a.email == _scope).firstOrNull;
    _actions(context).openNew(accountId: scoped?.id);
  }

  void _addAccount() => Navigator.of(context).push(
    phonePage(
      (_) => AccountSetupScreen(
        // The new account's mail is among all of them.
        onAdded: (_) => _goTo(mailboxQuery(FolderRole.inbox, null)),
      ),
    ),
  );

  void _settings() => showSettingsSheet(context);

  void _pickAccount(String? email) {
    final m = parseMailbox(_base);
    _goTo(
      mailboxQuery(
        m?.role,
        email,
        label: m?.label,
        snoozed: m?.snoozed ?? false,
      ),
    );
  }

  /// Back: out of search, then to the Inbox, then out of the app.
  bool get _atHome {
    if (_searching) return false;
    final m = parseMailbox(_base);
    return m != null &&
        m.role == FolderRole.inbox &&
        m.label == null &&
        !m.snoozed;
  }

  void _back() {
    if (_searching) {
      _leaveSearch();
    } else {
      _goTo(mailboxQuery(FolderRole.inbox, _scope));
    }
  }

  Future<void> _openRowMenu(Thread t, Offset at) async {
    final box = _menuArea.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    unawaited(HapticFeedback.mediumImpact());
    ref.read(selectedThreadIdProvider.notifier).select(t.id);
    setState(() => _menuThread = t);
    _rowMenu.open(position: box.globalToLocal(at));
  }

  /// Where swiping right archives: the Inbox (any account, Unread or not).
  bool get _archiveHere {
    if (_searching) return false;
    final m = parseMailbox(_base);
    return m != null &&
        m.role == FolderRole.inbox &&
        m.label == null &&
        !m.snoozed;
  }

  /// Where swiping left deletes: the Inbox, Starred, Snoozed, Archive, labels and search.
  bool get _deleteHere {
    if (_searching) return true;
    final m = parseMailbox(_base);
    if (m == null || m.snoozed || m.label != null) return true;
    return const {
      FolderRole.inbox,
      FolderRole.starred,
      FolderRole.archive,
      FolderRole.all,
    }.contains(m.role);
  }

  Widget _swipe(Thread t, Widget row) {
    final archive = _archiveHere;
    final delete = _deleteHere;
    if (!archive && !delete) return row;
    final s = context.s;
    return Dismissible(
      key: ValueKey('swipe-${t.id}'),
      direction: archive && delete
          ? DismissDirection.horizontal
          : archive
          ? DismissDirection.startToEnd
          : DismissDirection.endToStart,
      dismissThresholds: const {
        DismissDirection.startToEnd: 0.35,
        DismissDirection.endToStart: 0.35,
      },
      background: _SwipeLabel(
        color: archive ? s.blue : s.red,
        icon: archive ? AppIcons.archive : AppIcons.delete,
        label: archive ? 'Archive' : 'Delete',
        alignment: archive ? Alignment.centerLeft : Alignment.centerRight,
      ),
      secondaryBackground: _SwipeLabel(
        color: s.red,
        icon: AppIcons.delete,
        label: 'Delete',
        alignment: Alignment.centerRight,
      ),
      movementDuration: Motion.base,
      onUpdate: (d) {
        if (d.reached && !d.previousReached) HapticFeedback.selectionClick();
      },
      onDismissed: (direction) {
        _listKey.currentState?.dismissLocally(t.id);
        ref
            .read(pendingFilingProvider.notifier)
            .start(
              t.id,
              direction == DismissDirection.startToEnd
                  ? FilingKind.archive
                  : FilingKind.trash,
            );
      },
      child: row,
    );
  }

  List<Widget> _rowMenuItems(BuildContext context) {
    final t = _menuThread;
    if (t == null) return const [];
    final s = context.s;
    final actions = _actions(context);
    final repo = ref.read(repositoryProvider);
    final notice = ref.read(noticeProvider.notifier);
    // Reply all only where the last message went to several people (when it is loaded).
    final last = ref.read(messagesProvider(t.id)).value?.lastOrNull;
    final replyAll = (last?.to.length ?? 0) > 1;
    return [
      PhoneMenuItem(
        title: 'Reply',
        leading: Icon(AppIcons.reply, size: 20),
        onPressed: () => actions.openReply(),
      ),
      if (replyAll)
        PhoneMenuItem(
          title: 'Reply all',
          leading: Icon(AppIcons.replyAll, size: 20),
          onPressed: () => actions.openReply(all: true),
        ),
      PhoneMenuItem(
        title: 'Forward',
        leading: Icon(AppIcons.forward, size: 20),
        onPressed: actions.openForward,
      ),
      const Divider(height: 1),
      if (_archiveHere)
        PhoneMenuItem(
          title: 'Archive',
          leading: Icon(AppIcons.archive, size: 20),
          onPressed: actions.archiveSelected,
        ),
      PhoneMenuItem(
        title: 'Delete',
        danger: true,
        leading: Icon(AppIcons.delete, size: 20, color: s.red),
        onPressed: actions.trashSelected,
      ),
      PhoneMenuItem(
        title: 'Move to…',
        leading: Icon(AppIcons.move, size: 20),
        onPressed: actions.moveSelected,
      ),
      if (t.snoozed)
        PhoneMenuItem(
          title: 'Unsnooze',
          leading: Icon(AppIcons.snooze, size: 20),
          onPressed: () async {
            await repo.unsnooze(t.id);
            notice.show('Back in the inbox');
          },
        )
      else
        PhoneMenuItem(
          title: 'Snooze…',
          leading: Icon(AppIcons.snooze, size: 20),
          onPressed: actions.snoozeSelected,
        ),
      const Divider(height: 1),
      PhoneMenuItem(
        title: t.starred ? 'Remove star' : 'Star',
        leading: Icon(t.starred ? AppIcons.starOn : AppIcons.star, size: 20),
        onPressed: () => repo.star(t.id, !t.starred),
      ),
      PhoneMenuItem(
        title: t.unread ? 'Mark as read' : 'Mark as unread',
        leading: Icon(t.unread ? AppIcons.markRead : AppIcons.unread, size: 20),
        onPressed: () =>
            t.unread ? repo.markRead(t.id, true) : actions.markUnread(),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    ref.listen<Draft?>(composeProvider, (prev, next) {
      if (prev == null && next != null) openPhoneCompose(context, ref);
    });
    // A conversation asked for from outside (a tapped notification): the whole Inbox,
    // then its page.
    ref.listen<int?>(openThreadProvider, (_, id) {
      if (id == null) return;
      ref.read(openThreadProvider.notifier).done();
      _leaveSearch();
      ref.read(listFilterProvider.notifier).set('all');
      _goTo(mailboxQuery(FolderRole.inbox, null));
      _openThread(id);
    });
    final filter = ref.watch(listFilterProvider);
    ref.watch(queryProvider);
    final list = ThreadListBody(
      key: _listKey,
      phone: true,
      searching: _searching,
      refreshKey: _refreshKey,
      pressedId: _menuThread?.id,
      onOpen: _openThread,
      onRowMenu: _openRowMenu,
      rowWrapper: _swipe,
    );
    return PopScope(
      canPop: _atHome,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: s.bg,
        appBar: _searching
            ? PhoneSearchBar(
                controller: _listKey.currentState?.searchController,
                focusNode: _listKey.currentState?.searchFocus,
                onChanged: _typed,
                onSubmitted: _searchNow,
                onCancel: _leaveSearch,
              )
            : PhoneAppBar(
                scrolled: _scrolled,
                onPickAccount: _pickAccount,
                onAddAccount: _addAccount,
                onSettings: _settings,
                onCheck: () => _refreshKey.currentState?.show(),
              ),
        body: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.depth == 0) {
              final scrolled = n.metrics.pixels > 0;
              if (scrolled != _scrolled) setState(() => _scrolled = scrolled);
            }
            return false;
          },
          child: MenuAnchor(
            controller: _rowMenu,
            menuChildren: _rowMenuItems(context),
            onClose: () => setState(() => _menuThread = null),
            child: KeyedSubtree(key: _menuArea, child: list),
          ),
        ),
        bottomNavigationBar: PhoneBottomBar(
          items: [
            BarItem(
              icon: AppIcons.mailboxes,
              label: 'Mailboxes',
              onTap: _mailboxes,
            ),
            BarItem(
              icon: AppIcons.search,
              label: 'Search',
              on: _searching,
              onTap: _enterSearch,
            ),
            BarItem(
              icon: AppIcons.unread,
              iconOn: AppIcons.unreadOn,
              label: 'Unread',
              on: filter == 'unread',
              onTap: ref.read(listFilterProvider.notifier).toggleUnread,
            ),
            BarItem(
              icon: AppIcons.compose,
              label: 'Compose',
              accent: true,
              onTap: _compose,
            ),
          ],
        ),
      ),
    );
  }
}

class _SwipeLabel extends StatelessWidget {
  const _SwipeLabel({
    required this.color,
    required this.icon,
    required this.label,
    required this.alignment,
  });
  final Color color;
  final IconData icon;
  final String label;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final fg = context.s.isDark ? context.s.bg : Colors.white;
    return Container(
      color: color,
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 22, color: fg),
          const SizedBox(height: 4),
          Text(
            label,
            style: ui(context, size: 13, weight: FontWeight.w500, color: fg),
          ),
        ],
      ),
    );
  }
}

String _hhmm(DateTime d) {
  final l = d.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

/// The mailbox's name, and under it the account (a menu of them when there are several)
/// and when mail was last checked; More on the right.
class PhoneAppBar extends ConsumerWidget implements PreferredSizeWidget {
  const PhoneAppBar({
    super.key,
    required this.scrolled,
    required this.onPickAccount,
    required this.onAddAccount,
    required this.onSettings,
    required this.onCheck,
  });

  /// The list is scrolled: a hairline sets the bar off from it.
  final bool scrolled;
  final void Function(String? email) onPickAccount;
  final VoidCallback onAddAccount;
  final VoidCallback onSettings;
  final VoidCallback onCheck;

  @override
  Size get preferredSize => const Size.fromHeight(Touch.appBar);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final filter = ref.watch(listFilterProvider);
    final base = withoutFilter(ref.watch(queryProvider), filter);
    final scope = parseMailbox(base)?.scope;
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final sync = ref.watch(syncStatusProvider);
    final many = accounts.length > 1;
    final signInNeeded = accounts.any((a) => a.needsPassword);
    final syncText = sync.syncing
        ? 'Checking for mail…'
        : sync.lastOk != null
        ? 'Updated ${_hhmm(sync.lastOk!)}'
        : 'Not updated yet';
    final who =
        scope ?? (many ? 'All accounts' : accounts.firstOrNull?.email ?? '');
    final line2 = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            '${filter == 'unread' ? 'Unread only · ' : ''}$who',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ui(context, size: 13, color: s.fg2, height: 1.3),
          ),
        ),
        if (many) ...[
          const SizedBox(width: 2),
          Icon(AppIcons.expand, size: 14, color: s.fg2),
        ],
        Text(
          ' · $syncText',
          maxLines: 1,
          style: ui(context, size: 13, color: s.fg2, height: 1.3),
        ),
      ],
    );
    final block = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: Touch.target),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            mailboxTitle(base),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ui(context, size: 20, weight: FontWeight.w600, height: 1.25),
          ),
          line2,
        ],
      ),
    );
    final unreadAll = accounts.fold<int>(0, (n, a) => n + a.unread);
    Widget count(int n) =>
        Text(n > 0 ? '$n' : '', style: mono(context, size: 12.5, color: s.fg2));
    final title = !many
        ? Semantics(header: true, child: block)
        : MenuAnchor(
            alignmentOffset: const Offset(0, 4),
            menuChildren: [
              PhoneMenuItem(
                title: 'All accounts',
                trailing: count(unreadAll),
                onPressed: () => onPickAccount(null),
              ),
              for (final a in accounts)
                PhoneMenuItem(
                  title: a.email,
                  leading: Dot(color: a.color, size: 10),
                  subtitle: a.needsPassword ? 'Sign-in needed' : null,
                  subtitleColor: s.red,
                  trailing: count(a.unread),
                  onPressed: () => onPickAccount(a.email),
                ),
              const Divider(height: 1),
              PhoneMenuItem(
                title: 'Add account',
                leading: Icon(AppIcons.addAccount, size: 20),
                onPressed: onAddAccount,
              ),
            ],
            builder: (context, controller, _) => Semantics(
              button: true,
              label: 'Choose account',
              child: InkWell(
                borderRadius: BorderRadius.circular(Touch.radius),
                onTap: () =>
                    controller.isOpen ? controller.close() : controller.open(),
                child: block,
              ),
            ),
          );
    return AppBar(
      backgroundColor: s.bg,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      toolbarHeight: Touch.appBar,
      automaticallyImplyLeading: false,
      centerTitle: false,
      titleSpacing: Touch.gutter,
      shape: scrolled ? Border(bottom: BorderSide(color: s.border)) : null,
      title: title,
      actions: [
        MenuAnchor(
          alignmentOffset: const Offset(-8, 0),
          menuChildren: [
            PhoneMenuItem(
              title: sync.syncing ? 'Checking…' : 'Check for new mail',
              leading: Icon(AppIcons.sync, size: 20),
              trailing: sync.lastOk == null
                  ? null
                  : Text(
                      _hhmm(sync.lastOk!),
                      style: mono(context, size: 12.5, color: s.fg2),
                    ),
              onPressed: sync.syncing ? null : onCheck,
            ),
            PhoneMenuItem(
              title: 'Add account',
              leading: Icon(AppIcons.addAccount, size: 20),
              onPressed: onAddAccount,
            ),
            PhoneMenuItem(
              title: 'Settings',
              leading: Icon(AppIcons.settings, size: 20),
              subtitle: signInNeeded ? 'Sign-in needed' : null,
              subtitleColor: s.red,
              onPressed: onSettings,
            ),
          ],
          builder: (context, controller, _) => IconButton(
            tooltip: 'More',
            icon: Icon(AppIcons.more, color: s.fg),
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
          ),
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}

/// Search in place of the title: the field, and a way back (an arrow on Android,
/// Cancel on iOS).
class PhoneSearchBar extends StatelessWidget implements PreferredSizeWidget {
  const PhoneSearchBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmitted,
    required this.onCancel,
  });
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onCancel;

  @override
  Size get preferredSize => const Size.fromHeight(Touch.appBar);

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final ios = defaultTargetPlatform == TargetPlatform.iOS;
    final text = controller?.text ?? '';
    final field = SizedBox(
      height: 44,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.search,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        style: ui(context, size: 16),
        cursorColor: s.accentStrong,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: s.panel,
          hintText: 'Search mail',
          hintStyle: ui(context, size: 16, color: s.fg3),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          prefixIcon: Icon(AppIcons.search, size: 18, color: s.fg2),
          suffixIcon: text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear',
                  icon: Icon(AppIcons.clear, size: 18, color: s.fg2),
                  onPressed: () {
                    controller?.clear();
                    onChanged('');
                    focusNode?.requestFocus();
                  },
                ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Touch.radius),
            borderSide: BorderSide(color: s.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Touch.radius),
            borderSide: BorderSide(color: s.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Touch.radius),
            borderSide: BorderSide(color: s.accentStrong),
          ),
        ),
      ),
    );
    return AppBar(
      backgroundColor: s.bg,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      toolbarHeight: Touch.appBar,
      automaticallyImplyLeading: false,
      centerTitle: false,
      titleSpacing: ios ? Touch.gutter : 0,
      leading: ios
          ? null
          : IconButton(
              tooltip: 'Back',
              icon: Icon(AppIcons.back, color: s.fg),
              onPressed: onCancel,
            ),
      title: field,
      actions: [
        if (ios)
          TextButton(onPressed: onCancel, child: const Text('Cancel'))
        else
          const SizedBox(width: 12),
      ],
    );
  }
}
