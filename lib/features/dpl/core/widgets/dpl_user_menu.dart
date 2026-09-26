import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/theme_mode_provider.dart';
import '../../../../core/theme/vistar_palette.dart';
import '../../../../core/widgets/vistar/vistar_brand.dart';
import '../../../auth/auth_provider.dart';
import '../../../auth/change_password_dialog.dart';
import '../dpl_organization_provider.dart';

/// Shared profile button + popup used in every DPL AppBar.
///
/// Renders the user's ribbon avatar as the trigger. Tapping opens a
/// polished card with a tinted header (avatar, name, role pill) followed
/// by the action rows (Light / Dark mode, Change Password, Logout).
///
/// Drop into any AppBar via `actions: [const DplUserMenu()]`.
class DplUserMenu extends ConsumerWidget {
  const DplUserMenu({super.key});

  // Brand colors — resolved against the active light / dark palette.
  static Color get _primary => VistarPalette.primary;
  static Color get _primaryDark => VistarPalette.primaryInk;
  static Color get _primaryTint => VistarPalette.primaryTint;
  static Color get _danger => VistarPalette.bad;
  static Color get _textPrimary => VistarPalette.txt;
  static Color get _textMuted => VistarPalette.txt3;
  static Color get _divider => VistarPalette.line;
  static Color get _surface =>
      VistarPalette.isDark ? VistarPalette.surface2 : VistarPalette.surface;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).asData?.value;
    final name = (user?.name.trim().isNotEmpty ?? false)
        ? user!.name
        : (user?.username ?? 'User');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Tooltip(
        message: name,
        child: InkWell(
          customBorder: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(38 * 0.3),
          ),
          onTap: () => _open(context, ref),
          child: VistarAvatar(name: name, size: 38),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final user = ref.read(authControllerProvider).asData?.value;
    final name = (user?.name.trim().isNotEmpty ?? false)
        ? user!.name
        : (user?.username ?? 'User');
    final roleLabel = AppConstants.roleLabel(user?.role ?? '');
    final email = user?.username ?? '';
    final orgLabel =
        ref.read(dplActiveOrganizationProvider)?.displayLabel ?? '';
    final isDark = ref.read(themeModeProvider) == ThemeMode.dark;

    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final button = context.findRenderObject() as RenderBox;
    final topRight = button.localToGlobal(
      button.size.topRight(Offset.zero),
      ancestor: overlay,
    );

    final action = await showMenu<_Action>(
      context: context,
      position: RelativeRect.fromLTRB(
        topRight.dx - 280,
        topRight.dy + 8,
        16,
        0,
      ),
      elevation: 12,
      color: _surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: _divider),
      ),
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 280),
      items: [
        PopupMenuItem<_Action>(
          enabled: false,
          padding: EdgeInsets.zero,
          height: orgLabel.isEmpty ? 96 : 112,
          child: _Header(
            name: name,
            role: roleLabel,
            email: email,
            org: orgLabel,
          ),
        ),
        PopupMenuItem<_Action>(
          enabled: false,
          height: 1,
          padding: EdgeInsets.zero,
          child: Divider(height: 1, color: _divider),
        ),
        PopupMenuItem<_Action>(
          value: _Action.toggleTheme,
          padding: EdgeInsets.zero,
          child: _MenuRow(
            icon: isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
            label: isDark ? 'Light mode' : 'Dark mode',
            tint: _primaryTint,
            iconColor: _primaryDark,
            trailing: _ModePill(isDark: isDark),
          ),
        ),
        PopupMenuItem<_Action>(
          enabled: false,
          height: 1,
          padding: EdgeInsets.zero,
          child: Divider(height: 1, color: _divider),
        ),
        PopupMenuItem<_Action>(
          value: _Action.changePassword,
          padding: EdgeInsets.zero,
          child: _MenuRow(
            icon: Icons.lock_reset_outlined,
            label: 'Change Password',
            tint: _primaryTint,
            iconColor: _primaryDark,
          ),
        ),
        PopupMenuItem<_Action>(
          enabled: false,
          height: 1,
          padding: EdgeInsets.zero,
          child: Divider(height: 1, color: _divider),
        ),
        PopupMenuItem<_Action>(
          value: _Action.logout,
          padding: EdgeInsets.zero,
          child: _MenuRow(
            icon: Icons.logout_rounded,
            label: 'Logout',
            tint: VistarPalette.badBg,
            iconColor: _danger,
            labelColor: _danger,
          ),
        ),
      ],
    );

    if (action == null || !context.mounted) return;

    switch (action) {
      case _Action.toggleTheme:
        ref.read(themeModeProvider.notifier).toggleThemeMode();
        break;
      case _Action.changePassword:
        await showChangePasswordDialog(context, ref);
        break;
      case _Action.logout:
        final confirmed = await _confirmLogout(context);
        if (confirmed != true || !context.mounted) return;
        await ref.read(authControllerProvider.notifier).logout();
        break;
    }
  }

  Future<bool?> _confirmLogout(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: const Text('Log out?'),
        content: const Text(
          'You will need to sign in again to continue.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: _danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
  }
}

enum _Action { toggleTheme, changePassword, logout }

class _Header extends StatelessWidget {
  final String name;
  final String role;
  final String email;
  final String org;

  const _Header({
    required this.name,
    required this.role,
    required this.email,
    this.org = '',
  });

  @override
  Widget build(BuildContext context) {
    final dark = VistarPalette.isDark;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? const [Color(0xFF221433), Color(0xFF1A1230)]
              : const [Color(0xFFF7ECFC), Color(0xFFEED7F7)],
        ),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
        ),
      ),
      child: Row(
        children: [
          VistarAvatar(name: name, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    color: DplUserMenu._textPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    height: 1.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: dark
                        ? VistarPalette.primaryTint
                        : Colors.white.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: DplUserMenu._primary.withValues(alpha: 0.25),
                    ),
                  ),
                  child: Text(
                    role.isEmpty ? 'Member' : role,
                    style: TextStyle(
                      color: DplUserMenu._primaryDark,
                      fontWeight: FontWeight.w700,
                      fontSize: 10.5,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
                if (org.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        Icons.business_rounded,
                        size: 11,
                        color: DplUserMenu._textMuted,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          org,
                          style: TextStyle(
                            color: DplUserMenu._textMuted,
                            fontWeight: FontWeight.w700,
                            fontSize: 11,
                            height: 1.1,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Small "LIGHT" / "DARK" state tag on the theme row.
class _ModePill extends StatelessWidget {
  final bool isDark;
  const _ModePill({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: VistarPalette.surface3,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: VistarPalette.line),
      ),
      child: Text(
        isDark ? 'DARK' : 'LIGHT',
        style: TextStyle(
          color: VistarPalette.txt3,
          fontWeight: FontWeight.w800,
          fontSize: 9.5,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color tint;
  final Color iconColor;
  final Color? labelColor;
  final Widget? trailing;

  const _MenuRow({
    required this.icon,
    required this.label,
    required this.tint,
    required this.iconColor,
    this.labelColor,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tint,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 17, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: labelColor ?? DplUserMenu._textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 13.5,
              ),
            ),
          ),
          if (trailing != null) ...[trailing!, const SizedBox(width: 6)],
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: DplUserMenu._textMuted,
          ),
        ],
      ),
    );
  }
}
