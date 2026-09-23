import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../state/providers.dart';
import '../../theme/app_icons.dart';
import '../../theme/motion.dart';
import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';
import '../accounts/problem_note.dart';
import '../accounts/sign_in_again.dart';
import '../palette/command_palette.dart';
import '../sidebar/sidebar_model.dart';

Future<T?> _sheet<T>(BuildContext context, WidgetBuilder builder) =>
    showModalBottomSheet<T>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: context.s.bg,
      builder: builder,
    );

/// A sheet's title: 17 semibold, with a quieter line after it.
class _SheetTitle extends StatelessWidget {
  const _SheetTitle(this.title, {this.detail});
  final String title;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: title,
              style: ui(context, size: 17, weight: FontWeight.w600),
            ),
            if (detail != null)
              TextSpan(
                text: '   $detail',
                style: ui(context, size: 13, color: s.fg2),
              ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// A 52 row: an icon, the name, a count or detail, a check on the current one.
class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.title,
    required this.onTap,
    this.icon,
    this.iconColor,
    this.detail,
    this.count,
    this.current = false,
  });
  final String title;
  final IconData? icon;
  final Color? iconColor;
  final String? detail;
  final int? count;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Semantics(
      selected: current,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          color: current ? s.selected : null,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 20, color: iconColor ?? s.fg2),
                const SizedBox(width: 16),
              ],
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui(context, size: 16),
                ),
              ),
              if (detail != null)
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text(
                    detail!,
                    style: mono(context, size: 13, color: s.fg2),
                  ),
                ),
              if (count != null && count! > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text(
                    '$count',
                    style: mono(context, size: 13, color: s.fg2),
                  ),
                ),
              if (current)
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Icon(AppIcons.check, size: 18, color: s.accentStrong),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
    child: Text(
      title,
      style: ui(
        context,
        size: 13,
        weight: FontWeight.w600,
        color: context.s.fg2,
      ),
    ),
  );
}

/// Mailboxes: the roles, then labels, then Add account and Settings. Picking one calls
/// [onPick] with its query (the account narrowing kept).
Future<void> showMailboxSheet(
  BuildContext context, {
  required void Function(String query) onPick,
  required VoidCallback onAddAccount,
  required VoidCallback onSettings,
}) => _sheet(
  context,
  (_) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.6,
    minChildSize: 0.3,
    maxChildSize: 0.92,
    snap: true,
    builder: (context, controller) => _MailboxSheet(
      controller: controller,
      onPick: onPick,
      onAddAccount: onAddAccount,
      onSettings: onSettings,
    ),
  ),
);

class _MailboxSheet extends ConsumerWidget {
  const _MailboxSheet({
    required this.controller,
    required this.onPick,
    required this.onAddAccount,
    required this.onSettings,
  });
  final ScrollController controller;
  final void Function(String query) onPick;
  final VoidCallback onAddAccount;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = ref.watch(foldersProvider).value ?? const <Folder>[];
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final labels = ref.watch(labelsProvider).value ?? const <Label>[];
    final drafts = ref.watch(draftsProvider).value?.length;
    final base = withoutFilter(
      ref.watch(queryProvider),
      ref.watch(listFilterProvider),
    );
    final scope = parseMailbox(base)?.scope;
    final account = accounts.where((a) => a.email == scope).firstOrNull;

    void pick(String q) {
      Navigator.of(context).pop();
      onPick(q);
    }

    void then(VoidCallback f) {
      Navigator.of(context).pop();
      f();
    }

    Widget row(
      String title,
      IconData icon,
      String query, {
      int? count,
      String? detail,
      Color? iconColor,
    }) => _SheetRow(
      title: title,
      icon: icon,
      iconColor: iconColor,
      count: count,
      detail: detail,
      current: query == base,
      onTap: () => pick(query),
    );

