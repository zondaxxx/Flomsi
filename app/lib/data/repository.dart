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

  /// How many messages left the inbox (0: it was not there). Throws [MissingFolder]
  /// when the account has nowhere to archive to.
  Future<int> archive(int threadId);

  /// Create the `archive` or `trash` folder the account's server is missing; returns the
  /// folder's name.
  Future<String> createRoleFolder(int accountId, String role);

  /// Older mail for the list [query] shows, from every account it covers: how many
  /// messages arrived and whether the servers have older ones still.
  Future<({int fetched, bool more})> loadOlder(String query);

  /// Look on the servers for what [query] names, beyond the cached mail; the matches then
  /// show in [threads]. Returns how many arrived.
  Future<int> searchServer(String query);

  /// Folders of one account, for "Move to…".
  Future<List<Folder>> accountFolders(int accountId);

  /// Move the thread to any folder of its account (local first, replayed on sync).
  /// Returns how many messages moved: 0 when it is all there already.
  Future<int> moveThread(int threadId, int folderId);

  /// Hide the thread from the inbox until [until] (kept on this device).
  Future<void> snooze(int threadId, DateTime until);
  Future<void> unsnooze(int threadId);

  /// How many messages went to Trash (0: nothing to delete). Throws [MissingFolder].
  Future<int> trash(int threadId);
  Future<void> markRead(int threadId, bool read);
  Future<void> star(int threadId, bool on);

  Future<void> sync();
  Stream<RepoEvent> get events;

  /// A new message from [accountId] (the first account when null).
  Future<Draft> newDraft({int? accountId});
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

  /// The name an attachment is saved under: invisible characters that could disguise its
  /// extension removed, Windows device names renamed.
  String displayFileName(String name);

  /// The extension (lower case) of an attachment that can run code or open a browser when
  /// opened, judged by its real name; null for ordinary files.
  String? riskyExtension(String name);

  /// Sign in to IMAP, then SMTP, without storing anything. Throws a [Problem] whose
  /// stage says which server refused.
  Future<void> checkAccount(AccountSetup setup, String password);

  /// Providers this build can sign in with on their own page: `google`, `microsoft`.
  List<String> signInProviders();

  /// Sign in on the provider's page (the browser on a computer, the system sign-in sheet
  /// on a phone) and add the account it names, or, with [loginHint] naming an account
  /// already here, sign that one in again. [onReturned] runs when the page is done and
  /// the account is being connected. Throws a [Problem]; kind `cancelled` when the person
  /// closed the page.
  Future<Account> signIn(
    String provider, {
    String? loginHint,
    void Function()? onReturned,
  });

  /// Stop a sign-in on a computer while its browser page is still open.
  void cancelSignIn();

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
