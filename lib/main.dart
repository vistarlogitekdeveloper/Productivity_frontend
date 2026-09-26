import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_mode_provider.dart';
import 'core/theme/vistar_theme_sync.dart';
import 'core/routes/app_router.dart';
import 'core/widgets/vistar/vistar_loaders.dart';
import 'data/repositories/local_storage_repository.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Await shared preferences to prevent provider lookup errors
  final sharedPrefs = await SharedPreferences.getInstance();

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          AsyncValue.data(sharedPrefs),
        ),
      ],
      child: const ProductionMonitoringApp(),
    ),
  );
}

class ProductionMonitoringApp extends ConsumerWidget {
  const ProductionMonitoringApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    final themeMode = ref.watch(themeModeProvider);
    // Light unless the user explicitly chose dark.
    final brightness = themeMode == ThemeMode.dark
        ? Brightness.dark
        : Brightness.light;

    return VistarThemeSync(
      brightness: brightness,
      child: MaterialApp.router(
        title: 'Vistar Pulse',
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: brightness == Brightness.dark
            ? ThemeMode.dark
            : ThemeMode.light,
        // Token-driven widgets switch instantly; animating only the
        // Material half would show a 200ms mix of both palettes.
        themeAnimationDuration: Duration.zero,
        routerConfig: router,
        debugShowCheckedModeBanner: false,
        builder: (context, child) => VistarSplashGate(
          child: VistarRouteLoaderOverlay(
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
