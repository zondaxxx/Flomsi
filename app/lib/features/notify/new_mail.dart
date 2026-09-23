import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../data/models.dart';
import '../../data/repository.dart';

/// Notices mail that arrived since it last looked: after every sync that fetched
/// something, the inbox's unread conversations are compared with the ones already known.
/// A conversation counts again when a newer message arrives in it. What was unread when
/// the watcher started is not announced.
class NewMailWatcher {
  NewMailWatcher({
    required this.repo,
    required this.announce,
    required this.inFront,
  });

  final MailRepository repo;

  /// Called with the new conversations, newest first, when Flomsi is not in front.
  final Future<void> Function(List<Thread> fresh) announce;

  /// True while the user is looking at Flomsi: then the list itself shows the mail.
  final bool Function() inFront;

  final Set<String> _known = {};
  StreamSubscription<RepoEvent>? _sub;

  /// The newest mail seen so far. Mail much older than that is old mail that came in some
  /// other way (Load older, a server search), not news.
  DateTime _newest = DateTime.now();

  /// Mail may be dated a little before the newest seen (clocks, slow delivery).
  static const _slack = Duration(minutes: 30);

  static String _key(Thread t) =>
      '${t.id}:${t.lastDate.millisecondsSinceEpoch}';

  Future<void> start() async {
    await _look(tell: false);
    _sub = repo.events.listen((e) {
      if (e is SyncFinished && e.fetched > 0) unawaited(_look(tell: true));
      // Older mail on request: take it in without a word.
      if (e is MailImported) unawaited(_look(tell: false));
    });
  }

  Future<void> _look({required bool tell}) async {
    final List<Thread> unread;
    try {
      unread = await repo.threads('in:inbox is:unread', limit: 50);
    } catch (_) {
      return;
    }
    final since = _newest.subtract(_slack);
    final fresh = [
      for (final t in unread)
        if (!_known.contains(_key(t)) && t.lastDate.isAfter(since)) t,
    ];
    _known.addAll(unread.map(_key));
    for (final t in unread) {
      if (t.lastDate.isAfter(_newest)) _newest = t.lastDate;
    }
    if (tell && fresh.isNotEmpty && !inFront()) await announce(fresh);
  }

  Future<void> stop() async => _sub?.cancel();
}

/// System notifications for new mail: one per conversation, three at most, then a count.
/// A tap opens the conversation.
class MailNotifications {
  MailNotifications._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  /// The summary has its own id; each conversation keeps one, so a newer message replaces
  /// its notification instead of piling up (and a restart does not overwrite others).
  static const _summaryId = 0;
  static int _idOf(Thread t) => 1 + (t.id & 0x3fffffff);

  static bool get supported =>
      Platform.isMacOS ||
      Platform.isIOS ||
      Platform.isAndroid ||
      Platform.isWindows;

  /// Set up once; [onOpen] gets the thread id of a tapped notification.
  static Future<void> init({
    required void Function(int threadId) onOpen,
  }) async {
    if (!supported || _ready) return;
    // Asked later ([askOnce]): not over the start screen, only once there is mail.
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: darwin,
          macOS: darwin,
          windows: WindowsInitializationSettings(
            appName: 'Flomsi',
            appUserModelId: 'Zonda.Flomsi.Mail',
            guid: '5b1f8f0e-6a0c-4f7e-9d3b-2c8e4a1d7f60',
          ),
        ),
        onDidReceiveNotificationResponse: (r) {
          final id = int.tryParse(r.payload ?? '');
          if (id != null) onOpen(id);
        },
      );
      // Flomsi was started by a tap on one of its notifications.
      final launch = await _plugin.getNotificationAppLaunchDetails();
      final id = int.tryParse(launch?.notificationResponse?.payload ?? '');
      if ((launch?.didNotificationLaunchApp ?? false) && id != null) onOpen(id);
      _ready = true;
    } catch (e) {
      debugPrint('notifications unavailable: $e');
    }
  }

  static bool _asked = false;

  /// Ask to show notifications, once per run (the system itself asks only once).
  static Future<void> askOnce() async {
    if (!_ready || _asked) return;
    _asked = true;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, sound: true);
      await _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, sound: true);
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    } catch (e) {
      debugPrint('notification permission: $e');
    }
  }

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'new_mail',
      'New mail',
      channelDescription: 'A message arrived in the inbox',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.email,
      groupKey: 'dev.zonda.flomsi.mail',
    ),
    iOS: DarwinNotificationDetails(threadIdentifier: 'mail'),
    macOS: DarwinNotificationDetails(threadIdentifier: 'mail'),
  );

  static Future<void> announce(List<Thread> fresh) async {
    if (!_ready) return;
    if (fresh.length > 3) {
      await _plugin.show(
        id: _summaryId,
        title: '${fresh.length} new messages',
        body: fresh.take(4).map((t) => '${t.sender}: ${t.subject}').join('\n'),
        notificationDetails: _details,
        payload: '${fresh.first.id}',
      );
      return;
    }
    for (final t in fresh) {
      await _plugin.show(
        id: _idOf(t),
        title: t.sender.isEmpty ? 'New mail' : t.sender,
        body: t.subject.isEmpty ? t.snippet : t.subject,
        notificationDetails: _details,
        payload: '${t.id}',
      );
    }
  }
}
