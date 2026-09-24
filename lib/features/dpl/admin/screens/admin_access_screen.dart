import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_permissions_provider.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_admin.dart';
import '../providers/admin_providers.dart';

/// Access rules — which roles may do what.
///
/// One role at a time rather than a full roles-by-permissions matrix. The
/// matrix is what you draw on a whiteboard; on a phone or a tablet at the
/// plant it is eleven columns of unlabelled tick boxes, and the question
/// people actually arrive with is "what can QA do?", not "who can print?".
///
/// Unsaved edits are held locally and committed in one save, so a half-applied
/// change never exists. Only the cells that differ from what the server
/// returned are sent: writing the whole row would store an override for every
/// permission and freeze that role at today's defaults for ever.
class AdminAccessScreen extends ConsumerStatefulWidget {
  const AdminAccessScreen({super.key});

  @override
  ConsumerState<AdminAccessScreen> createState() => _AdminAccessScreenState();
}

class _AdminAccessScreenState extends ConsumerState<AdminAccessScreen> {
  String? _role;

  /// Local edit buffer, keyed by permission. Empty means nothing is pending.
  final Map<String, bool> _pending = {};

  /// The organization and role the buffer belongs to, captured on the FIRST
  /// edit rather than re-read at save time.
  ///
  /// `_save` used to read the organization back out of the provider. That is
  /// the same provider the organization picker invalidates, and a provider
  /// mid-refetch still reports its previous value — so a save that landed in
  /// that window could have written one tenant's edits onto another tenant's
  /// rules. Access rules are the last thing that should be applied to the
  /// wrong plant, so the target is pinned to whatever was actually on screen
  /// when the first box was ticked.
  int? _pendingOrgId;
  String? _pendingRole;

  bool _saving = false;

  void _clearPending() {
    _pending.clear();
    _pendingOrgId = null;
    _pendingRole = null;
  }