    final hasStarred = folders.any((f) => f.role == FolderRole.starred);
    final roles = <Widget>[
      for (final f in folders)
        if (f.role != FolderRole.other) ...[
          if (f.role == FolderRole.drafts)
            // Drafts live on this device, for every account.
            row('Drafts', AppIcons.drafts, 'in:drafts', count: drafts)
          else
            row(
              labelForRole(f.role),
              phoneIconForRole(f.role),
              mailboxQuery(f.role, scope),
              count: scope == null
                  ? f.unread
                  : f.role == FolderRole.inbox
                  ? account?.unread
                  : null,
            ),
          if (f.role == FolderRole.starred ||
              (f.role == FolderRole.inbox && !hasStarred))
            row(
              'Snoozed',
              AppIcons.snooze,
              mailboxQuery(null, scope, snoozed: true),
            ),
        ],
    ];
    return ListView(
      controller: controller,
      padding: EdgeInsets.zero,
      children: [
        _SheetTitle('Mailboxes', detail: scope),
        ...roles,
        if (labels.isNotEmpty) ...[
          const _Section('Labels'),
          for (final l in labels)
            row(
              l.name,
              AppIcons.label,
              mailboxQuery(null, scope, label: l.name),
              iconColor: l.color,
            ),
        ],
        const SizedBox(height: 8),
        Divider(height: 1, color: context.s.border),
        _SheetRow(
          title: 'Add account',
          icon: AppIcons.addAccount,
          onTap: () => then(onAddAccount),
        ),
        _SheetRow(
          title: 'Settings',
          icon: AppIcons.settings,
          onTap: () => then(onSettings),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// A picker ("Move to…", "Snooze until…") as a sheet: its choices under their groups.
/// A choice closes the sheet, then runs.
Future<void> showPickerSheet(BuildContext context, Picker p) =>
    _sheet(context, (_) => _PickerSheet(picker: p));

class _PickerSheet extends StatefulWidget {
  const _PickerSheet({required this.picker});
  final Picker picker;

  @override
  State<_PickerSheet> createState() => _PickerSheetState();
}

class _PickerSheetState extends State<_PickerSheet> {
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _choose(Command c) async {
    final wait = Motion.of(context, Motion.base);
    Navigator.of(context).pop();
    await Future<void>.delayed(wait);
    c.run();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final p = widget.picker;
    final f = _filter.text.trim().toLowerCase();
    final items = f.isEmpty
        ? p.items
        : p.items.where((c) => c.title.toLowerCase().contains(f)).toList();
    final rows = <Widget>[];
    String? group;
    for (final c in items) {
      if (c.group != group) {
        group = c.group;
        rows.add(_Section(c.group));
      }
      rows.add(
        _SheetRow(title: c.title, detail: c.detail, onTap: () => _choose(c)),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SheetTitle(p.hint.replaceAll('…', '').trim()),
        if (p.items.length > 12)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: QuietField(
              controller: _filter,
              hint: 'Filter',
              leading: Icon(AppIcons.search, size: 18, color: s.fg2),
              onChanged: (_) => setState(() {}),
            ),
          ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 8),
            children: rows.isEmpty
                ? [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Nothing matches',
                        style: ui(context, size: 15, color: s.fg2),
                      ),
                    ),
                  ]
                : rows,
          ),
        ),
      ],
    );
  }
}

/// Why accounts did not update, per account, with what fixes each.
Future<void> showSyncProblemsSheet(BuildContext context) =>
    _sheet(context, (_) => const _SyncProblemsSheet());

class _SyncProblemsSheet extends ConsumerWidget {
  const _SyncProblemsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final failing = [...accounts.where((a) => a.problem != null)];
    final lastError = ref.watch(syncStatusProvider).lastError;
    final repo = ref.read(repositoryProvider);
    final details = [
      for (final a in failing)
        '${a.email}: ${a.problem!.title}'
            '${a.problem!.detail.isEmpty ? '' : ' (${a.problem!.detail})'}',
      if (failing.isEmpty && lastError != null) lastError,
    ].join('\n');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SheetTitle('Sync problems'),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            children: [
              for (final a in failing) ...[
                Row(
                  children: [
                    Dot(color: a.color, size: 10),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        a.email,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ui(context, size: 16, weight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ProblemNote(a.problem!),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => a.needsPassword
                          ? repo.retryAccount(a.id)
                          : repo.sync(),
                      child: const Text('Try again'),
                    ),
                    if (a.needsPassword)
                      TextButton(
                        onPressed: () {
                          Navigator.of(context).pop();
                          if (a.signInProvider != null) {
                            signInAgain(context, ref, a);
                          } else {
                            openPasswordEntry(context, a);
                          }
                        },
                        child: Text(
                          a.signInProvider != null
                              ? 'Sign in'
                              : 'Enter password',
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              if (failing.isEmpty && lastError != null) ...[
                Text(lastError, style: ui(context, size: 15)),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: repo.sync,
                    child: const Text('Try again'),
                  ),
                ),
              ],
              if (failing.isEmpty && lastError == null)
                Text(
                  'Every account updated.',
                  style: ui(context, size: 15, color: s.fg2),
                ),
            ],
          ),
        ),
        if (details.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: details));
                  ref.read(noticeProvider.notifier).show('Copied');
                },
                child: const Text('Copy details'),
              ),
            ),
          ),
      ],
    );
  }
}
