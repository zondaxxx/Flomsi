import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../thread/snooze.dart';
import '../../platform.dart';
import '../../state/providers.dart';
import '../accounts/add_account_sheet.dart';
import '../settings/settings_sheet.dart';
import '../shell/file_away.dart';
import '../sidebar/sidebar_model.dart';
import '../phone/phone_list_parts.dart';
import '../phone/phone_thread_row.dart';
import '../../theme/app_icons.dart';
import '../../theme/motion.dart';
import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';

/// Filter row + animated thread rows. The search field itself lives in the top bar on desktop.
class ThreadListBody extends ConsumerStatefulWidget {
  const ThreadListBody({
    super.key,
    this.onOpen,
    this.showSearch = false,
    this.phone = false,
    this.searching = false,
    this.refreshKey,
    this.pressedId,
    this.onRowMenu,
    this.rowWrapper,
    this.rowActions,
  });
  final void Function(int threadId)? onOpen;

  /// Narrow windows have no top-bar field, so the list carries its own.
  final bool showSearch;

  /// The phone list: big rows, no filter chips (the bottom bar has them), states and
  /// "Load older mail" inside the scroll view.
  final bool phone;

  /// Phones: the search bar is up. An empty field shows what can be searched for.
  final bool searching;

  /// Phones: the pull-to-refresh, so "Check for new mail" can show it.
  final GlobalKey<RefreshIndicatorState>? refreshKey;

  /// Phones: the row whose menu is open, highlighted meanwhile.
  final int? pressedId;

  /// Phones: a long press on a row, at that point on the screen.
  final void Function(Thread thread, Offset position)? onRowMenu;

  /// Phones: what a row is wrapped in (swipe actions).
  final Widget Function(Thread thread, Widget row)? rowWrapper;

  /// Phones: the row's actions for a screen reader.
  final Map<CustomSemanticsAction, VoidCallback> Function(Thread thread)?
  rowActions;

  @override
  ConsumerState<ThreadListBody> createState() => ThreadListBodyState();
}

class ThreadListBodyState extends ConsumerState<ThreadListBody> {
  final searchController = TextEditingController();
  final searchFocus = FocusNode(debugLabel: 'search');

  /// An AnimatedList's state, or a SliverAnimatedList's on phones.
  var _listKey = GlobalKey();
  final _items = <Thread>[];

  /// The query [_items] shows. A different query is a different list: it starts at its
  /// top instead of animating from the old one.
  String? _itemsQuery;
  // A new list for a new query starts at its top; nothing to restore.
  final _scroll = ScrollController(keepScrollOffset: false);
  final _selectedRowKey = GlobalKey(debugLabel: 'selected row');
  String get _filter => ref.read(listFilterProvider);

  /// The folder, account or label the list shows (set from outside: sidebar, keys,
  /// notifications). Filters narrow it; typed search looks everywhere.
  String _base = '';

  /// The last query this list set itself, to tell it from one set from outside.
  String? _composed;

  @override
  void initState() {
    super.initState();
    // The filter outlives a list (a phone turned into a tablet): what it added to the
    // query is not part of the mailbox.
    _base = withoutFilter(
      ref.read(queryProvider),
      ref.read(listFilterProvider),
    );
    searchFocus.addListener(
      () => ref
          .read(scopeProvider.notifier)
          .set(searchFocus.hasFocus ? 'search' : 'list'),
    );
  }

