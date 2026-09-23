import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Icons as each phone draws them: SF-style Cupertino glyphs on Apple devices, Material
/// ones on Android (people read their own platform's icons fastest).
abstract final class AppIcons {
  static bool get _android => defaultTargetPlatform == TargetPlatform.android;

  static IconData _pick(IconData apple, IconData android) =>
      _android ? android : apple;

  static IconData get mailboxes =>
      _pick(CupertinoIcons.tray_2, Icons.all_inbox_outlined);
  static IconData get search => _pick(CupertinoIcons.search, Icons.search);
  static IconData get unread =>
      _pick(CupertinoIcons.envelope_badge, Icons.mark_email_unread_outlined);
  static IconData get unreadOn =>
      _pick(CupertinoIcons.envelope_badge_fill, Icons.mark_email_unread);
  static IconData get markRead =>
      _pick(CupertinoIcons.envelope_open, Icons.mark_email_read_outlined);
  static IconData get compose =>
      _pick(CupertinoIcons.square_pencil, Icons.edit_outlined);
  static IconData get more =>
      _pick(CupertinoIcons.ellipsis_circle, Icons.more_vert);
  static IconData get moreBar =>
      _pick(CupertinoIcons.ellipsis_circle, Icons.more_horiz);
  static IconData get back =>
      _pick(CupertinoIcons.chevron_back, Icons.arrow_back);
  static IconData get archive =>
      _pick(CupertinoIcons.archivebox, Icons.archive_outlined);
  static IconData get delete =>
      _pick(CupertinoIcons.trash, Icons.delete_outline);
  static IconData get reply =>
      _pick(CupertinoIcons.arrowshape_turn_up_left, Icons.reply);
  static IconData get replyAll =>
      _pick(CupertinoIcons.arrowshape_turn_up_left_2, Icons.reply_all);
  static IconData get forward =>
      _pick(CupertinoIcons.arrowshape_turn_up_right, Icons.forward);
  static IconData get move =>
      _pick(CupertinoIcons.folder, Icons.drive_file_move_outline);
  static IconData get snooze => _pick(CupertinoIcons.clock, Icons.snooze);
  static IconData get star => _pick(CupertinoIcons.star, Icons.star_border);
  static IconData get starOn => _pick(CupertinoIcons.star_fill, Icons.star);
  static IconData get images =>
      _pick(CupertinoIcons.photo, Icons.image_outlined);
  static IconData get settings =>
      _pick(CupertinoIcons.gear, Icons.settings_outlined);
  static IconData get addAccount =>
      _pick(CupertinoIcons.person_badge_plus, Icons.person_add_alt_outlined);
  static IconData get sync =>
      _pick(CupertinoIcons.arrow_clockwise, Icons.refresh);
  static IconData get attach =>
      _pick(CupertinoIcons.paperclip, Icons.attach_file);
  static IconData get close => _pick(CupertinoIcons.xmark, Icons.close);
  static IconData get clear =>
      _pick(CupertinoIcons.xmark_circle_fill, Icons.cancel);
  static IconData get reveal =>
      _pick(CupertinoIcons.eye, Icons.visibility_outlined);
  static IconData get hide =>
      _pick(CupertinoIcons.eye_slash, Icons.visibility_off_outlined);
  static IconData get external =>
      _pick(CupertinoIcons.arrow_up_right_square, Icons.open_in_new);
  static IconData get lock => _pick(CupertinoIcons.lock, Icons.lock_outline);
  static IconData get error =>
      _pick(CupertinoIcons.exclamationmark_circle, Icons.error_outline);
  static IconData get expand =>
      _pick(CupertinoIcons.chevron_down, Icons.expand_more);
  static IconData get chevron =>
      _pick(CupertinoIcons.chevron_forward, Icons.chevron_right);
  static IconData get check => _pick(CupertinoIcons.checkmark, Icons.check);
  static IconData get mail =>
      _pick(CupertinoIcons.envelope, Icons.mail_outline);
  static IconData get olderMail => _pick(
    CupertinoIcons.arrow_down_circle,
    Icons.expand_circle_down_outlined,
  );
  static IconData get cloud =>
      _pick(CupertinoIcons.cloud, Icons.cloud_outlined);
  static IconData get label => _pick(CupertinoIcons.tag, Icons.label_outline);

  // Folder roles.
  static IconData get inbox => _pick(CupertinoIcons.tray, Icons.inbox_outlined);
  static IconData get drafts =>
      _pick(CupertinoIcons.doc_text, Icons.drafts_outlined);
  static IconData get sent =>
      _pick(CupertinoIcons.paperplane, Icons.send_outlined);
  static IconData get junk =>
      _pick(CupertinoIcons.xmark_shield, Icons.report_outlined);
  static IconData get folder =>
      _pick(CupertinoIcons.folder, Icons.folder_outlined);
}
