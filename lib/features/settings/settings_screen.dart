import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme_mode_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = ref.watch(themeModeProvider) == ThemeMode.dark;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const ListTile(
            leading: Icon(Icons.person),
            title: Text('Profile'),
            subtitle: Text('Manage your account'),
          ),
          const Divider(),
          SwitchListTile(
            value: isDark,
            onChanged: (dark) => ref
                .read(themeModeProvider.notifier)
                .setThemeMode(dark ? ThemeMode.dark : ThemeMode.light),
            title: const Text('Dark Mode'),
            secondary: Icon(
              isDark ? Icons.dark_mode : Icons.dark_mode_outlined,
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.sync),
            title: const Text('Force Sync Data'),
            subtitle: const Text('Sync offline entries to server'),
            onTap: () {
              // trigger sync logic
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Syncing data...')),
              );
            },
          ),
        ],
      ),
    );
  }
}
