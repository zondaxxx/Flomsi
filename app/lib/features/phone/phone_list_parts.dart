import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../state/providers.dart';
import '../../theme/app_icons.dart';
import '../../theme/tokens.dart';
import '../accounts/sign_in_again.dart';
import '../list/thread_list.dart';
import '../sidebar/sidebar_model.dart';
import 'sheets.dart';

/// A spinner that shows only when loading takes long enough to notice (300 ms).
class DelayedSpinner extends StatefulWidget {
  const DelayedSpinner({super.key});

  @override
  State<DelayedSpinner> createState() => _DelayedSpinnerState();
}

class _DelayedSpinnerState extends State<DelayedSpinner> {
  bool _show = false;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _show = true);
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Center(
    child: _show
        ? const CircularProgressIndicator.adaptive(strokeWidth: 2)
        : const SizedBox.shrink(),
  );
}

/// What an empty or failed list says: a title, a line under it, one action.
class PhoneEmpty extends StatelessWidget {
  const PhoneEmpty({
    super.key,
    required this.title,
    this.detail,
    this.action,
    this.onAction,
    this.busy = false,
    this.below,
  });
  final String title;
  final String? detail;
  final String? action;
  final VoidCallback? onAction;
  final bool busy;

  /// A button of its own under the words (Load older mail, Search on the server).
  final Widget? below;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy) ...[
              const CircularProgressIndicator.adaptive(strokeWidth: 2),
              const SizedBox(height: 16),
            ],
            Text(
              title,
              textAlign: TextAlign.center,
              style: ui(
                context,
                size: busy ? 15 : 17,
                weight: busy ? FontWeight.w400 : FontWeight.w500,
                color: busy ? s.fg2 : s.fg,
              ),
            ),
            if (detail != null) ...[
              const SizedBox(height: 6),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: ui(context, size: 14, color: s.fg2),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: 12),
              TextButton(onPressed: onAction, child: Text(action!)),
            ],
            if (below != null) ...[const SizedBox(height: 16), below!],
          ],
        ),
      ),
    );
  }
}

String _hhmm(DateTime d) {
  final l = d.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

/// An empty mailbox, said for what it is.
class PhoneEmptyMailbox extends ConsumerWidget {
  const PhoneEmptyMailbox({
    super.key,
    required this.query,
    required this.filter,
  });
  final String query;
  final String filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncStatusProvider);
    if (sync.syncing && sync.lastOk == null) {
      final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
      final from = accounts.length == 1 ? _providerName(accounts.single) : null;
      return PhoneEmpty(
        title: from == null
            ? 'Getting your mail…'
            : 'Getting your mail from $from…',
        busy: true,
      );
    }
    if (filter == 'unread') {
      return PhoneEmpty(
        title: 'No unread mail',
        action: 'Show all mail',
        onAction: () => ref.read(listFilterProvider.notifier).set('all'),
      );
    }
    final m = parseMailbox(query);
    if (m == null) {
      return PhoneEmpty(
        title: 'No matches on this phone',
        below: ServerSearchButton(key: ValueKey('server-$query'), query: query),
      );
    }
    if (m.snoozed) return const PhoneEmpty(title: 'Nothing snoozed');
    if (m.label != null) {
      return PhoneEmpty(title: 'Nothing labelled ${m.label}');
    }
    final title = mailboxTitle(query);
    final updated = sync.lastOk;
    return switch (m.role) {
      FolderRole.starred => const PhoneEmpty(title: 'No starred mail'),
      FolderRole.inbox || null => PhoneEmpty(
        title: 'No mail in Inbox',
        detail: updated == null
            ? 'Pull down to check for mail'
            : 'Updated ${_hhmm(updated)} · pull down to check again',
      ),
      FolderRole.drafts => const PhoneEmpty(title: 'No drafts on this phone'),
      _ => PhoneEmpty(
        title: 'No mail in $title',
        below: MoreFromServer.offered(query)
            ? SizedBox(
                width: 240,
                child: MoreFromServer(
                  key: ValueKey('more-$query'),
                  query: query,
                  shown: 0,
                  phone: true,
                ),
              )
            : null,
      ),
    };
  }
}

/// An account the server stopped letting in, with the way back in.
class PhoneSignInBanner extends ConsumerWidget {
  const PhoneSignInBanner({super.key, required this.account});
  final Account account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final a = account;
    final oauth = a.signInProvider != null;
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(
        color: s.red.withValues(alpha: 0.06),
        border: Border(bottom: BorderSide(color: s.border)),
      ),
      child: Row(
        children: [
          Icon(AppIcons.lock, size: 18, color: s.red),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  oauth
                      ? 'Sign in to ${a.email} again'
                      : '${a.email}: password refused',
                  style: ui(context, size: 15, weight: FontWeight.w500),
                ),
                if (a.problem != null)
                  Text(
                    a.problem!.title,
                    style: ui(context, size: 13, color: s.fg2),
                  ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => oauth
                ? signInAgain(context, ref, a)
                : openPasswordEntry(context, a),
            child: Text(oauth ? 'Sign in' : 'Enter password'),
          ),
        ],
      ),
    );
  }
}

/// A sync that failed for another reason than the password.
class PhoneSyncBanner extends ConsumerWidget {
  const PhoneSyncBanner({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    return InkWell(
      onTap: () => showSyncProblemsSheet(context),
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: s.border)),
        ),
        child: Row(
          children: [
            Icon(AppIcons.error, size: 18, color: s.red),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ui(context, size: 14),
              ),
            ),
            TextButton(
              onPressed: () => ref.read(repositoryProvider).sync(),
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

String? _providerName(Account a) => switch (a.kind) {
  'gmail' => 'Gmail',
  'outlook' => 'Outlook',
  'icloud' => 'iCloud',
  _ => a.email.contains('@') ? a.email.split('@').last : null,
};

/// What search looks through, with examples to start from.
class PhoneSearchHint extends StatelessWidget {
  const PhoneSearchHint({super.key, required this.onExample});
  final void Function(String example) onExample;

  static const examples = [
    'from:anna',
    'has:attachment',
    'before:2026-09',
    '#work',
  ];

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Search senders, subjects and text of the mail on this phone.',
              style: ui(context, size: 15, color: s.fg2, height: 1.4),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in examples)
                  ActionChip(
                    label: Text(
                      e,
                      style: mono(context, size: 13, color: s.fg2),
                    ),
                    onPressed: () => onExample('$e '),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// No matches here: the same search on the server.
class ServerSearchButton extends ConsumerStatefulWidget {
  const ServerSearchButton({super.key, required this.query});
  final String query;

  @override
  ConsumerState<ServerSearchButton> createState() => _ServerSearchButtonState();
}

class _ServerSearchButtonState extends ConsumerState<ServerSearchButton> {
  bool _busy = false;
  bool _done = false;

  Future<void> _run() async {
    final repo = ref.read(repositoryProvider);
    final notice = ref.read(noticeProvider.notifier);
    final limit = ref.read(listLimitProvider.notifier);
    setState(() => _busy = true);
    try {
      final n = await repo.searchServer(widget.query);
      notice.show(
        n == 0 ? 'Nothing on the server either' : 'Found $n on the server',
      );
      if (n > 0) limit.grow(n);
      _done = true;
    } catch (e) {
      notice.show(e is Problem ? e.title : '$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => FilledButton(
    onPressed: _busy || _done ? null : _run,
    style: FilledButton.styleFrom(minimumSize: const Size(0, Touch.target)),
    child: Text(
      _busy
          ? 'Searching the server…'
          : _done
          ? 'Searched the server'
          : 'Search on the server',
    ),
  );
}
