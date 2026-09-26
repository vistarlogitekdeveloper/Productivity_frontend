import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_permissions_provider.dart';
import '../../core/widgets/dpl_empty_state.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_admin.dart';
import '../providers/admin_providers.dart';
import '../widgets/user_editor_dialog.dart';

/// The people list. Add someone, change their role, disable them, reset a
/// password.
///
/// There is no delete, here or in the API. Every sticker, scan, slip and trip
/// points at the user who made it, so removing the row would either break
/// those references or let the id be reused and re-attribute somebody else's
/// work. Disabling stops the login and leaves the history intact.
class AdminUsersScreen extends ConsumerStatefulWidget {
  const AdminUsersScreen({super.key});

  @override
  ConsumerState<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends ConsumerState<AdminUsersScreen> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) ref.read(adminUserSearchProvider.notifier).set(v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(adminUsersProvider);
    final perms = ref.watch(dplPermissionsProvider);
    final canManage = perms.can(DplPermission.usersManage);

    return Scaffold(
      backgroundColor: DplColors.pageBg,
      floatingActionButton: canManage
          ? FloatingActionButton.extended(
              onPressed: () => _edit(null),
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Add user'),
            )
          : null,
      body: Column(
        children: [
          _Filters(searchCtrl: _searchCtrl, onSearch: _onSearch),
          Expanded(
            child: async.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => DplInlineErrorRetry(
                message: e.toString(),
                onRetry: () => ref.invalidate(adminUsersProvider),
              ),
              data: (res) {
                if (res.isError) {
                  return DplInlineErrorRetry(
                    message: res.error ?? 'Failed to load users.',
                    onRetry: () => ref.invalidate(adminUsersProvider),
                  );
                }
                final rows = res.data?.users ?? const <DplManagedUser>[];
                if (rows.isEmpty) {
                  return const DplEmptyView(
                    title: 'Nobody matches those filters',
                    message:
                        'Clear the search, or add the first person for this '
                        'organization. Everyone who signs in to Vistar Pulse '
                        'needs an account here.',
                    icon: Icons.group_outlined,
                  );
                }
                return RefreshIndicator(
                  onRefresh: () async => ref.invalidate(adminUsersProvider),
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(14, 4, 14, 96),
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _UserTile(
                      user: rows[i],
                      canManage: canManage,
                      onEdit: () => _edit(rows[i]),
                      onToggleActive: () => _toggleActive(rows[i]),
                      onResetPassword: () => _resetPassword(rows[i]),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _edit(DplManagedUser? existing) async {
    final orgsRes = ref.read(adminOrganizationsProvider).asData?.value;
    final orgs = orgsRes?.data ?? const <DplAdminOrganization>[];
    final catalogue = ref.read(adminCatalogueProvider).asData?.value;
    final roles = catalogue?.data?.roles ?? const <DplRoleInfo>[];

    if (orgs.isEmpty || roles.isEmpty) {
      // Without these two lists the form cannot offer a valid organization or
      // role, and a half-populated form is worse than a clear refusal.
      DplSnacks.warning(
        context,
        'Still loading organizations and roles — try again in a moment.',
      );
      ref
        ..invalidate(adminOrganizationsProvider)
        ..invalidate(adminCatalogueProvider);
      return;
    }

    final result = await showDialog<UserEditorResult>(
      context: context,
      builder: (_) => UserEditorDialog(
        existing: existing,
        organizations: orgs.where((o) => o.isActive || o.id == existing?.organizationId).toList(),
        roles: roles,
      ),
    );
    if (result == null || !mounted) return;

    final svc = ref.read(dplApiServiceProvider);
    final res = existing == null
        ? await svc.createAdminUser(result.user, password: result.password ?? '')
        : await svc.updateAdminUser(existing.id, result.user);
    if (!mounted) return;

    if (res.isError) {
      // EMAIL_TAKEN / EMPLOYEE_CODE_TAKEN / ORG_INACTIVE / LAST_ADMIN all
      // carry a message that already names the conflict.
      DplSnacks.error(context, res.error ?? 'Failed to save the user.');
      return;
    }
    DplSnacks.success(
      context,
      existing == null
          ? '${result.user.name} can now sign in. Give them the temporary '
              'password — they will be asked to change it.'
          : 'User updated.',
    );
    ref.invalidate(adminUsersProvider);
    ref.invalidate(adminAuditProvider);
  }

  Future<void> _toggleActive(DplManagedUser user) async {
    final disabling = user.isActive;
    if (disabling) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Disable ${user.name}?'),
          content: const Text(
            'They will not be able to sign in. Nothing they have already done '
            'is removed — every scan, label and slip keeps their name on it.\n\n'
            'You can re-enable the account at any time.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: VistarPalette.badSolid),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Disable'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    final res = await ref
        .read(dplApiServiceProvider)
        .setAdminUserActive(user.id, !user.isActive);
    if (!mounted) return;
    if (res.isError) {
      // LAST_ADMIN and CANNOT_DISABLE_SELF both explain themselves.
      DplSnacks.error(context, res.error ?? 'Failed to change the account.');
      return;
    }
    DplSnacks.success(
      context,
      disabling ? '${user.name} can no longer sign in.' : '${user.name} can sign in again.',
    );
    ref.invalidate(adminUsersProvider);
    ref.invalidate(adminAuditProvider);
  }

  Future<void> _resetPassword(DplManagedUser user) async {
    final password = await showDialog<String>(
      context: context,
      builder: (_) => _PasswordDialog(userName: user.name),
    );
    if (password == null || !mounted) return;

    final res =
        await ref.read(dplApiServiceProvider).resetAdminUserPassword(user.id, password);
    if (!mounted) return;
    if (res.isError) {
      DplSnacks.error(context, res.error ?? 'Failed to reset the password.');
      return;
    }
    DplSnacks.success(
      context,
      'Password set. Give it to ${user.name} — they will be asked to change '
      'it when they sign in.',
    );
    ref.invalidate(adminUsersProvider);
    ref.invalidate(adminAuditProvider);
  }
}

// ---------------------------------------------------------------------------
// Filters
// ---------------------------------------------------------------------------

class _Filters extends ConsumerWidget {
  final TextEditingController searchCtrl;
  final ValueChanged<String> onSearch;

  const _Filters({required this.searchCtrl, required this.onSearch});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orgs =
        ref.watch(adminOrganizationsProvider).asData?.value.data ??
            const <DplAdminOrganization>[];
    final roles =
        ref.watch(adminCatalogueProvider).asData?.value.data?.roles ??
            const <DplRoleInfo>[];
    final orgFilter = ref.watch(adminUserOrgFilterProvider);
    final status = ref.watch(adminUserStatusProvider);
    final roleFilter = ref.watch(adminUserRoleProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      child: Column(
        children: [
          TextField(
            controller: searchCtrl,
            decoration: const InputDecoration(
              hintText: 'Search name, email or employee code',
              prefixIcon: Icon(Icons.search_rounded),
              isDense: true,
            ),
            onChanged: onSearch,
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _Dropdown<int?>(
                  icon: Icons.apartment_outlined,
                  value: orgFilter,
                  hint: 'All organizations',
                  items: [
                    const DropdownMenuItem<int?>(
                      value: null,
                      child: Text('All organizations'),
                    ),
                    ...orgs.map(
                      (o) => DropdownMenuItem<int?>(
                        value: o.id,
                        child: Text(o.label),
                      ),
                    ),
                  ],
                  onChanged: (v) =>
                      ref.read(adminUserOrgFilterProvider.notifier).set(v),
                ),
                const SizedBox(width: 8),
                _Dropdown<String>(
                  icon: Icons.badge_outlined,
                  value: roleFilter,
                  hint: 'All roles',
                  items: [
                    const DropdownMenuItem<String>(
                      value: '',
                      child: Text('All roles'),
                    ),
                    ...roles.map(
                      (r) => DropdownMenuItem<String>(
                        value: r.key,
                        child: Text(r.label),
                      ),
                    ),
                  ],
                  onChanged: (v) =>
                      ref.read(adminUserRoleProvider.notifier).set(v ?? ''),
                ),
                const SizedBox(width: 8),
                _Dropdown<String>(
                  icon: Icons.toggle_on_outlined,
                  value: status,
                  hint: 'All',
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('All')),
                    DropdownMenuItem(value: 'active', child: Text('Active')),
                    DropdownMenuItem(value: 'disabled', child: Text('Disabled')),
                  ],
                  onChanged: (v) =>
                      ref.read(adminUserStatusProvider.notifier).set(v ?? 'all'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  final IconData icon;
  final T value;
  final String hint;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  const _Dropdown({
    required this.icon,
    required this.value,
    required this.hint,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // `value` is only honoured when it is present among the items — while the
    // org or role list is still loading it will not be, and passing it anyway
    // makes DropdownButton assert. Falling back to null shows the hint for a
    // frame instead of crashing the tab.
    final hasValue = items.any((i) => i.value == value);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: DplColors.cardBg,
        border: Border.all(color: DplColors.divider),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: DplColors.neutral),
          const SizedBox(width: 6),
          DropdownButton<T>(
            value: hasValue ? value : null,
            hint: Text(hint, style: const TextStyle(fontSize: 13)),
            underline: const SizedBox.shrink(),
            isDense: true,
            style: TextStyle(fontSize: 13, color: DplColors.textPrimary),
            items: items,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Row
// ---------------------------------------------------------------------------

class _UserTile extends ConsumerWidget {
  final DplManagedUser user;
  final bool canManage;
  final VoidCallback onEdit;
  final VoidCallback onToggleActive;
  final VoidCallback onResetPassword;

  const _UserTile({
    required this.user,
    required this.canManage,
    required this.onEdit,
    required this.onToggleActive,
    required this.onResetPassword,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final roles =
        ref.watch(adminCatalogueProvider).asData?.value.data?.roles ??
            const <DplRoleInfo>[];
    final roleLabel = roles
        .where((r) => r.key == user.role)
        .map((r) => r.label)
        .firstOrNull ??
        user.role;

    return Opacity(
      // A disabled account stays visible but reads as switched off. Hiding it
      // would make "why can this person not log in" unanswerable from here.
      opacity: user.isActive ? 1 : 0.55,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: DplColors.cardBg,
          border: Border.all(
            color: user.isActive ? DplColors.divider : VistarPalette.badLine,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: DplColors.primaryTint,
                  child: Text(
                    _initials(user.name),
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      color: DplColors.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user.name.isEmpty ? user.email : user.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        user.email,
                        style: TextStyle(
                          fontSize: 12,
                          color: DplColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (canManage)
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, size: 20),
                    onSelected: (v) {
                      switch (v) {
                        case 'edit':
                          onEdit();
                        case 'password':
                          onResetPassword();
                        case 'status':
                          onToggleActive();
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'edit', child: Text('Edit details')),
                      const PopupMenuItem(
                        value: 'password',
                        child: Text('Set new password'),
                      ),
                      PopupMenuItem(
                        value: 'status',
                        child: Text(
                          user.isActive ? 'Disable account' : 'Enable account',
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _Chip(text: roleLabel, color: DplColors.primary),
                _Chip(text: user.organizationLabel, color: DplColors.neutral),
                if (user.employeeCode.isNotEmpty)
                  _Chip(text: user.employeeCode, color: DplColors.neutral),
                if (!user.isActive)
                  _Chip(text: 'Disabled', color: DplColors.error),
                if (user.mustChangePassword)
                  _Chip(
                    text: 'Must change password',
                    color: DplColors.warning,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              user.hasNeverLoggedIn
                  ? 'Never signed in'
                  : 'Last signed in ${DateFormat('d MMM yyyy, HH:mm').format(user.lastLoginAt!.toLocal())}',
              style: TextStyle(fontSize: 11, color: DplColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }
}

class _Chip extends StatelessWidget {
  final String text;
  final Color color;

  const _Chip({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Password dialog
// ---------------------------------------------------------------------------

/// Sets somebody else's password.
///
/// There is no "show current password" here and there never can be: the API
/// stores a bcrypt hash and returns nothing. An administrator can only
/// replace a password, and the account is flagged so the value they typed
/// stops working the moment the user sets their own.
class _PasswordDialog extends StatefulWidget {
  final String userName;

  const _PasswordDialog({required this.userName});

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _ctrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _ctrl.text;
    if (value.length < 8) {
      setState(() => _error = 'Use at least 8 characters.');
      return;
    }
    if (value != _confirmCtrl.text) {
      setState(() => _error = 'The two passwords do not match.');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('New password for ${widget.userName}'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error != null) ...[
              _ErrorBox(message: _error!),
              const SizedBox(height: 10),
            ],
            TextField(
              controller: _ctrl,
              obscureText: _obscure,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Temporary password',
                helperText:
                    'They will be asked to change it the first time they sign in.',
                helperMaxLines: 2,
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _confirmCtrl,
              obscureText: _obscure,
              decoration: const InputDecoration(labelText: 'Type it again'),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Set password')),
      ],
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String message;

  const _ErrorBox({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: VistarPalette.badBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: VistarPalette.badLine),
      ),
      child: Text(
        message,
        style: TextStyle(
          color: VistarPalette.badInk,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
