import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A pushed phone screen as each platform moves it: iOS slides with the edge swipe back,
/// Android uses its own transition and predictive back.
Route<T> phonePage<T>(WidgetBuilder builder, {bool modal = false}) =>
    defaultTargetPlatform == TargetPlatform.iOS
    ? CupertinoPageRoute<T>(builder: builder, fullscreenDialog: modal)
    : MaterialPageRoute<T>(builder: builder, fullscreenDialog: modal);

/// A screen that is a task of its own (compose, adding an account).
Route<T> phoneModal<T>(WidgetBuilder builder) =>
    phonePage(builder, modal: true);
