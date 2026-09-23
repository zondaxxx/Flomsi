import 'package:flutter/material.dart';

/// System-like colors for accounts and labels (Apple's semantic palette values).
abstract final class Swatch {
  static const green = Color(0xFF34C759);
  static const blue = Color(0xFF0A84FF);
  static const orange = Color(0xFFFF9F0A);
  static const pink = Color(0xFFFF375F);
  static const purple = Color(0xFFBF5AF2);
  static const teal = Color(0xFF5AC8FA);
  static const yellow = Color(0xFFFFD60A);
  static const gray = Color(0xFF8E8E93);
}

enum FolderRole {
  inbox,
  sent,
  drafts,
  trash,
  junk,
  archive,
  all,
  starred,
  other,
}

class Account {
  const Account({
    required this.id,
    required this.email,
    required this.kind,
    required this.color,
    this.unread = 0,
    this.displayName = '',
    this.signature = '',
    this.server = '',
    this.imap,
    this.smtp,
    this.localBridge = false,
    this.problem,
  });
  final int id;
  final String email;
  final String kind; // gmail, imap, outlook, jmap
  final Color color;
  final int unread;

  /// Name shown in From.
  final String displayName;
  final String signature;

  /// `imap.example.com:993`
  final String server;
  final ServerSetup? imap;
  final ServerSetup? smtp;

  /// A bridge on this computer (Proton) whose own certificate is accepted.
  final bool localBridge;

  /// Why this account stopped syncing; an [Problem.isAuth] problem waits for a new
  /// password instead of retrying (retries can lock the mailbox).
  final Problem? problem;
  bool get needsPassword => problem?.isAuth ?? false;

  String get short =>
      kind == 'imap' ? email.split('@').last.split('.').first : kind;
}

/// One mail server as a person types it in.
class ServerSetup {
  const ServerSetup({
    required this.host,
    required this.port,
    this.startTls = false,
  });
  final String host;
  final int port;

  /// Plain connection upgraded with STARTTLS (143, 587, Proton Bridge) instead of TLS
  /// from the first byte (993, 465).
  final bool startTls;
  String get security => startTls ? 'starttls' : 'tls';

  @override
  String toString() => '$host:$port${startTls ? ' STARTTLS' : ''}';
}

/// Everything the add-account form collects, except the password.
class AccountSetup {
  const AccountSetup({
    required this.email,
    required this.imap,
    required this.smtp,
    this.displayName = '',
    this.localBridge = false,
  });
  final String email;
  final String displayName;
  final ServerSetup imap;
  final ServerSetup smtp;
  final bool localBridge;
}

/// A failure put in words. [kind] is `auth`, `network`, `tls`, `server` or `local`;
/// [stage] says which server answered (`imap`, `smtp`) when that matters.
class Problem implements Exception {
  const Problem({
    required this.kind,
    required this.title,
    this.hint,
    this.detail = '',
    this.stage,
  });
  final String kind;
  final String title;
  final String? hint;

  /// The server's own words, for people who want them.
  final String detail;
  final String? stage;
  bool get isAuth => kind == 'auth';

  @override
  String toString() => hint == null ? title : '$title. $hint';
}

class Folder {
  const Folder({
    required this.id,
    required this.accountId,
    required this.name,
    required this.role,
    this.unread = 0,
  });
  final int id;
  final int accountId;
  final String name;
  final FolderRole role;
  final int unread;
}

class Label {
  const Label(this.name, this.color);
  final String name;
  final Color color;
}

class Thread {
  const Thread({
    required this.id,
    required this.accountId,
    required this.subject,
    required this.participants,
    required this.lastDate,
    required this.msgCount,
    required this.unreadCount,
    required this.snippet,
    this.hasAttachment = false,
    this.starred = false,
    this.labels = const [],
    this.snoozedUntil,
  });
  final int id;
  final int accountId;
  final String subject;
  final List<String> participants;
  final DateTime lastDate;
  final int msgCount;
  final int unreadCount;
  final String snippet;
  final bool hasAttachment;
  final bool starred;
  final List<Label> labels;

  /// When a snooze ends (future: hidden from the inbox) or ended (past).
  final DateTime? snoozedUntil;

  bool get unread => unreadCount > 0;
  bool get snoozed =>
      snoozedUntil != null && snoozedUntil!.isAfter(DateTime.now());
  String get sender => participants.isEmpty ? '' : participants.first;

  Thread copyWith({int? unreadCount, bool? starred}) => Thread(
    id: id,
    accountId: accountId,
    subject: subject,
    participants: participants,
    lastDate: lastDate,
    msgCount: msgCount,
    unreadCount: unreadCount ?? this.unreadCount,
    snippet: snippet,
    hasAttachment: hasAttachment,
    starred: starred ?? this.starred,
    labels: labels,
    snoozedUntil: snoozedUntil,
  );
}

