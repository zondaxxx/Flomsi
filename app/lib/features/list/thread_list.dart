import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../state/providers.dart';
import '../../theme/motion.dart';
import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';

/// Filter row + animated thread rows. The search field itself lives in the top bar on desktop.
class ThreadListBody extends ConsumerStatefulWidget {
  const ThreadListBody({super.key, this.onOpen, this.showSearch = false});
  final void Function(int threadId)? onOpen;

  /// Phones have no top-bar field, so the list carries its own.
  final bool showSearch;

  @override
  ConsumerState<ThreadListBody> createState() => ThreadListBodyState();
}

class ThreadListBodyState extends ConsumerState<ThreadListBody> {
  final searchController = TextEditingController();
  final searchFocus = FocusNode(debugLabel: 'search');
  final _listKey = GlobalKey<AnimatedListState>();
  final _items = <Thread>[];
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
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
    super.dispose();
  }

  void focusSearch() => searchFocus.requestFocus();

  void onSearchChanged(String v) =>
      ref.read(queryProvider.notifier).set(_compose(v));

  String _compose(String base) {
    final q = base.trim();
    return switch (_filter) {
      'unread' => '$q is:unread'.trim(),
      'starred' => '$q is:starred'.trim(),
      _ => q,
    };
  }

  /// Diff the provider's list into the AnimatedList: removals collapse, insertions rise in.
  void _sync(List<Thread> next) {
    final d = Motion.of(context, Motion.base);
    for (var i = _items.length - 1; i >= 0; i--) {
      if (!next.any((t) => t.id == _items[i].id)) {
        final removed = _items.removeAt(i);
        _listKey.currentState?.removeItem(
          i,
          (context, anim) => _Transition(
            anim: anim,
            child: ThreadRow(thread: removed, selected: false),
          ),
          duration: d,
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
        _listKey.currentState?.removeItem(
          existing,
          (context, anim) => const SizedBox.shrink(),
          duration: Duration.zero,
        );
      }
      _items.insert(j, next[j]);
      _listKey.currentState?.insertItem(j, duration: d);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final threads = ref.watch(threadsProvider);
    final selected = ref.watch(selectedThreadIdProvider);
    final syncError = ref.watch(
      syncStatusProvider.select((st) => st.lastError),
    );
    final list = threads.asData?.value;
    if (list != null) _sync(list);
    final unread = list?.where((t) => t.unread).length ?? 0;
    final starred = list?.where((t) => t.starred).length ?? 0;

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
              _FilterButton(
                label: 'All',
                count: list?.length ?? 0,
                active: _filter == 'all',
                onTap: () => _setFilter('all'),
              ),
              _FilterButton(
                label: 'Unread',
                count: unread,
                active: _filter == 'unread',
                onTap: () => _setFilter('unread'),
              ),
              _FilterButton(
                label: 'Starred',
                count: starred,
                active: _filter == 'starred',
                onTap: () => _setFilter('starred'),
              ),
              const Spacer(),
              IconBtn(
                icon: CupertinoIcons.line_horizontal_3_decrease,
                label: 'Sort: newest',
                onTap: () {},
              ),
            ],
          ),
        ),
        if (syncError != null)
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
          child: threads.when(
            loading: () => const SizedBox.shrink(),
            error: (e, _) => Center(
              child: Text('$e', style: mono(context, color: s.red)),
            ),
            data: (_) => _items.isEmpty
                ? const EmptyNote('No mail')
                : AnimatedList(
                    key: _listKey,
                    initialItemCount: _items.length,
                    itemBuilder: (context, i, anim) {
                      if (i >= _items.length) return const SizedBox.shrink();
                      final t = _items[i];
                      return _Transition(
                        anim: anim,
                        child: ThreadRow(
                          thread: t,
                          selected: t.id == selected,
                          onTap: () {
                            ref
                                .read(selectedThreadIdProvider.notifier)
                                .select(t.id);
                            widget.onOpen?.call(t.id);
                          },
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  void _setFilter(String f) {
    setState(() => _filter = f);
    ref.read(queryProvider.notifier).set(_compose(searchController.text));
  }
}

class _Transition extends StatelessWidget {
  const _Transition({required this.anim, required this.child});
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
  final int count;
  final bool active;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final s = context.s;
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
            const SizedBox(width: 5),
            Text(
              '$count',
              style: mono(context, size: 11, color: active ? s.fg2 : s.fg3),
            ),
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
