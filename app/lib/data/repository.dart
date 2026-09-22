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

  /// Sanitized HTML for one message; with [remoteImages] the http(s) images stay in.
  Future<String?> messageHtml(int messageId, {bool remoteImages = false});

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

  /// Local path of an attachment (fetched from the server when not cached), to hand to
  /// "open with" or a share sheet.
  Future<String> openAttachment(Attachment a);

  /// Save an attachment into [dir] under a free name; returns the path written.
  Future<String> saveAttachment(Attachment a, String dir);

  /// Name, size and MIME type of a local file, ready to go into a draft.
  Future<DraftAttachment> describeFile(String path);

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