  /// A human name for an organization id, for confirmation copy. Falls back to
  /// the id so a dialog never reads "Reset ... at null" — and a destructive
  /// confirmation that cannot say what it will affect is worse than none.
  String _organizationLabel(int orgId) {
    final orgs = ref.read(adminOrganizationsProvider).asData?.value.data ??
        const <DplAdminOrganization>[];
    final match = orgs.where((o) => o.id == orgId).firstOrNull;
    return match?.label ?? 'organization #$orgId';
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(adminPermissionMatrixProvider);
    final canManage =
        ref.watch(dplPermissionsProvider).can(DplPermission.permissionsManage);

    return Scaffold(
      backgroundColor: DplColors.pageBg,
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => DplInlineErrorRetry(
          message: e.toString(),
          onRetry: () => ref.invalidate(adminPermissionMatrixProvider),
        ),
        data: (res) {
          if (res.isError) {
            return DplInlineErrorRetry(
              message: res.error ?? 'Failed to load the access rules.',
              onRetry: () => ref.invalidate(adminPermissionMatrixProvider),
            );
          }
          final matrix = res.data;
          if (matrix == null || matrix.roles.isEmpty) {
            return const Center(child: Text('No roles to configure.'));
          }

          final role = _role ?? matrix.roles.first.key;
          final roleInfo =
              matrix.roles.where((r) => r.key == role).firstOrNull;

          return Column(
            children: [
              // WHICH organization these rules belong to. Without this the
              // administrator could only ever edit their own tenant, which
              // makes the whole per-organization design unreachable — and
              // per-organization is the point: one plant prints labels one at
              // a time, another prints a pallet's worth, and the same role
              // name means different things in each.
              _OrgPicker(
                pendingCount: _pending.length,
                onChangeRequested: _switchOrganization,
              ),
              _RolePicker(
                roles: matrix.roles,
                selected: role,
                pendingCount: _pending.length,
                onChanged: (v) => _switchRole(v),
              ),
              if (roleInfo != null && roleInfo.description.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                  child: Text(
                    roleInfo.description,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF6B7280),
                    ),
                  ),
                ),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                    14,
                    4,
                    14,
                    _pending.isEmpty ? 24 : 104,
                  ),
                  children: [
                    for (final group in matrix.groups)
                      _GroupCard(
                        group: group,
                        matrix: matrix,
                        role: role,
                        pending: _pending,
                        enabled: canManage && !_saving,
                        onToggle: (key, value) => _toggle(matrix, role, key, value),
                      ),
                    const SizedBox(height: 8),
                    if (canManage)
                      TextButton.icon(
                        onPressed: _saving
                            ? null
                            : () => _resetRole(
                                  matrix.organizationId,
                                  role,
                                  roleInfo,
                                ),
                        icon: const Icon(Icons.restart_alt, size: 18),
                        label: const Text('Reset this role to the built-in defaults'),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: _pending.isEmpty
          ? null
          : _SaveBar(
              count: _pending.length,
              saving: _saving,
              onDiscard: () => setState(_clearPending),
              onSave: _save,
            ),
    );
  }

  /// Ask before moving away from unsaved edits.
  ///
  /// Silently dropping them when a picker moves is how a save gets "lost" with
  /// nobody able to say what happened — and here the edits are access rules,
  /// so the person walks away believing they changed who can do what.
  Future<bool> _confirmDiscard() async {
    if (_pending.isEmpty) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard unsaved changes?'),
        content: Text(
          'You have ${_pending.length} unsaved change'
          '${_pending.length == 1 ? '' : 's'} that have not been saved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Stay here'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard == true;
  }

  Future<void> _switchRole(String next) async {
    if (!await _confirmDiscard() || !mounted) return;
    setState(() {
      _clearPending();
      _role = next;
    });
  }

  /// Move to another organization's rules.
  ///
  /// The pending buffer is keyed by permission only, so carrying it across a
  /// switch would apply one tenant's edits to another's grid. It is always
  /// cleared.
  Future<void> _switchOrganization(int? orgId) async {
    if (!await _confirmDiscard() || !mounted) return;
    setState(_clearPending);
    ref.read(adminPermissionOrgProvider.notifier).set(orgId);
  }

  void _toggle(DplPermissionMatrix matrix, String role, String key, bool value) {
    final current = matrix.cell(role, key);
    setState(() {
      // Pin the target on the first edit. `matrix` here is the one actually
      // rendered under the operator's finger, which is the only copy that
      // cannot be stale.
      _pendingOrgId ??= matrix.organizationId;
      _pendingRole ??= role;

      // Toggling back to the server's value removes the pending entry rather
      // than recording a no-op change — otherwise the save bar claims edits
      // that would write nothing.
      if (value == current.allowed) {
        _pending.remove(key);
      } else {
        _pending[key] = value;
      }
      if (_pending.isEmpty) {
        _pendingOrgId = null;
        _pendingRole = null;
      }
    });
  }

  Future<void> _save() async {
    // Both taken from the buffer, not re-read from the provider — see the
    // note on _pendingOrgId. If either is missing there is nothing coherent
    // to write, and guessing is exactly the failure mode being avoided.
    final orgId = _pendingOrgId;
    final role = _pendingRole;
    if (orgId == null || role == null || _pending.isEmpty) return;

    setState(() => _saving = true);
    final res = await ref.read(dplApiServiceProvider).setAdminPermissions(
          organizationId: orgId,
          role: role,
          changes: Map<String, bool>.from(_pending),
        );
    if (!mounted) return;
    setState(() => _saving = false);

    if (res.isError) {
      // ADMIN_LOCKOUT_REFUSED explains exactly which permissions cannot be
      // given up and why, so surface it as-is.
      DplSnacks.error(context, res.error ?? 'Failed to save the access rules.');
      return;
    }

    setState(_clearPending);
    DplSnacks.success(
      context,
      'Saved. It applies the next time someone with that role opens the app.',
    );
    ref.invalidate(adminPermissionMatrixProvider);
    ref.invalidate(adminAuditProvider);
    // The administrator's own permissions may have just changed.
    await ref.read(dplPermissionsProvider.notifier).refresh();
  }

  /// [orgId] is passed in from the rendered grid rather than read back out of
  /// the provider. Reset is destructive — it drops every override for the role
  /// — and it sits behind a confirmation dialog, which is exactly the window
  /// in which a refetch could swap the provider's organization underneath it.
  Future<void> _resetRole(int orgId, String role, DplRoleInfo? info) async {
    final orgName = _organizationLabel(orgId);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reset ${info?.label ?? role}?'),
        content: Text(
          'Every change made to this role at $orgName is removed, and it goes '
          'back to the access it ships with. Other roles and other '
          'organizations are untouched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _saving = true);
    final res = await ref.read(dplApiServiceProvider).resetAdminPermissions(
          organizationId: orgId,
          role: role,
        );
    if (!mounted) return;
    setState(() {
      _saving = false;
      _clearPending();
    });

    if (res.isError) {
      DplSnacks.error(context, res.error ?? 'Failed to reset the role.');
      return;
    }
    DplSnacks.success(context, 'Role reset to its defaults.');
    ref.invalidate(adminPermissionMatrixProvider);
    ref.invalidate(adminAuditProvider);
  }
}

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

/// Which organization's access rules are on screen.
///
/// Defaults to the administrator's own — that is what the backend returns when
/// no `organization_id` is passed, and it is the one they mean nine times out
/// of ten. Changing another tenant's access rules by accident is an expensive
/// mistake, so the picker names the organization rather than relying on the
/// admin remembering which one they left it on.
class _OrgPicker extends ConsumerWidget {
  final int pendingCount;
  final Future<void> Function(int? orgId) onChangeRequested;

  const _OrgPicker({
    required this.pendingCount,
    required this.onChangeRequested,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orgs = ref.watch(adminOrganizationsProvider).asData?.value.data ??
        const <DplAdminOrganization>[];
    final selected = ref.watch(adminPermissionOrgProvider);

    // Inactive tenants are offered too: rules set for one that was switched
    // off still apply the moment it comes back, and hiding it makes that
    // invisible.
    final items = <DropdownMenuItem<int?>>[
      const DropdownMenuItem<int?>(
        value: null,
        child: Text('My organization'),
      ),
      ...orgs.map(
        (o) => DropdownMenuItem<int?>(
          value: o.id,
          child: Text(o.isActive ? o.label : '${o.label} (inactive)'),
        ),
      ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
      child: _ControlledDropdown<int?>(
        label: 'Organization',
        icon: Icons.apartment_outlined,
        helperText: 'These rules apply only to people in this organization.',
        pendingCount: pendingCount,
        value: items.any((i) => i.value == selected) ? selected : null,
        items: items,
        onChanged: onChangeRequested,
      ),
    );
  }
}

/// A dropdown whose displayed value is read from its argument on every build.
///
/// NOT DropdownButtonFormField, and that is the entire point. That widget is
/// uncontrolled: FormFieldState.didChange commits the tapped value to its own
/// internal state and only THEN calls the parent's onChanged, and its
/// didUpdateWidget re-syncs only when `initialValue` itself changes
/// (verified in Flutter 3.47.2, material/dropdown.dart didChange /
/// didUpdateWidget).
///
/// Both pickers on this screen can REFUSE a change — the operator has unsaved
/// edits and answers "Stay here", or dismisses the barrier. On that path the
/// provider never moves, so `initialValue` never moves, so nothing pulls the
/// display back: the field goes on showing an organization that neither the
/// loaded grid nor the pending buffer agrees with. The administrator then
/// carries on ticking boxes under a header naming the wrong plant, and the
/// save — correctly targeted at the pinned id — grants the permission to a
/// tenant they were not looking at.
///
/// A plain DropdownButton reads `value` every build, so a refused change
/// simply never appears.
class _ControlledDropdown<T> extends StatelessWidget {
  final String label;
  final IconData icon;
  final String? helperText;
  final int pendingCount;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final Future<void> Function(T value) onChanged;

  const _ControlledDropdown({
    required this.label,
    required this.icon,
    required this.pendingCount,
    required this.value,
    required this.items,
    required this.onChanged,
    this.helperText,
  });

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        isDense: true,
        helperText: helperText,
        helperMaxLines: 2,
        suffixText: pendingCount > 0 ? '$pendingCount unsaved' : null,
        suffixStyle: const TextStyle(
          color: DplColors.warning,
          fontWeight: FontWeight.w700,
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          isDense: true,
          items: items,
          onChanged: (v) {
            if (v is T) onChanged(v);
          },
        ),
      ),
    );
  }
}

class _RolePicker extends StatelessWidget {
  final List<DplRoleInfo> roles;
  final String selected;
  final int pendingCount;
  final Future<void> Function(String) onChanged;

  const _RolePicker({
    required this.roles,
    required this.selected,
    required this.pendingCount,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final known = roles.any((r) => r.key == selected);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
      // Controlled, for the same reason as the organization picker: switching
      // role can be refused when there are unsaved edits, and an uncontrolled
      // field would keep showing the role the operator did NOT switch to while
      // the grid below still belongs to the old one.
      child: _ControlledDropdown<String?>(
        label: 'Role',
        icon: Icons.badge_outlined,
        pendingCount: pendingCount,
        value: known ? selected : null,
        items: roles
            .map(
              (r) => DropdownMenuItem<String?>(
                value: r.key,
                child: Text(r.label),
              ),
            )
            .toList(),
        onChanged: (v) async {
          if (v != null) await onChanged(v);
        },
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  final DplPermissionGroup group;
  final DplPermissionMatrix matrix;
  final String role;
  final Map<String, bool> pending;
  final bool enabled;
  final void Function(String key, bool value) onToggle;

  const _GroupCard({
    required this.group,
    required this.matrix,
    required this.role,
    required this.pending,
    required this.enabled,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE2EAF6)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: Text(
              group.label,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 13,
                color: DplColors.primary,
                letterSpacing: 0.3,
              ),
            ),
          ),
          for (final p in group.permissions)
            _PermissionRow(
              permission: p,
              cell: matrix.cell(role, p.key),
              pending: pending[p.key],
              enabled: enabled,
              onToggle: (v) => onToggle(p.key, v),
            ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  final DplPermissionInfo permission;
  final DplPermissionCell cell;
  final bool? pending;
  final bool enabled;
  final ValueChanged<bool> onToggle;

  const _PermissionRow({
    required this.permission,
    required this.cell,
    required this.pending,
    required this.enabled,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final value = pending ?? cell.allowed;
    final changed = value != cell.isDefault;

    return SwitchListTile.adaptive(
      value: value,
      // A locked cell is the Administrator's own ability to hand access back.
      // Switching it off would leave nobody able to undo the change, so the
      // backend refuses it and the switch is disabled rather than letting
      // someone discover that by being locked out.
      onChanged: enabled && !cell.locked ? onToggle : null,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
      title: Row(
        children: [
          Flexible(
            child: Text(
              permission.label,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
          ),
          if (pending != null) ...[
            const SizedBox(width: 6),
            const _Tag(text: 'unsaved', color: DplColors.warning),
          ] else if (changed) ...[
            const SizedBox(width: 6),
            const _Tag(text: 'changed', color: DplColors.info),
          ],
          if (cell.locked) ...[
            const SizedBox(width: 6),
            const Icon(Icons.lock_outline, size: 14, color: DplColors.neutral),
          ],
        ],
      ),
      subtitle: Text(
        permission.description,
        style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280)),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final Color color;

  const _Tag({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class _SaveBar extends StatelessWidget {
  final int count;
  final bool saving;
  final VoidCallback onDiscard;
  final VoidCallback onSave;

  const _SaveBar({
    required this.count,
    required this.saving,
    required this.onDiscard,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '$count change${count == 1 ? '' : 's'} not saved yet',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
            TextButton(
              onPressed: saving ? null : onDiscard,
              child: const Text('Discard'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: saving ? null : onSave,
              icon: saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check, size: 18),
              label: Text(saving ? 'Saving…' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }
}
