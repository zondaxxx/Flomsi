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

  /// How many messages left the inbox (0: it was not there).
  Future<int> archive(int threadId);

  /// Folders of one account, for "Move to…".
  Future<List<Folder>> accountFolders(int accountId);

  /// Move the thread to any folder of its account (local first, replayed on sync).
  Future<void> moveThread(int threadId, int folderId);

  /// Hide the thread from the inbox until [until] (kept on this device).
  Future<void> snooze(int threadId, DateTime until);
  Future<void> unsnooze(int threadId);

  /// How many messages went to Trash (0: nothing to delete).
  Future<int> trash(int threadId);
  Future<void> markRead(int threadId, bool read);
  Future<void> star(int threadId, bool on);

  Future<void> sync();
  Stream<RepoEvent> get events;

  Future<Draft> newDraft();
  Future<Draft> replyDraft(int threadId, {bool all = false});
  Future<Draft> forwardDraft(int threadId);

  /// SMTP send. Throws when nothing went out. Returns a warning when the mail went out but
  /// a later step (the copy in Sent) failed, else null.
  Future<String?> send(Draft draft);

  /// Keep [draft] on this device: inserted, or updated in place when it has a
  /// [Draft.localId]. Returns the local id.
  Future<int> saveDraft(Draft draft);

  /// Drafts kept on this device, most recently edited first.
  Future<List<Draft>> drafts();

  Future<void> deleteDraft(int localId);

  /// Local path of an attachment (fetched from the server when not cached), to hand to
  /// "open with" or a share sheet.
  Future<String> openAttachment(Attachment a);

  /// Save an attachment into [dir] under a free name; returns the path written.
  Future<String> saveAttachment(Attachment a, String dir);

  /// Name, size and MIME type of a local file, ready to go into a draft.
  Future<DraftAttachment> describeFile(String path);

  /// Sign in to IMAP, then SMTP, without storing anything. Throws a [Problem] whose
  /// stage says which server refused.
  Future<void> checkAccount(AccountSetup setup, String password);

  /// Register an account; the password goes to the OS keychain, never to the database.
  /// Throws a [Problem]; adding an address twice is refused.
  Future<Account> addAccount(AccountSetup setup, String password);

  /// The SMTP server usually paired with [imapHost], or null.
  ServerSetup? suggestSmtp(String imapHost);

  /// Check [password] against the account's IMAP server and store it; the account
  /// syncs again. Throws a [Problem] and keeps the old password when it is refused.
  Future<void> updatePassword(int accountId, String password);

  /// Try an account that stopped on a sign-in problem again, with the stored password
  /// (after turning IMAP on at the provider, say).
  Future<void> retryAccount(int accountId);

  Future<void> removeAccount(int id);

  /// Name shown in From, and the signature new drafts start with.
  Future<void> updateAccount(
    int id, {
    required String displayName,
    required String signature,
  });

  /// App preferences kept with the mail database (`theme`, `keymap`).
  Future<String?> setting(String key);
  Future<void> setSetting(String key, String value);
}
