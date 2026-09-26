import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/theme_mode_provider.dart';
import '../../core/widgets/vistar/vistar_ambient.dart';
import '../auth/auth_provider.dart';
import 'data/vistar_app_catalog.dart';
import 'design/workspace_theme.dart';
import 'models/vistar_app.dart';
import 'services/vistar_sso_handoff.dart';
import 'services/workspace_credentials.dart';
import 'widgets/vistar_swoosh.dart';
import 'workspace_account.dart';

/// Vistar Workspace — the app launcher.
///
/// One page listing every app in the Vistar family. Tapping a tile opens
/// that app in a new tab with an SSO hand-off appended (see
/// [VistarSsoHandoff]) so the user lands inside instead of on another
/// login form.
///
/// Everything on this page is derived from [vistarAppCatalogProvider]:
/// the grid, the category chips, the counts and the search index. Adding
/// an app never touches this file.
class WorkspaceScreen extends ConsumerStatefulWidget {
  const WorkspaceScreen({super.key});

  @override
  ConsumerState<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends ConsumerState<WorkspaceScreen> {
  final _searchController = TextEditingController();

  String _query = '';

  /// `null` means "All".
  String? _category;

  /// The app whose hand-off overlay is currently showing, if any.
  VistarApp? _launching;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _open(VistarApp app) async {
    if (!app.enabled || _launching != null) return;

    final user = ref.read(authControllerProvider).value;
    final email = user?.username ?? '';

    // A browser refresh keeps the session (prefs) but drops the password
    // (memory only). Recover it for the locally-known portal account so
    // one-click sign-in survives F5 — which is the whole point.
    var credentials = ref.read(workspaceCredentialsProvider);
    if (credentials == null && email.isNotEmpty) {
      if (ref.read(workspaceCredentialsProvider.notifier).restoreIfKnown(email)) {
        credentials = ref.read(workspaceCredentialsProvider);
      }
    }

    final identity = VistarSsoIdentity(
      email: email,
      name: (user?.name.isNotEmpty ?? false) ? user!.name : email,
      role: user?.role ?? '',
      password: credentials?.password,
    );

    setState(() => _launching = app);

    // Launch first, feedback second. On web the browser only honours a
    // new tab opened synchronously inside the click gesture — awaiting
    // anything before `open()` gets the pop-up blocked.
    bool opened;
    try {
      opened = await ref.read(vistarSsoHandoffProvider).open(app, identity);
    } catch (_) {
      opened = false;
    }
    if (!mounted) return;

    if (!opened) {
      setState(() => _launching = null);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            // Tinted dark surface rather than a flat red bar — a solid
            // `bad` fill leaves the body text at poor contrast.
            backgroundColor: VistarPalette.surface3,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(VistarPalette.rSm),
              side: BorderSide(
                color: VistarPalette.bad.withValues(alpha: 0.45),
              ),
            ),
            content: Row(
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  size: 18,
                  color: VistarPalette.bad,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Could not open ${app.name}. Allow pop-ups for this site, then try again.',
                    style: VistarType.body(
                      size: 13.5,
                      color: VistarPalette.txt,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      return;
    }

    // Hold the overlay briefly so the hand-off reads as a deliberate
    // sign-in rather than a tile that flickered.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;
    setState(() => _launching = null);
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => Theme(
        data: vistarWorkspaceTheme(),
        child: AlertDialog(
          backgroundColor: VistarPalette.surface2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(VistarPalette.r),
            side: BorderSide(color: VistarPalette.line2),
          ),
          title: Text(
            'Sign out of Vistar Workspace?',
            style: VistarType.display(size: 18),
          ),
          content: Text(
            'Apps you already opened in other tabs stay open.',
            style: VistarType.body(size: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(
                'Cancel',
                style: VistarType.body(
                  size: 14,
                  weight: FontWeight.w700,
                  color: VistarPalette.txt2,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(
                'Sign out',
                style: VistarType.body(
                  size: 14,
                  weight: FontWeight.w700,
                  color: VistarPalette.pink,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;
    await ref.read(authControllerProvider.notifier).logout();
  }

  @override
  Widget build(BuildContext context) {
    final apps = ref.watch(vistarAppCatalogProvider);
    final categories = ref.watch(vistarAppCategoriesProvider);
    final user = ref.watch(authControllerProvider).value;

    // Whether tapping a tile can sign the user in rather than just land
    // them on a login form. True when the password is still in memory, or
    // when it is the portal account whose password `_open` can recover.
    // Kept as a pure read — recovery itself happens on tap, never during
    // a build.
    final signedInAs = (user?.username ?? '').trim().toLowerCase();
    final canAutoLogin =
        ref.watch(workspaceCredentialsProvider)?.isUsable == true ||
        signedInAs == VistarWorkspaceAccount.username;

    final visible = apps
        .where(
          (app) =>
              (_category == null || app.category == _category) &&
              app.matches(_query),
        )
        .toList(growable: false);

    return Theme(
      data: vistarWorkspaceTheme(),
      child: Scaffold(
        backgroundColor: VistarPalette.bg,
        body: Stack(
          children: [
            const Positioned.fill(child: _AmbientBackground()),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isWide = constraints.maxWidth >= 820;
                  final pad = isWide ? 32.0 : 18.0;

                  return CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: _ContentWidth(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(pad, 18, pad, 0),
                            child: _TopBar(
                              displayName: user?.name ?? '',
                              email: user?.username ?? '',
                              role: AppConstants.roleLabel(user?.role ?? ''),
                              compact: !isWide,
                              onSignOut: _signOut,
                              isDark:
                                  ref.watch(themeModeProvider) == ThemeMode.dark,
                              onToggleTheme: () => ref
                                  .read(themeModeProvider.notifier)
                                  .toggleThemeMode(),
                            ),
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: _ContentWidth(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(pad, 34, pad, 0),
                            child: _Hero(
                              firstName: _firstName(user?.name ?? ''),
                              appCount: apps.length,
                              suiteCount: categories.length,
                              isWide: isWide,
                              canAutoLogin: canAutoLogin,
                            ),
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: _ContentWidth(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(pad, 28, pad, 0),
                            child: _Filters(
                              controller: _searchController,
                              categories: categories,
                              selected: _category,
                              isWide: isWide,
                              onQueryChanged: (v) => setState(() => _query = v),
                              onCategoryChanged: (v) =>
                                  setState(() => _category = v),
                            ),
                          ),
                        ),
                      ),
                      if (visible.isEmpty)
                        SliverToBoxAdapter(
                          child: _ContentWidth(
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(pad, 60, pad, 60),
                              child: _EmptyState(
                                query: _query,
                                onClear: () {
                                  _searchController.clear();
                                  setState(() {
                                    _query = '';
                                    _category = null;
                                  });
                                },
                              ),
                            ),
                          ),
                        )
                      else
                        SliverToBoxAdapter(
                          child: _ContentWidth(
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(pad, 20, pad, 0),
                              child: GridView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                padding: EdgeInsets.zero,
                                itemCount: visible.length,
                                gridDelegate:
                                    const SliverGridDelegateWithMaxCrossAxisExtent(
                                      maxCrossAxisExtent: 380,
                                      mainAxisExtent: 196,
                                      crossAxisSpacing: 16,
                                      mainAxisSpacing: 16,
                                    ),
                                itemBuilder: (context, i) => _AppTile(
                                  app: visible[i],
                                  busy: _launching?.id == visible[i].id,
                                  onTap: () => _open(visible[i]),
                                ),
                              ),
                            ),
                          ),
                        ),
                      SliverToBoxAdapter(
                        child: _ContentWidth(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(pad, 32, pad, 36),
                            child: const _FooterNote(),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            if (_launching != null) _HandoffOverlay(appName: _launching!.name),
          ],
        ),
      ),
    );
  }

  static String _firstName(String full) {
    final trimmed = full.trim();
    if (trimmed.isEmpty) return 'there';
    return trimmed.split(RegExp(r'\s+')).first;
  }
}

// ───────────────────────────────────────────────────────────────────
// Layout helpers
// ───────────────────────────────────────────────────────────────────

/// Caps the launcher at a comfortable reading width on large monitors
/// and centres it.
class _ContentWidth extends StatelessWidget {
  final Widget child;
  const _ContentWidth({required this.child});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180),
        child: child,
      ),
    );
  }
}

/// Aurora glows over near-black, plus the oversized swoosh watermark.
class _AmbientBackground extends StatelessWidget {
  const _AmbientBackground();

  @override
  Widget build(BuildContext context) {
    // The shared Vistar ambient, which follows the light / dark palette.
    return const VistarAmbient();
  }
}

// ───────────────────────────────────────────────────────────────────
// Header
// ───────────────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final String displayName;
  final String email;
  final String role;
  final bool compact;
  final VoidCallback onSignOut;
  final bool isDark;
  final VoidCallback onToggleTheme;

  const _TopBar({
    required this.displayName,
    required this.email,
    required this.role,
    required this.compact,
    required this.onSignOut,
    required this.isDark,
    required this.onToggleTheme,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        VistarSwoosh(size: compact ? 34 : 40),
        const SizedBox(width: 12),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Vistar', style: VistarType.display(size: compact ? 19 : 22)),
            Text('Workspace', style: VistarType.overline(size: 9.5)),
          ],
        ),
        const Spacer(),
        if (!compact) ...[
          _UserChip(displayName: displayName, email: email, role: role),
          const SizedBox(width: 10),
        ],
        Tooltip(
          message: isDark ? 'Switch to light mode' : 'Switch to dark mode',
          child: IconButton(
            onPressed: onToggleTheme,
            icon: Icon(
              isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              size: 20,
            ),
            color: VistarPalette.txt2,
            style: IconButton.styleFrom(
              backgroundColor: VistarPalette.surface2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(VistarPalette.rSm),
                side: BorderSide(color: VistarPalette.line),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: 'Sign out',
          child: IconButton(
            onPressed: onSignOut,
            icon: const Icon(Icons.logout_rounded, size: 20),
            color: VistarPalette.txt2,
            style: IconButton.styleFrom(
              backgroundColor: VistarPalette.surface2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(VistarPalette.rSm),
                side: BorderSide(color: VistarPalette.line),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _UserChip extends StatelessWidget {
  final String displayName;
  final String email;
  final String role;

  const _UserChip({
    required this.displayName,
    required this.email,
    required this.role,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
      decoration: BoxDecoration(
        color: VistarPalette.surface2,
        borderRadius: BorderRadius.circular(VistarPalette.rLg),
        border: Border.all(color: VistarPalette.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Avatar(name: displayName.isEmpty ? email : displayName),
          const SizedBox(width: 10),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                displayName.isEmpty ? email : displayName,
                style: VistarType.body(
                  size: 13.5,
                  weight: FontWeight.w700,
                  color: VistarPalette.txt,
                  height: 1.2,
                ),
              ),
              Text(
                role,
                style: VistarType.body(
                  size: 11.5,
                  weight: FontWeight.w600,
                  color: VistarPalette.txt3,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String name;
  const _Avatar({required this.name});

  String get _initials {
    final parts = name
        .trim()
        .split(RegExp(r'[\s._@]+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'V';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts[0].substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: VistarPalette.ribbon,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        _initials,
        style: VistarType.body(
          size: 13,
          weight: FontWeight.w800,
          color: Colors.white,
          height: 1,
        ),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  final String firstName;
  final int appCount;
  final int suiteCount;
  final bool isWide;
  final bool canAutoLogin;

  const _Hero({
    required this.firstName,
    required this.appCount,
    required this.suiteCount,
    required this.isWide,
    required this.canAutoLogin,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('YOUR VISTAR APPS', style: VistarType.overline()),
        const SizedBox(height: 14),
        _RibbonHeadline(
          leading: 'Welcome back, ',
          accent: firstName,
          trailing: '.',
          size: isWide ? 42 : 30,
        ),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Text(
            canAutoLogin
                ? 'You signed in once. Pick an app and we sign you in there '
                      'with the same credentials — straight to its home page.'
                : 'Pick an app to open it. Sign in again on this workspace to '
                      're-enable one-click sign-in across apps.',
            style: VistarType.body(size: isWide ? 15.5 : 14.5),
          ),
        ),
        const SizedBox(height: 22),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _StatPill(
              icon: Icons.apps_rounded,
              label: '$appCount apps',
            ),
            _StatPill(
              icon: Icons.category_outlined,
              label: '$suiteCount suites',
            ),
            _StatPill(
              icon: canAutoLogin
                  ? Icons.bolt_rounded
                  : Icons.lock_open_outlined,
              label: canAutoLogin
                  ? 'One-click sign-in on'
                  : 'One-click sign-in off',
              highlight: canAutoLogin,
            ),
          ],
        ),
      ],
    );
  }
}

/// Headline where one word is filled with the brand ribbon.
class _RibbonHeadline extends StatelessWidget {
  final String leading;
  final String accent;
  final String trailing;
  final double size;

  const _RibbonHeadline({
    required this.leading,
    required this.accent,
    required this.trailing,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final style = VistarType.display(size: size);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(leading, style: style),
        ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) =>
              VistarPalette.ribbonFlat.createShader(bounds),
          child: Text(accent, style: style),
        ),
        Text(trailing, style: style),
      ],
    );
  }
}

class _StatPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool highlight;

  const _StatPill({
    required this.icon,
    required this.label,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
      decoration: BoxDecoration(
        color: highlight
            ? VistarPalette.pink.withValues(alpha: 0.14)
            : VistarPalette.surface2,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: highlight
              ? VistarPalette.pink.withValues(alpha: 0.35)
              : VistarPalette.line,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 15,
            color: highlight ? VistarPalette.pink : VistarPalette.txt3,
          ),
          const SizedBox(width: 7),
          Text(
            label,
            style: VistarType.body(
              size: 12.5,
              weight: FontWeight.w700,
              color: highlight ? VistarPalette.txt : VistarPalette.txt2,
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────
// Search + category chips
// ───────────────────────────────────────────────────────────────────

class _Filters extends StatelessWidget {
  final TextEditingController controller;
  final List<String> categories;
  final String? selected;
  final bool isWide;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<String?> onCategoryChanged;

  const _Filters({
    required this.controller,
    required this.categories,
    required this.selected,
    required this.isWide,
    required this.onQueryChanged,
    required this.onCategoryChanged,
  });

  @override
  Widget build(BuildContext context) {
    final search = SizedBox(
      width: isWide ? 320 : double.infinity,
      child: TextField(
        controller: controller,
        onChanged: onQueryChanged,
        style: VistarType.body(size: 14, color: VistarPalette.txt),
        decoration: InputDecoration(
          hintText: 'Search apps…',
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 20,
            color: VistarPalette.txt3,
          ),
        ),
      ),
    );

    final chips = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _CategoryChip(
          key: const ValueKey('workspace-suite-all'),
          label: 'All',
          selected: selected == null,
          onTap: () => onCategoryChanged(null),
        ),
        for (final category in categories)
          _CategoryChip(
            key: ValueKey('workspace-suite-$category'),
            label: category,
            selected: selected == category,
            onTap: () => onCategoryChanged(category),
          ),
      ],
    );

    if (!isWide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [search, const SizedBox(height: 14), chips],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        search,
        const SizedBox(width: 16),
        Expanded(child: Align(alignment: Alignment.centerRight, child: chips)),
      ],
    );
  }
}

class _CategoryChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _CategoryChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
          decoration: BoxDecoration(
            gradient: selected ? VistarPalette.ribbon : null,
            color: selected ? null : VistarPalette.surface2,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? Colors.transparent : VistarPalette.line,
            ),
          ),
          child: Text(
            label,
            style: VistarType.body(
              size: 12.5,
              weight: FontWeight.w700,
              color: selected ? Colors.white : VistarPalette.txt2,
            ),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────
// App tile
// ───────────────────────────────────────────────────────────────────

class _AppTile extends StatefulWidget {
  final VistarApp app;
  final bool busy;
  final VoidCallback onTap;

  const _AppTile({required this.app, required this.busy, required this.onTap});

  @override
  State<_AppTile> createState() => _AppTileState();
}

class _AppTileState extends State<_AppTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final lifted = _hovered && app.enabled;

    return MouseRegion(
      cursor: app.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        transform: Matrix4.translationValues(0, lifted ? -2 : 0, 0),
        decoration: BoxDecoration(
          // The `.card` surface: translucent over the ambient in dark mode, clean
          // white-to-lavender in daylight.
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: VistarPalette.isDark
                ? const <Color>[Color(0xB316142A), Color(0xB3110F1E)]
                : const <Color>[Color(0xFFFFFFFF), Color(0xFFFBFAFD)],
          ),
          borderRadius: BorderRadius.circular(VistarPalette.r),
          border: Border.all(
            color: lifted ? VistarPalette.line2 : VistarPalette.line,
          ),
          boxShadow: lifted ? VistarPalette.glow : VistarPalette.shadow,
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(VistarPalette.r),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: app.enabled ? widget.onTap : null,
            child: Stack(
              children: [
                // Corner swoosh accent.
                Positioned(
                  right: -26,
                  bottom: -30,
                  child: VistarSwoosh(size: 120, opacity: lifted ? 0.09 : 0.05),
                ),
                Padding(
                  padding: const EdgeInsets.all(18),
                  child: Opacity(
                    opacity: app.enabled ? 1 : 0.45,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _IconPlate(app: app),
                            const SizedBox(width: 13),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    app.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: VistarType.display(
                                      size: 17,
                                      height: 1.25,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    app.note ?? app.host,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: VistarType.body(
                                      size: 11.5,
                                      weight: FontWeight.w600,
                                      color: VistarPalette.txt3,
                                      height: 1.3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 13),
                        Expanded(
                          child: Text(
                            app.tagline,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: VistarType.body(size: 13, height: 1.42),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            _CategoryTag(
                              label: app.category,
                              color: app.accent.last,
                            ),
                            const Spacer(),
                            if (widget.busy)
                              const _BusyDots()
                            else
                              _OpenAffordance(lifted: lifted),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IconPlate extends StatelessWidget {
  final VistarApp app;
  const _IconPlate({required this.app});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 52,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: app.accentGradient,
        borderRadius: BorderRadius.circular(15),
        boxShadow: [
          BoxShadow(
            color: app.accent.last.withValues(alpha: 0.35),
            blurRadius: 22,
            spreadRadius: -8,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Icon(app.icon, size: 25, color: Colors.white),
    );
  }
}

class _CategoryTag extends StatelessWidget {
  final String label;
  final Color color;

  const _CategoryTag({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: VistarType.body(
              size: 11.5,
              weight: FontWeight.w700,
              color: VistarPalette.txt2,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _OpenAffordance extends StatelessWidget {
  final bool lifted;
  const _OpenAffordance({required this.lifted});

  @override
  Widget build(BuildContext context) {
    final color = lifted ? VistarPalette.pink : VistarPalette.txt3;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Open',
          style: VistarType.body(
            size: 12.5,
            weight: FontWeight.w700,
            color: color,
          ),
        ),
        const SizedBox(width: 5),
        Icon(Icons.arrow_outward_rounded, size: 15, color: color),
      ],
    );
  }
}

class _BusyDots extends StatelessWidget {
  const _BusyDots();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 13,
          height: 13,
          child: CircularProgressIndicator(
            strokeWidth: 1.8,
            valueColor: const AlwaysStoppedAnimation<Color>(VistarPalette.pink),
            backgroundColor: VistarPalette.line2,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          'Signing in',
          style: VistarType.body(
            size: 12.5,
            weight: FontWeight.w700,
            color: VistarPalette.pink,
          ),
        ),
      ],
    );
  }
}

// ───────────────────────────────────────────────────────────────────
// Empty state / footer / overlay
// ───────────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final String query;
  final VoidCallback onClear;

  const _EmptyState({required this.query, required this.onClear});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        children: [
          VistarSwoosh(size: 88, opacity: 0.22),
          const SizedBox(height: 20),
          Text(
            query.isEmpty ? 'Nothing in this suite yet' : 'No apps match',
            style: VistarType.display(size: 20),
          ),
          const SizedBox(height: 8),
          Text(
            query.isEmpty
                ? 'Pick another suite to see what you have access to.'
                : 'Nothing matches “$query”.',
            textAlign: TextAlign.center,
            style: VistarType.body(size: 14),
          ),
          const SizedBox(height: 18),
          TextButton(
            onPressed: onClear,
            child: Text(
              'Show all apps',
              style: VistarType.body(
                size: 13.5,
                weight: FontWeight.w700,
                color: VistarPalette.pink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FooterNote extends StatelessWidget {
  const _FooterNote();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.shield_outlined,
          size: 15,
          color: VistarPalette.txt3,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Apps open in a new tab with a 60-second Vistar hand-off that signs '
            'you in there. Your password is held in memory only for this tab '
            'and cleared when you sign out.',
            style: VistarType.body(size: 12.5, color: VistarPalette.txt3),
          ),
        ),
      ],
    );
  }
}

/// Full-screen "handing you over" curtain, shown for a beat after the new
/// tab is requested.
class _HandoffOverlay extends StatelessWidget {
  final String appName;
  const _HandoffOverlay({required this.appName});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 3, sigmaY: 3),
          child: Container(
            color: VistarPalette.bg.withValues(alpha: 0.62),
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const VistarBreathingMark(size: 74),
                const SizedBox(height: 20),
                Text('Opening $appName', style: VistarType.display(size: 20)),
                const SizedBox(height: 8),
                Text(
                  'Handing your Vistar session across…',
                  style: VistarType.body(size: 13.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
