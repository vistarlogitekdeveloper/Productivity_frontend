import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/app_constants.dart';
import '../../data/repositories/local_storage_repository.dart';

final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(
  ThemeModeController.new,
);

class ThemeModeController extends Notifier<ThemeMode> {
  SharedPreferences? get _prefs =>
      ref.watch(sharedPreferencesProvider).asData?.value;

  @override
  ThemeMode build() {
    final mode = _prefs?.getString(AppConstants.themeModeKey);
    return _modeFromString(mode);
  }

  void toggleThemeMode() {
    setThemeMode(state == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark);
  }

  /// Light is the default; only an explicit choice of dark is persisted as
  /// dark. [ThemeMode.system] is stored (and treated) as light so the app
  /// never changes appearance behind the user's back.
  void setThemeMode(ThemeMode mode) {
    final next = mode == ThemeMode.dark ? ThemeMode.dark : ThemeMode.light;
    if (next == state) return;
    state = next;
    _prefs?.setString(AppConstants.themeModeKey, _modeToString(next));
  }

  static ThemeMode _modeFromString(String? value) {
    switch (value) {
      case 'dark':
        return ThemeMode.dark;
      case 'light':
        return ThemeMode.light;
      default:
        return ThemeMode.light;
    }
  }

  static String _modeToString(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.light:
        return 'light';
      case ThemeMode.system:
        return 'light';
    }
  }
}
