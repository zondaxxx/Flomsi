import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Light / dark / follow the system. Nothing else: the platform draws the chrome.
class AppearanceController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => ThemeMode.dark;
  void set(ThemeMode m) => state = m;
  void cycle() => state = switch (state) {
    ThemeMode.system => ThemeMode.dark,
    ThemeMode.dark => ThemeMode.light,
    ThemeMode.light => ThemeMode.system,
  };
}

final appearanceProvider = NotifierProvider<AppearanceController, ThemeMode>(
  AppearanceController.new,
);
