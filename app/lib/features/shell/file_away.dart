import 'package:flutter/widgets.dart';

import '../../data/models.dart';
import '../../data/repository.dart';
import '../../state/providers.dart';
import '../../theme/surfaces.dart';

/// Archive (or, without [archive], delete) a thread. When the account has nowhere to put
/// it, say why: a missing Archive or Trash folder can be created on the server there and
/// then and the thread filed into it; on Gmail the folder only needs showing to IMAP.
/// Without a [context] to ask in (the screen is gone), the reason becomes a notice.
/// Returns how many messages moved, or null when nothing was done.
Future<int?> fileAway(
  BuildContext? context,
  MailRepository repo,
  NoticeController notice,
  int threadId, {
  required bool archive,
}) async {
  Future<int> run() => archive ? repo.archive(threadId) : repo.trash(threadId);
  try {
    return await run();
  } on MissingFolder catch (m) {
    if (context == null || !context.mounted) {
      notice.show(m.message, error: true);
      return null;
    }
    final folder = m.role == 'trash' ? 'Trash' : 'Archive';
    if (m.gmail) {
      final hidden = m.role == 'trash' ? 'Trash' : 'All Mail';
      await confirmDialog(
        context,
        title: '$hidden is hidden from mail apps',
        body:
            'Gmail keeps $hidden out of IMAP, so Flomsi has nowhere to put this '
            'conversation. In Gmail on the web open Settings, then Labels, and turn on '
            '“Show in IMAP” for $hidden. The next sync picks it up.',
        action: 'OK',
        cancel: false,
      );
      return null;
    }
    final create = await confirmDialog(
      context,
      title: 'No $folder folder',
      body:
          'This account’s server has no $folder folder. Flomsi can create “$folder” '
          'there and put the conversation in it.',
      action: 'Create $folder',
    );
    if (!create) return null;
    try {
      await repo.createRoleFolder(m.accountId, m.role);
      return await run();
    } catch (e) {
      notice.show('Could not create $folder: $e', error: true);
      return null;
    }
  } catch (e) {
    notice.show(e is Problem ? e.title : e.toString(), error: true);
    return null;
  }
}
