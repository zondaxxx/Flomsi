import 'package:flutter/cupertino.dart';

import '../../data/models.dart';
import '../../theme/app_icons.dart';

/// One navigable row in the sidebar. Sections carry no query.
class SidebarEntry {
  const SidebarEntry({
    required this.label,
    this.query,
    this.icon,
    this.color,
    this.count = 0,
    this.section = false,
    this.warning,
  });
  final String label;

  /// Something needs the user (an account whose password was refused).
  final String? warning;
  final String? query;
  final IconData? icon;
  final Color? color;
  final int count;
  final bool section;
}

IconData iconForRole(FolderRole r) => switch (r) {
  FolderRole.inbox => CupertinoIcons.tray,
  FolderRole.starred => CupertinoIcons.star,
  FolderRole.drafts => CupertinoIcons.doc_text,
  FolderRole.sent => CupertinoIcons.paperplane,
  FolderRole.archive => CupertinoIcons.archivebox,
  FolderRole.junk => CupertinoIcons.xmark_shield,
  FolderRole.trash => CupertinoIcons.trash,
  _ => CupertinoIcons.folder,
};

/// The role's icon on a phone, in the platform's own glyphs.
IconData phoneIconForRole(FolderRole r) => switch (r) {
  FolderRole.inbox => AppIcons.inbox,
  FolderRole.starred => AppIcons.star,
  FolderRole.drafts => AppIcons.drafts,
  FolderRole.sent => AppIcons.sent,
  FolderRole.archive => AppIcons.archive,
  FolderRole.junk => AppIcons.junk,
  FolderRole.trash => AppIcons.delete,
  FolderRole.all => AppIcons.mail,
  FolderRole.other => AppIcons.folder,
};

String queryForRole(FolderRole r) => switch (r) {
  FolderRole.inbox => '',
  FolderRole.starred => 'is:starred',
  _ => 'in:${r.name}',
};

String labelForRole(FolderRole r) => switch (r) {
  FolderRole.inbox => 'Inbox',
  FolderRole.starred => 'Starred',
  FolderRole.drafts => 'Drafts',
  FolderRole.sent => 'Sent',
  FolderRole.archive => 'Archive',
  FolderRole.junk => 'Junk',
  FolderRole.trash => 'Trash',
  FolderRole.all => 'All Mail',
  FolderRole.other => 'Folder',
};

List<SidebarEntry> buildSidebar({
  required List<Folder> folders,
  required List<Account> accounts,
  required List<Label> labels,
}) => [
  const SidebarEntry(label: 'Mailboxes', section: true),
  for (final f in folders) ...[
    SidebarEntry(
      label: labelForRole(f.role),
      query: queryForRole(f.role),
      icon: iconForRole(f.role),
      count: f.unread,
    ),
    // Snoozed sits right after Starred (after Inbox when there is no Starred).
    if (f.role == FolderRole.starred ||
        (f.role == FolderRole.inbox &&
            !folders.any((x) => x.role == FolderRole.starred)))
      const SidebarEntry(
        label: 'Snoozed',
        query: 'in:snoozed',
        icon: CupertinoIcons.clock,
      ),
  ],
  if (accounts.isNotEmpty) const SidebarEntry(label: 'Accounts', section: true),
  for (final a in accounts)
    SidebarEntry(
      label: a.email,
      query: 'account:${a.email}',
      icon: CupertinoIcons.circle_fill,
      color: a.color,
      count: a.unread,
      warning: a.needsPassword ? 'Needs password: ${a.problem!.title}' : null,
    ),
  if (labels.isNotEmpty) const SidebarEntry(label: 'Labels', section: true),
  for (final l in labels)
    SidebarEntry(
      label: l.name,
      query: '#${l.name}',
      icon: CupertinoIcons.tag,
      color: l.color,
    ),
];

/// A mailbox: its role (Inbox when none), the account it is scoped to (all when null),
/// or a label, or the snoozed list.
typedef Mailbox = ({
  FolderRole? role,
  String? scope,
  String? label,
  bool snoozed,
});

/// The query that shows [role] on [scope] (an address), a label, or the snoozed list. A
/// scoped Inbox is `account:<email>` alone: `in:inbox` would also show snoozed mail.
String mailboxQuery(
  FolderRole? role,
  String? scope, {
  String? label,
  bool snoozed = false,
}) {
  final base = label != null
      ? '#$label'
      : snoozed
      ? 'in:snoozed'
      : queryForRole(role ?? FolderRole.inbox);
  if (scope == null) return base;
  return base.isEmpty ? 'account:$scope' : 'account:$scope $base';
}

/// The mailbox a query shows, or null for a search (words, senders, filters).
Mailbox? parseMailbox(String q) {
  final tokens = q.trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
  String? scope;
  final rest = <String>[];
  for (final t in tokens) {
    if (t.startsWith('account:') && scope == null) {
      scope = t.substring(8);
    } else {
      rest.add(t);
    }
  }
  if (rest.isEmpty) {
    return (role: FolderRole.inbox, scope: scope, label: null, snoozed: false);
  }
  if (rest.length > 1) return null;
  final t = rest.single;
  if (t == 'is:starred') {
    return (
      role: FolderRole.starred,
      scope: scope,
      label: null,
      snoozed: false,
    );
  }
  if (t == 'in:snoozed') {
    return (role: null, scope: scope, label: null, snoozed: true);
  }
  if (t.startsWith('#')) {
    return (role: null, scope: scope, label: t.substring(1), snoozed: false);
  }
  if (t.startsWith('in:')) {
    final role = FolderRole.values
        .where((r) => r.name == t.substring(3))
        .firstOrNull;
    if (role != null) {
      return (role: role, scope: scope, label: null, snoozed: false);
    }
  }
  return null;
}

/// The mailbox under the list's filter: [query] without the `is:unread` or `is:starred`
/// the filter added to its end.
String withoutFilter(String query, String filter) {
  final token = switch (filter) {
    'unread' => 'is:unread',
    'starred' => 'is:starred',
    _ => null,
  };
  final parts = query.trim().split(RegExp(r'\s+'))
    ..removeWhere((t) => t.isEmpty);
  if (token != null && parts.isNotEmpty && parts.last == token) {
    parts.removeLast();
  }
  return parts.join(' ');
}

/// The mailbox's name for a title: Inbox, Sent, a label… (the account shown apart).
String mailboxTitle(String q) {
  final m = parseMailbox(q);
  if (m == null) return 'Search';
  if (m.snoozed) return 'Snoozed';
  if (m.label != null) return m.label!;
  return labelForRole(m.role ?? FolderRole.inbox);
}

/// Title for the toolbar / list header, from the active query.
String titleForQuery(String q) {
  final t = q.trim();
  if (t.isEmpty) return 'Inbox';
  if (t == 'is:starred') return 'Starred';
  if (t == 'in:snoozed') return 'Snoozed';
  if (t == 'is:unread') return 'Unread';
  if (t.startsWith('in:') && !t.contains(' ')) {
    final role = FolderRole.values
        .where((r) => r.name == t.substring(3))
        .firstOrNull;
    return role != null ? labelForRole(role) : t.substring(3);
  }
  if (t.startsWith('#') && !t.contains(' ')) return t.substring(1);
  if (t.startsWith('account:') && !t.contains(' ')) return t.substring(8);
  return 'Search';
}
