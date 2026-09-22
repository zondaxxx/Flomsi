import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

/// Light / dark / follow the system. Nothing else: the platform draws the chrome.
/// The choice is stored (`theme` setting) and restored at start.
class AppearanceController extends Notifier<ThemeMode> {
  bool _chosen = false;

  @override
  ThemeMode build() {
    Future(() async {
      try {
        final saved = await ref.read(repositoryProvider).setting('theme');
        final mode = ThemeMode.values.asNameMap()[saved];
        if (mode != null && !_chosen) state = mode;
      } catch (_) {
        // No database yet: keep the default.
      }
    });
    return ThemeMode.dark;
  }

  void set(ThemeMode m) {
    _chosen = true;
    state = m;
    ref.read(repositoryProvider).setSetting('theme', m.name).ignore();
  }

  void cycle() => set(switch (state) {
    ThemeMode.system => ThemeMode.dark,
    ThemeMode.dark => ThemeMode.light,
    ThemeMode.light => ThemeMode.system,
  });
}

final appearanceProvider = NotifierProvider<AppearanceController, ThemeMode>(
  AppearanceController.new,
);