  @override
  void dispose() {
    searchController.dispose();
    searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void focusSearch() => searchFocus.requestFocus();

  /// The folder, account or label under the filter and the search.
  String get base => _base;

  void scrollToTop() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void onSearchChanged(String v) => _setQuery(_compose(v));

  void _setQuery(String q) {
    _composed = q;
    ref.read(queryProvider.notifier).set(q);
  }

  String _compose(String typed) {
    final q = typed.trim().isEmpty ? _base : typed.trim();
    return switch (_filter) {
      'unread' => '$q is:unread'.trim(),
      'starred' => '$q is:starred'.trim(),
      _ => q,
    };
  }

  /// A selection far from the rows on screen (k with nothing selected, a thread opened
  /// from elsewhere) has no row built for RevealOnSelect: jump near it first.
  void _revealFar(int? id) {
    // Phones open a conversation on its own page: the list stays where it was.
    if (id == null || widget.phone) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (_selectedRowKey.currentContext != null) return;
      final i = _items.indexWhere((t) => t.id == id);
      if (i < 0) return;
      final pos = _scroll.position;
      final row = (pos.maxScrollExtent + pos.viewportDimension) / _items.length;
      pos.jumpTo(
        (i * row - (pos.viewportDimension - row) / 2).clamp(
          0.0,
          pos.maxScrollExtent,
        ),
      );
    });
  }

  void _removeRow(int i, AnimatedRemovedItemBuilder builder, Duration d) {
    final st = _listKey.currentState;
    if (st is AnimatedListState) st.removeItem(i, builder, duration: d);
    if (st is SliverAnimatedListState) st.removeItem(i, builder, duration: d);
  }

  void _insertRow(int i, Duration d) {
    final st = _listKey.currentState;
    if (st is AnimatedListState) st.insertItem(i, duration: d);
    if (st is SliverAnimatedListState) st.insertItem(i, duration: d);
  }

  Widget _plainRow(Thread t) => widget.phone
      ? PhoneThreadRow(thread: t)
      : ThreadRow(thread: t, selected: false);

  /// A swiped row leaves the list at once; the repository event that follows finds it already gone.
  void dismissLocally(int threadId) {
    final i = _items.indexWhere((t) => t.id == threadId);
    if (i < 0) return;
    _items.removeAt(i);
    _removeRow(i, (context, anim) => const SizedBox.shrink(), Duration.zero);
  }

  /// Diff the provider's list into the AnimatedList: removals collapse, insertions rise in.
  void _sync(List<Thread> next) {
    final d = Motion.of(context, Motion.base);
    for (var i = _items.length - 1; i >= 0; i--) {
      if (!next.any((t) => t.id == _items[i].id)) {
        final removed = _items.removeAt(i);
        _removeRow(
          i,
          (context, anim) => _Transition(anim: anim, child: _plainRow(removed)),
          d,
        );
      }
    }
    for (var j = 0; j < next.length; j++) {
      if (j < _items.length && _items[j].id == next[j].id) {
        _items[j] = next[j];
        continue;
      }
      final existing = _items.indexWhere((t) => t.id == next[j].id);
      if (existing >= 0) {
        _items.removeAt(existing);
        _removeRow(
          existing,
          (context, anim) => const SizedBox.shrink(),
          Duration.zero,
        );
      }
      _items.insert(j, next[j]);
      _insertRow(j, d);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final draftsView = ref.watch(queryProvider).trim() == 'in:drafts';
    final draftCount = draftsView
        ? ref.watch(draftsProvider).value?.length ?? 0
        : 0;
    final threads = ref.watch(threadsProvider);
    final selected = ref.watch(selectedThreadIdProvider);
    final syncError = ref.watch(
      syncStatusProvider.select((st) => st.lastError),
    );
    final accounts = ref.watch(accountsProvider).value;
    final locked = [...?accounts?.where((a) => a.needsPassword)];
    final query = ref.watch(queryProvider);
    final sameQuery = query == _itemsQuery;
    final list = threads.value;
    if (list != null) {
      if (sameQuery) {
        _sync(list);
      } else if (!threads.isLoading && !threads.hasError) {
        _items
          ..clear()
          ..addAll(list);
        _itemsQuery = query;
        _listKey = GlobalKey();
      }
    }
    ref.listen(selectedThreadIdProvider, (_, id) => _revealFar(id));
    // Another folder chosen elsewhere: it becomes the base, and the filter and search
    // text that belonged to the last one go.
    ref.listen(queryProvider, (_, next) {
      if (next == _composed) return;
      _composed = null;
      _base = next;
      searchController.clear();
      ref.read(listFilterProvider.notifier).set('all');
    });
    // The filter changed (chips here, the phone's Unread button): narrow the mailbox.
    ref.listen(listFilterProvider, (_, _) {
      _setQuery(_compose(searchController.text));
    });
    final filter = ref.watch(listFilterProvider);
    if (widget.phone) {
      return _phoneBody(
        context,
        threads: threads,
        sameQuery: sameQuery,
        selected: selected,
        accounts: accounts,
        locked: locked,
        syncError: syncError,
        query: query,
        filter: filter,
        draftsView: draftsView,
      );
    }
    // Counts only where they mean what they say: over a filtered list they would not.
    final unread = filter == 'all' ? list?.where((t) => t.unread).length : null;
    final starred = filter == 'all'
        ? list?.where((t) => t.starred).length
        : null;

    return Column(
      children: [
        if (widget.showSearch)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
            child: QuietField(
              controller: searchController,
              focusNode: searchFocus,
              hint: 'Search mail',
              height: 32,
              leading: Icon(CupertinoIcons.search, size: 14, color: s.fg3),
              onChanged: onSearchChanged,
            ),
          ),
        Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: s.border)),
          ),
          child: Row(
            children: [
              if (draftsView)
                _FilterButton(
                  label: 'On this device',
                  count: draftCount,
                  active: true,
                  onTap: () {},
                )
              else ...[
                _FilterButton(
                  label: 'All',
                  count: filter == 'all' ? list?.length : null,
                  active: filter == 'all',
                  onTap: () => _setFilter('all'),
                ),
                _FilterButton(
                  label: 'Unread',
                  count: unread,
                  active: filter == 'unread',
                  onTap: () => _setFilter('unread'),
                ),
                _FilterButton(
                  label: 'Starred',
                  count: starred,
                  active: filter == 'starred',
                  onTap: () => _setFilter('starred'),
                ),
              ],
            ],
          ),
        ),
        for (final a in locked)
          _SignInBanner(key: ValueKey('signin-${a.id}'), account: a),
        if (syncError != null && (accounts?.isNotEmpty ?? true))
          Container(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: s.border)),
            ),
            child: Row(
              children: [
                Icon(
                  CupertinoIcons.exclamationmark_circle,
                  size: 13,
                  color: s.red,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    syncError,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: mono(context, size: 11, color: s.red),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: draftsView
              ? const _DraftList()
              : threads.when(
                  // A sync event reloads the list; keep showing it meanwhile. A new
                  // folder or search waits for its own rows.
                  skipLoadingOnReload: sameQuery,
                  loading: () => const SizedBox.shrink(),
                  error: (e, _) => Center(
                    child: Text('$e', style: mono(context, color: s.red)),
                  ),
                  data: (_) => _items.isEmpty
                      ? (accounts != null && accounts.isEmpty
                            ? const FirstRun()
                            : const EmptyNote('No mail'))
                      : _pullToRefresh(
                          AnimatedList(
                            key: _listKey,
                            controller: _scroll,
                            // On a phone the list always scrolls, so a short one can be
                            // pulled down to refresh too.
                            physics: _touch
                                ? const AlwaysScrollableScrollPhysics()
                                : null,
                            initialItemCount: _items.length,
                            itemBuilder: (context, i, anim) {
                              if (i >= _items.length) {
                                return const SizedBox.shrink();
                              }
                              final t = _items[i];
                              final row = ThreadRow(
                                thread: t,
                                selected: t.id == selected,
                                onTap: () {
                                  ref
                                      .read(selectedThreadIdProvider.notifier)
                                      .select(t.id);
                                  widget.onOpen?.call(t.id);
                                },
                              );
                              return _Transition(
                                anim: anim,
                                child: RevealOnSelect(
                                  key: ValueKey('reveal-${t.id}'),
                                  selected: t.id == selected,
                                  child: KeyedSubtree(
                                    key: t.id == selected
                                        ? _selectedRowKey
                                        : null,
                                    child: _touch ? _swipeable(t, row) : row,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                ),
        ),
        if (!draftsView &&
            (accounts?.isNotEmpty ?? false) &&
            MoreFromServer.offered(query))
          MoreFromServer(
            key: ValueKey('more-$query'),
            query: query,
            shown: list?.length ?? 0,
          ),
      ],
    );
  }

  /// The phone list: banners, the rows (or what an empty mailbox says), then older mail,
  /// all in one scroll view that pulls down to check for mail.
  Widget _phoneBody(
    BuildContext context, {
    required AsyncValue<List<Thread>> threads,
    required bool sameQuery,
    required int? selected,
    required List<Account>? accounts,
    required List<Account> locked,
    required String? syncError,
    required String query,
    required String filter,
    required bool draftsView,
  }) {
    final repo = ref.read(repositoryProvider);
    final s = context.s;
    final many = (accounts?.length ?? 0) > 1;
    final typed = searchController.text.trim();
    // Accounts that stopped for another reason than their sign-in.
    final failing = [
      ...?accounts?.where((a) => a.problem != null && !a.needsPassword),
    ];
    final syncText = failing.length > 1
        ? '${failing.length} accounts didn’t update'
        : failing.length == 1
        ? '${failing.single.email}: ${failing.single.problem!.title}'
        : locked.isEmpty
        ? syncError
        : null;
    final scoped = query.contains('account:');
    Color? colorOf(Thread t) => many && !scoped
        ? accounts!.where((a) => a.id == t.accountId).firstOrNull?.color
        : null;
    Widget fill(Widget child) =>
        SliverFillRemaining(hasScrollBody: false, child: child);
    final slivers = <Widget>[
      for (final a in locked)
        SliverToBoxAdapter(
          child: PhoneSignInBanner(key: ValueKey('signin-${a.id}'), account: a),
        ),
      if (syncText != null && (accounts?.isNotEmpty ?? false))
        SliverToBoxAdapter(child: PhoneSyncBanner(text: syncText)),
    ];
    if (widget.searching && typed.isEmpty) {
      slivers.add(
        fill(
          PhoneSearchHint(
            onExample: (example) {
              searchController.text = example;
              searchController.selection = TextSelection.collapsed(
                offset: example.length,
              );
              onSearchChanged(example);
            },
          ),
        ),
      );
    } else if (draftsView) {
      slivers.add(const _PhoneDrafts());
    } else {
      slivers.add(
        threads.when(
          skipLoadingOnReload: sameQuery,
          loading: () => fill(const DelayedSpinner()),
          error: (e, _) => fill(
            PhoneEmpty(
              title: 'Couldn’t open the mail stored on this phone',
              detail: '$e',
              action: 'Try again',
              onAction: () => ref.invalidate(storedThreadsProvider),
            ),
          ),
          data: (_) => _items.isEmpty
              ? fill(PhoneEmptyMailbox(query: query, filter: filter))
              : SliverMainAxisGroup(
                  slivers: [
                    if (widget.searching)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(28, 8, 16, 4),
                          child: Text(
                            'On this phone',
                            style: ui(context, size: 13, color: s.fg2),
                          ),
                        ),
                      ),
                    SliverAnimatedList(
                      key: _listKey,
                      initialItemCount: _items.length,
                      // Rows keep their state (a swipe under way) when rows above
                      // them come or go.
                      findChildIndexCallback: (key) {
                        final i = _items.indexWhere(
                          (t) => ValueKey('row-${t.id}') == key,
                        );
                        return i < 0 ? null : i;
                      },
                      itemBuilder: (context, i, anim) {
                        if (i >= _items.length) return const SizedBox.shrink();
                        final t = _items[i];
                        final Widget row = PhoneThreadRow(
                          thread: t,
                          selected: t.id == widget.pressedId,
                          accountColor: colorOf(t),
                          onTap: () {
                            ref
                                .read(selectedThreadIdProvider.notifier)
                                .select(t.id);
                            widget.onOpen?.call(t.id);
                          },
                          onLongPress: widget.onRowMenu == null
                              ? null
                              : (at) => widget.onRowMenu!(t, at),
                          actions: widget.rowActions?.call(t) ?? const {},
                        );
                        return _Transition(
                          key: ValueKey('row-${t.id}'),
                          anim: anim,
                          child: Column(
                            children: [
                              widget.rowWrapper?.call(t, row) ?? row,
                              Padding(
                                padding: const EdgeInsets.only(left: 28),
                                child: Divider(height: 1, color: s.border),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
        ),
      );
      if ((accounts?.isNotEmpty ?? false) &&
          MoreFromServer.offered(query) &&
          _items.isNotEmpty) {
        slivers.add(
          SliverToBoxAdapter(
            child: MoreFromServer(
              key: ValueKey('more-$query'),
              query: query,
              shown: threads.value?.length ?? 0,
              phone: true,
            ),
          ),
        );
      }
    }
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 8)));
    return RefreshIndicator.adaptive(
      key: widget.refreshKey,
      onRefresh: repo.sync,
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: slivers,
      ),
    );
  }

  static bool get _touch => kTouch;

  /// Phones: pull the list down to sync now (the platform's own spinner).
  Widget _pullToRefresh(Widget list) => _touch
      ? RefreshIndicator.adaptive(
          onRefresh: () => ref.read(repositoryProvider).sync(),
          child: list,
        )
      : list;

  /// Swipe right to archive, left to delete. The action is local-first, like the keyboard path.
  Widget _swipeable(Thread t, Widget row) {
    final s = context.s;
    return Dismissible(
      key: ValueKey('thread-${t.id}'),
      background: _SwipeBackground(
        color: s.blue,
        icon: CupertinoIcons.archivebox,
        label: 'Archive',
        alignment: Alignment.centerLeft,
      ),
      secondaryBackground: _SwipeBackground(
        color: s.red,
        icon: CupertinoIcons.trash,
        label: 'Delete',
        alignment: Alignment.centerRight,
      ),
      movementDuration: Motion.base,
      onDismissed: (direction) async {
        dismissLocally(t.id);
        final notice = ref.read(noticeProvider.notifier);
        final archive = direction == DismissDirection.startToEnd;
        final n = await fileAway(
          context,
          ref.read(repositoryProvider),
          notice,
          t.id,
          archive: archive,
        );
        if (n != null && n > 0) {
          notice.show(archive ? 'Archived' : 'Deleted');
          return;
        }
        // Nothing moved (not in the inbox, already deleted, or no folder for it): bring
        // the row back.
        if (n == 0) {
          notice.show(archive ? 'Not in the inbox' : 'Nothing to delete');
        }
        if (mounted) ref.invalidate(storedThreadsProvider);
      },
      child: row,
    );
  }

  void _setFilter(String f) => ref.read(listFilterProvider.notifier).set(f);
}

/// An account the server stopped letting in: say which and why, and where to fix it.
class _SignInBanner extends StatelessWidget {
  const _SignInBanner({super.key, required this.account});
  final Account account;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      decoration: BoxDecoration(
        color: s.red.withValues(alpha: 0.06),
        border: Border(bottom: BorderSide(color: s.border)),
      ),
      child: Row(
        children: [
          Icon(CupertinoIcons.lock, size: 13, color: s.red),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${account.email}: ${account.problem?.title ?? 'needs a password'}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ui(context, size: 12, color: s.red),
            ),
          ),
          const SizedBox(width: 8),
          SmallButton(
            label: 'Enter password',
            height: 22,
            onPressed: () => showSettingsSheet(context),
          ),
        ],
      ),
    );
  }
}

/// No account yet: what this is, what it needs, one button.
class FirstRun extends StatelessWidget {
  const FirstRun({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'No accounts yet',
                style: ui(context, size: 15, weight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                'Add a mailbox over IMAP: Gmail, iCloud, Yandex, Mail.ru, Fastmail, '
                'Proton through its Bridge, or any server you know the address of.',
                style: ui(context, size: 12.5, color: s.fg2, height: 1.45),
              ),
              const SizedBox(height: 8),
              Text(
                'Most providers want an app password, made in the account’s '
                'security settings; your usual password is refused.',
                style: ui(context, size: 12, color: s.fg3, height: 1.45),
              ),
              const SizedBox(height: 16),
              SmallButton(
                label: 'Add account',
                primary: true,
                height: 28,
                onPressed: () => showAddAccountSheet(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({
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
    final s = context.s;
    return Container(
      color: color,
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 20, color: s.bg),
          const SizedBox(height: 3),
          Text(label, style: mono(context, size: 10.5, color: s.bg)),
        ],
      ),
    );
  }
}

class _Transition extends StatelessWidget {
  const _Transition({super.key, required this.anim, required this.child});
  final Animation<double> anim;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: anim, curve: Motion.curve);
    return SizeTransition(
      sizeFactor: curved,
      alignment: Alignment.topCenter,
      child: FadeTransition(opacity: curved, child: child),
    );
  }
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({
    required this.label,
    required this.count,
    required this.active,
    required this.onTap,
  });
  final String label;
  final int? count;
  final bool active;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final count = this.count;
    return HoverRegion(
      onTap: onTap,
      builder: (context, hovered) => AnimatedContainer(
        duration: Motion.of(context, Motion.fast),
        height: 24,
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: active ? s.raised : (hovered ? s.hover : Colors.transparent),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            Text(
              label,
              style: ui(context, size: 12, color: active ? s.fg : s.fg2),
            ),
            if (count != null) ...[
              const SizedBox(width: 5),
              Text(
                '$count',
                style: mono(context, size: 11, color: active ? s.fg2 : s.fg3),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Two lines: sender · chips · time, then subject — preview.
class ThreadRow extends StatelessWidget {
  const ThreadRow({
    super.key,
    required this.thread,
    required this.selected,
    this.onTap,
  });
  final Thread thread;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = thread;
    return HoverRegion(
      onTap: onTap,
      builder: (context, hovered) => AnimatedContainer(
        duration: Motion.of(context, Motion.fast),
        curve: Motion.curve,
        padding: const EdgeInsets.fromLTRB(12, 9, 14, 9),
        decoration: BoxDecoration(
          color: selected
              ? s.selected
              : (hovered ? s.hover : Colors.transparent),
          border: Border(bottom: BorderSide(color: s.border)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: AnimatedScale(
                duration: Motion.of(context, Motion.base),
                curve: Curves.easeOutBack,
                scale: t.unread ? 1 : 0,
                child: Dot(color: s.blue, size: 7),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          t.sender,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ui(
                            context,
                            weight: t.unread
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                      if (t.msgCount > 1)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text(
                            '${t.msgCount}',
                            style: mono(context, size: 11, color: s.fg3),
                          ),
                        ),
                      if (t.hasAttachment)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Icon(
                            CupertinoIcons.paperclip,
                            size: 12,
                            color: s.fg3,
                          ),
                        ),
                      if (t.starred)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Icon(
                            CupertinoIcons.star_fill,
                            size: 11,
                            color: s.yellow,
                          ),
                        ),
                      for (final l in t.labels.take(2))
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: TagChip(l.name),
                        ),
                      const SizedBox(width: 8),
                      if (t.snoozed) ...[
                        Icon(CupertinoIcons.clock, size: 11, color: s.yellow),
                        const SizedBox(width: 4),
                        Text(
                          snoozeLabel(t.snoozedUntil!, DateTime.now()),
                          style: mono(context, size: 11, color: s.yellow),
                        ),
                      ] else
                        Text(
                          formatWhen(t.lastDate),
                          style: mono(context, size: 11),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: t.subject,
                          style: ui(
                            context,
                            size: 12.5,
                            weight: t.unread
                                ? FontWeight.w500
                                : FontWeight.w400,
                          ),
                        ),
                        if (t.snippet.isNotEmpty)
                          TextSpan(
                            text: '  —  ${t.snippet}',
                            style: ui(context, size: 12.5, color: s.fg3),
                          ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Drafts kept on this device, newest first. A click reopens one in the composer.
class _DraftList extends ConsumerWidget {
  const _DraftList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    return ref
        .watch(draftsProvider)
        .when(
          skipLoadingOnReload: true,
          loading: () => const SizedBox.shrink(),
          error: (e, _) => Center(
            child: Text('$e', style: mono(context, color: s.red)),
          ),
          data: (drafts) => drafts.isEmpty
              ? const EmptyNote('No drafts')
              : ListView.builder(
                  itemCount: drafts.length,
                  itemBuilder: (context, i) => Appear(
                    key: ValueKey('draft-${drafts[i].localId}'),
                    delay: Duration(milliseconds: 18 * i.clamp(0, 10)),
                    child: DraftRow(
                      draft: drafts[i],
                      onTap: () =>
                          ref.read(composeProvider.notifier).open(drafts[i]),
                      onDelete: () async {
                        await ref
                            .read(repositoryProvider)
                            .deleteDraft(drafts[i].localId!);
                        ref.invalidate(draftsProvider);
                        ref
                            .read(noticeProvider.notifier)
                            .show('Draft discarded');
                      },
                    ),
                  ),
                ),
        );
  }
}

/// Drafts kept on this phone, in the phone list's scroll view.
class _PhoneDrafts extends ConsumerWidget {
  const _PhoneDrafts();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    Widget fill(Widget child) =>
        SliverFillRemaining(hasScrollBody: false, child: child);
    return ref
        .watch(draftsProvider)
        .when(
          skipLoadingOnReload: true,
          loading: () => fill(const DelayedSpinner()),
          error: (e, _) => fill(
            PhoneEmpty(
              title: 'Couldn’t open the drafts on this phone',
              detail: '$e',
              action: 'Try again',
              onAction: () => ref.invalidate(draftsProvider),
            ),
          ),
          data: (drafts) => drafts.isEmpty
              ? fill(const PhoneEmpty(title: 'No drafts on this phone'))
              : SliverList.builder(
                  itemCount: drafts.length,
                  itemBuilder: (context, i) {
                    final d = drafts[i];
                    return Column(
                      key: ValueKey('draft-${d.localId}'),
                      children: [
                        PhoneDraftRow(
                          draft: d,
                          onTap: () =>
                              ref.read(composeProvider.notifier).open(d),
                          onDelete: () async {
                            await ref
                                .read(repositoryProvider)
                                .deleteDraft(d.localId!);
                            ref.invalidate(draftsProvider);
                            ref
                                .read(noticeProvider.notifier)
                                .show('Draft deleted');
                          },
                        ),
                        Padding(
                          padding: const EdgeInsets.only(left: 28),
                          child: Divider(height: 1, color: s.border),
                        ),
                      ],
                    );
                  },
                ),
        );
  }
}

class DraftRow extends StatelessWidget {
  const DraftRow({
    super.key,
    required this.draft,
    required this.onTap,
    required this.onDelete,
  });
  final Draft draft;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final d = draft;
    final to = d.to.isEmpty ? 'no recipients' : d.to.join(', ');
    final body = d.text.trim().split('\n').first;
    return HoverRegion(
      onTap: onTap,
      builder: (context, hovered) => AnimatedContainer(
        duration: Motion.of(context, Motion.fast),
        curve: Motion.curve,
        padding: const EdgeInsets.fromLTRB(29, 9, 8, 9),
        decoration: BoxDecoration(
          color: hovered ? s.hover : Colors.transparent,
          border: Border(bottom: BorderSide(color: s.border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'draft',
                        style: mono(context, size: 11, color: s.red),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          to,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ui(
                            context,
                            color: d.to.isEmpty ? s.fg3 : s.fg,
                          ),
                        ),
                      ),
                      if (d.attachments.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Icon(
                            CupertinoIcons.paperclip,
                            size: 12,
                            color: s.fg3,
                          ),
                        ),
                      if (d.savedAt != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          formatWhen(d.savedAt!.toLocal()),
                          style: mono(context, size: 11),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: d.subject.isEmpty ? '(no subject)' : d.subject,
                          style: ui(
                            context,
                            size: 12.5,
                            color: d.subject.isEmpty ? s.fg3 : s.fg,
                          ),
                        ),
                        if (body.isNotEmpty)
                          TextSpan(
                            text: '  —  $body',
                            style: ui(context, size: 12.5, color: s.fg3),
                          ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            AnimatedOpacity(
              opacity: hovered || kTouch ? 1 : 0,
              duration: Motion.of(context, Motion.fast),
              child: IconBtn(
                icon: CupertinoIcons.trash,
                label: 'Discard draft',
                size: 13,
                onTap: onDelete,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The foot of the list: more of what is here, older mail of this folder from the
/// server, or the same search on the server.
class MoreFromServer extends ConsumerStatefulWidget {
  const MoreFromServer({
    super.key,
    required this.query,
    required this.shown,
    this.phone = false,
  });
  final String query;

  /// The last item of the phone list: taller, in reading type.
  final bool phone;

  /// How many conversations the list holds now.
  final int shown;

  static List<String> _tokens(String q) =>
      q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();

  /// Words, a sender or recipient, a subject or a date: something to look for.
  static bool searching(String query) => _tokens(query).any(
    (t) =>
        !t.startsWith('#') &&
        !RegExp(r'^(in|is|has|account|label):').hasMatch(t),
  );

  /// A folder as it is (optionally one account's): older mail of it can be fetched.
  static bool folderView(String query) {
    final t = _tokens(query).where((t) => !t.startsWith('account:')).toList();
    return t.isEmpty ||
        (t.length == 1 &&
            RegExp(r'^in:(inbox|sent|archive|all|spam|junk|trash)$')
                .hasMatch(t.first));
  }

  static bool offered(String query) => searching(query) || folderView(query);

  @override
  ConsumerState<MoreFromServer> createState() => _MoreFromServerState();
}

class _MoreFromServerState extends ConsumerState<MoreFromServer> {
  bool _busy = false;

  /// This list has everything the server has (per query; a new query starts over).
  bool _done = false;

  /// The list is a full page: there is more here before anything is asked of a server.
  bool get _moreHere => widget.shown >= ref.read(listLimitProvider);

  Future<void> _run() async {
    if (_busy || _done) return;
    if (_moreHere) {
      ref.read(listLimitProvider.notifier).grow();
      return;
    }
    final repo = ref.read(repositoryProvider);
    final notice = ref.read(noticeProvider.notifier);
    final limit = ref.read(listLimitProvider.notifier);
    final searching = MoreFromServer.searching(widget.query);
    setState(() => _busy = true);
    try {
      if (searching) {
        final n = await repo.searchServer(widget.query);
        notice.show(
          n == 0 ? 'Nothing more on the server' : 'Found $n more on the server',
        );
        if (n > 0) limit.grow(n);
        _done = true;
      } else {
        final r = await repo.loadOlder(widget.query);
        notice.show(
          r.fetched == 0
              ? 'No older mail on the server'
              : '${r.fetched} older ${r.fetched == 1 ? 'message' : 'messages'}',
        );
        // Room in the list for what came, so it shows.
        if (r.fetched > 0) limit.grow(r.fetched);
        _done = !r.more;
      }
    } catch (e) {
      notice.show(e is Problem ? e.title : '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    ref.watch(listLimitProvider);
    final searching = MoreFromServer.searching(widget.query);
    final label = _moreHere && !_busy
        ? 'Show more'
        : _busy
        ? (searching ? 'Searching the server…' : 'Loading older mail…')
        : _done
        ? (searching ? 'Searched the server' : 'All mail is here')
        : (searching ? 'Search on the server' : 'Load older mail');
    final phone = widget.phone;
    return Container(
      height: phone ? 52 : 32,
      decoration: phone
          ? null
          : BoxDecoration(
              border: Border(top: BorderSide(color: s.border)),
            ),
      child: HoverRegion(
        onTap: _busy || _done ? null : _run,
        builder: (context, hovered) => Container(
          color: hovered && !_done ? s.hover : null,
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_busy) ...[
                SizedBox(
                  width: phone ? 14 : 10,
                  height: phone ? 14 : 10,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: s.fg3,
                  ),
                ),
                const SizedBox(width: 8),
              ] else if (!_done) ...[
                Icon(
                  phone
                      ? (searching ? AppIcons.cloud : AppIcons.olderMail)
                      : (searching
                            ? CupertinoIcons.cloud
                            : CupertinoIcons.arrow_down_circle),
                  size: phone ? 16 : 12,
                  color: phone ? s.fg2 : s.fg3,
                ),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: phone
                    ? ui(context, size: 15, color: _done ? s.fg3 : s.fg2)
                    : mono(context, size: 11.5, color: _done ? s.fg3 : s.fg2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
