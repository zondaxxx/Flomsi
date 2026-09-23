import 'package:flutter/material.dart';

/// The app's navigator and messenger, for work that outlives the screen that started it
/// (a filing committed after its thread page closed, a notice after a pop).
final rootNavigatorKey = GlobalKey<NavigatorState>();
final messengerKey = GlobalKey<ScaffoldMessengerState>();
