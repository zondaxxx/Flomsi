import 'models.dart';

/// UI-facing data source. The Rust core implements this over the bridge;
/// MockRepository implements it in memory for design work and tests.
abstract class MailRepository {
  Future<List<Account>> accounts();
  Future<List<Folder>> folders();
  Future<List<Label>> labels();
  Future<List<Thread>> threads(String query, {int limit = 100});
  Future<Thread?> thread(int id);
  Future<List<Message>> messages(int threadId);

  Future<void> archive(int threadId);
  Future<void> trash(int threadId);
  Future<void> markRead(int threadId, bool read);
  Future<void> star(int threadId, bool on);

  Future<void> sync();
  Stream<RepoEvent> get events;

  Future<Draft> newDraft();
  Future<Draft> replyDraft(int threadId, {bool all = false});
  Future<Draft> forwardDraft(int threadId);

  /// SMTP send. Throws with the server's reason.
  Future<void> send(Draft draft);

  /// Connect and authenticate once without storing anything. Throws with the server's reason.
  Future<void> testImapLogin({
    required String email,
    required String host,
    required int port,
    required String password,
  });

  /// Register an IMAP account. The secret goes to the OS keychain, never to the database.
  Future<Account> addImapAccount({
    required String email,
    required String host,
    required int port,
    required String password,
    String displayName = '',
  });
  Future<void> removeAccount(int id);
}
