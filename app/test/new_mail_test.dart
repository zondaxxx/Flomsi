import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/data/mock_repository.dart';
import 'package:mail_app/data/models.dart';
import 'package:mail_app/features/notify/new_mail.dart';

/// Unread inbox conversations as a test sets them, and sync events on demand.
class _Inbox extends MockRepository {
  List<Thread> unread = [];
  final _sync = StreamController<RepoEvent>.broadcast();
  String? asked;

  @override
  Stream<RepoEvent> get events => _sync.stream;

  @override
  Future<List<Thread>> threads(String query, {int limit = 100}) async {
    asked = query;
    return unread;
  }

  Future<void> synced(int fetched) => _emit(SyncFinished(fetched: fetched));

  Future<void> imported() => _emit(const MailImported());

  Future<void> _emit(RepoEvent e) async {
    _sync.add(e);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }
}

Thread _t(int id, String subject, DateTime at) => Thread(
  id: id,
  accountId: 1,
  subject: subject,
  participants: const ['Anna Sokolova'],
  lastDate: at,
  msgCount: 1,
  unreadCount: 1,
  snippet: '',
);

void main() {
  test(
    'only mail that arrived after start is announced, and only once',
    () async {
      final repo = _Inbox();
      final t0 = DateTime.now().add(const Duration(minutes: 1));
      repo.unread = [_t(1, 'Old unread', t0)];
      final told = <List<String>>[];
      var front = false;
      final w = NewMailWatcher(
        repo: repo,
        announce: (fresh) async =>
            told.add(fresh.map((t) => t.subject).toList()),
        inFront: () => front,
      );
      await w.start();
      expect(repo.asked, 'in:inbox is:unread');

      // A sync that fetched nothing is not looked at.
      repo.unread = [_t(2, 'Design review', t0), ...repo.unread];
      await repo.synced(0);
      expect(told, isEmpty);

      await repo.synced(1);
      expect(told, [
        ['Design review'],
      ]);
      await repo.synced(1);
      expect(told.length, 1, reason: 'already announced');

      // A newer message in a known conversation counts again.
      repo.unread = [_t(1, 'Old unread', t0.add(const Duration(hours: 1)))];
      await repo.synced(1);
      expect(told.last, ['Old unread']);

      // In front, the list shows it: no notification, and it is not saved for later.
      front = true;
      repo.unread = [_t(3, 'Lunch?', t0), ...repo.unread];
      await repo.synced(1);
      front = false;
      await repo.synced(1);
      expect(told.length, 2);

      // Months-old mail that came in some other way is not news, even unknown.
      repo.unread = [
        _t(4, 'Old newsletter', t0.subtract(const Duration(days: 90))),
        ...repo.unread,
      ];
      await repo.synced(1);
      expect(told.length, 2);
      // Older mail loaded on request is taken in without a word.
      repo.unread = [_t(5, 'Recent but loaded', t0), ...repo.unread];
      await repo.imported();
      await repo.synced(1);
      expect(told.length, 2);
      await w.stop();
    },
  );
}