/// A received attachment: part [idx] of message [messageId].
class Attachment {
  const Attachment({
    required this.messageId,
    required this.idx,
    required this.name,
    required this.mime,
    required this.size,
  });
  final int messageId;
  final int idx;
  final String name;
  final String mime;

  /// Bytes.
  final int size;

  String get sizeLabel => formatBytes(size);
}

/// A file going out with a draft: a local [path], or part [idx] of stored message
/// [messageId] (forwarding keeps the original attachments this way).
class DraftAttachment {
  const DraftAttachment({
    required this.name,
    required this.mime,
    required this.size,
    this.path,
    this.messageId,
    this.idx,
  });
  final String name;
  final String mime;
  final int size;
  final String? path;
  final int? messageId;
  final int? idx;

  bool get fromMessage => path == null;
}

/// 900 B, 84 KB, 12.4 MB.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
  final mb = bytes / (1024 * 1024);
  return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
}

class Message {
  const Message({
    required this.id,
    required this.threadId,
    required this.fromName,
    required this.fromAddr,
    required this.to,
    required this.date,
    required this.text,
    this.html,
    this.blockedImages = 0,
    this.isMine = false,
    this.attachments = const [],
  });
  final int id;
  final int threadId;
  final String fromName;
  final String fromAddr;
  final List<String> to;
  final DateTime date;
  final String text;

  /// Sanitized HTML body, when the message has one.
  final String? html;
  final int blockedImages;
  final bool isMine;
  final List<Attachment> attachments;

  String get initials {
    final parts = fromName.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) {
      return fromAddr.substring(0, 1).toUpperCase();
    }
    return parts.take(2).map((p) => p.substring(0, 1).toUpperCase()).join();
  }
}

/// A message being written. Addresses are `Name <addr>` or bare `addr`.
class Draft {
  const Draft({
    required this.accountId,
    required this.from,
    this.to = const [],
    this.cc = const [],
    this.bcc = const [],
    this.subject = '',
    this.text = '',
    this.inReplyTo,
    this.references = const [],
    this.kind = DraftKind.fresh,
    this.attachments = const [],
    this.localId,
    this.savedAt,
  });
  final int accountId;
  final String from;
  final List<String> to;
  final List<String> cc;
  final List<String> bcc;
  final String subject;
  final String text;
  final String? inReplyTo;
  final List<String> references;
  final DraftKind kind;
  final List<DraftAttachment> attachments;

  /// Id of the copy kept on this device, once autosave has stored it.
  final int? localId;
  final DateTime? savedAt;

  Draft copyWith({
    List<String>? to,
    List<String>? cc,
    List<String>? bcc,
    String? subject,
    String? text,
    DraftKind? kind,
    List<DraftAttachment>? attachments,
    int? localId,
    DateTime? savedAt,
  }) => Draft(
    accountId: accountId,
    from: from,
    to: to ?? this.to,
    cc: cc ?? this.cc,
    bcc: bcc ?? this.bcc,
    subject: subject ?? this.subject,
    text: text ?? this.text,
    inReplyTo: inReplyTo,
    references: references,
    kind: kind ?? this.kind,
    attachments: attachments ?? this.attachments,
    localId: localId ?? this.localId,
    savedAt: savedAt ?? this.savedAt,
  );
}

enum DraftKind { fresh, reply, forward }

/// Something changed in the cache; UI should refetch.
sealed class RepoEvent {
  const RepoEvent();
}

class SyncStarted extends RepoEvent {
  const SyncStarted();
}

class SyncFinished extends RepoEvent {
  const SyncFinished({required this.fetched, this.errors = const []});
  final int fetched;
  final List<String> errors;
}

class ThreadsChanged extends RepoEvent {
  const ThreadsChanged();
}

String formatWhen(DateTime d, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final local = d.toLocal();
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(local.year, local.month, local.day);
  final diff = today.difference(day).inDays;
  String two(int v) => v.toString().padLeft(2, '0');
  if (diff == 0) return '${two(local.hour)}:${two(local.minute)}';
  if (diff == 1) return 'yesterday';
  if (diff < 7) {
    return const [
      'mon',
      'tue',
      'wed',
      'thu',
      'fri',
      'sat',
      'sun',
    ][local.weekday - 1];
  }
  const months = [
    'jan',
    'feb',
    'mar',
    'apr',
    'may',
    'jun',
    'jul',
    'aug',
    'sep',
    'oct',
    'nov',
    'dec',
  ];
  return '${local.day} ${months[local.month - 1]}';
}
