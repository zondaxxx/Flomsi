import 'package:flutter/cupertino.dart';

import '../../data/models.dart';

/// One navigable row in the sidebar. Sections carry no query.
class SidebarEntry {
  const SidebarEntry({
    required this.label,
    this.query,
    this.icon,
    this.color,
    this.count = 0,
    this.section = false,
  });
  final String label;
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
  for (final f in folders)
    SidebarEntry(
      label: labelForRole(f.role),
      query: queryForRole(f.role),
      icon: iconForRole(f.role),
      count: f.unread,
    ),
  if (accounts.isNotEmpty) const SidebarEntry(label: 'Accounts', section: true),
  for (final a in accounts)
    SidebarEntry(
      label: a.email,
      query: 'account:${a.email}',
      icon: CupertinoIcons.circle_fill,
      color: a.color,
      count: a.unread,
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

/// Title for the toolbar / list header, from the active query.
String titleForQuery(String q) {
  final t = q.trim();
  if (t.isEmpty) return 'Inbox';
  if (t == 'is:starred') return 'Starred';
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
