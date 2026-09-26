import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_permissions_provider.dart';
import '../../core/widgets/dpl_empty_state.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_admin.dart';
import '../providers/admin_providers.dart';

/// Organizations — the tenants everything else is scoped to.
///
/// Every part, plan, trip and user belongs to exactly one, and the JWT carries
/// it, so this is the highest-consequence master in the system. An
/// organization is never deleted: its code appears on stickers and slips that
/// will outlive it. It is deactivated, which hides it from the login screen
/// and stops anyone being assigned to it.
class AdminOrganizationsScreen extends ConsumerWidget {
  const AdminOrganizationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminOrganizationsProvider);
    final canManage = ref.watch(dplPermissionsProvider).can(DplPermission.orgsManage);

    return Scaffold(
      backgroundColor: DplColors.pageBg,
      floatingActionButton: canManage
          ? FloatingActionButton.extended(
              onPressed: () => _edit(context, ref, null),
              icon: const Icon(Icons.add_business_outlined),
              label: const Text('Add organization'),
            )
          : null,
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => DplInlineErrorRetry(
          message: e.toString(),
          onRetry: () => ref.invalidate(adminOrganizationsProvider),
        ),
        data: (res) {
          if (res.isError) {
            return DplInlineErrorRetry(
              message: res.error ?? 'Failed to load organizations.',
              onRetry: () => ref.invalidate(adminOrganizationsProvider),
            );
          }
          final rows = res.data ?? const <DplAdminOrganization>[];
          if (rows.isEmpty) {
            return const DplEmptyView(
              title: 'No organizations yet',
              message:
                  'An organization is the plant or company everything else '
                  'belongs to. Add one before adding people.',
              icon: Icons.apartment_outlined,
            );
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(adminOrganizationsProvider),
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 96),
              itemCount: rows.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _OrgTile(
                org: rows[i],
                canManage: canManage,
                onEdit: () => _edit(context, ref, rows[i]),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    DplAdminOrganization? existing,
  ) async {
    final result = await showDialog<DplAdminOrganization>(
      context: context,
      builder: (_) => _OrgDialog(existing: existing),
    );
    if (result == null || !context.mounted) return;

    final svc = ref.read(dplApiServiceProvider);
    final res = existing == null
        ? await svc.createAdminOrganization(result)
        : await svc.updateAdminOrganization(existing.id, result);
    if (!context.mounted) return;

    if (res.isError) {
      // ORG_CODE_TAKEN and ORG_HAS_ACTIVE_USERS both name the obstacle.
      DplSnacks.error(context, res.error ?? 'Failed to save the organization.');
      return;
    }
    DplSnacks.success(
      context,
      existing == null ? 'Organization created.' : 'Organization updated.',
    );
    ref.invalidate(adminOrganizationsProvider);
    ref.invalidate(adminAuditProvider);
  }
}

class _OrgTile extends StatelessWidget {
  final DplAdminOrganization org;
  final bool canManage;
  final VoidCallback onEdit;

  const _OrgTile({
    required this.org,
    required this.canManage,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: canManage ? onEdit : null,
      borderRadius: BorderRadius.circular(14),
      child: Ink(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: DplColors.cardBg,
          border: Border.all(
            color: org.isActive ? DplColors.divider : VistarPalette.badLine,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: DplColors.primaryTint,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.apartment_rounded,
                color: DplColors.primary,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    org.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${org.code} · ${org.userCount} '
                    '${org.userCount == 1 ? 'user' : 'users'}',
                    style: TextStyle(
                      fontSize: 12,
                      color: DplColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (!org.isActive)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: DplColors.errorBg,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'Inactive',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: DplColors.error,
                  ),
                ),
              ),
            if (canManage)
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 18),
                onPressed: onEdit,
                tooltip: 'Edit',
              ),
          ],
        ),
      ),
    );
  }
}

class _OrgDialog extends StatefulWidget {
  final DplAdminOrganization? existing;

  const _OrgDialog({this.existing});

  @override
  State<_OrgDialog> createState() => _OrgDialogState();
}

class _OrgDialogState extends State<_OrgDialog> {
  late final TextEditingController _codeCtrl;
  late final TextEditingController _nameCtrl;
  late bool _isActive;
  String? _error;

  @override
  void initState() {
    super.initState();
    _codeCtrl = TextEditingController(text: widget.existing?.code ?? '');
    _nameCtrl = TextEditingController(text: widget.existing?.name ?? '');
    _isActive = widget.existing?.isActive ?? true;
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final code = _codeCtrl.text.trim().toUpperCase();
    final name = _nameCtrl.text.trim();

    if (code.isEmpty) {
      setState(() => _error = 'A code is required.');
      return;
    }
    if (!RegExp(r'^[A-Z0-9_-]+$').hasMatch(code)) {
      setState(() => _error =
          'Use letters, numbers, hyphen and underscore only — no spaces.');
      return;
    }
    if (name.length < 2) {
      setState(() => _error = 'Enter the organization\'s full name.');
      return;
    }

    Navigator.of(context).pop(DplAdminOrganization(
      id: widget.existing?.id ?? 0,
      code: code,
      name: name,
      isActive: _isActive,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final userCount = widget.existing?.userCount ?? 0;

    return AlertDialog(
      title: Text(
        widget.existing == null ? 'Add organization' : 'Edit ${widget.existing!.code}',
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_error != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: VistarPalette.badBg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: VistarPalette.badLine),
                  ),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: VistarPalette.badInk,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _codeCtrl,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Code',
                  hintText: 'SANAND_JIT',
                  helperText:
                      'A short, stable identifier. It travels in the login '
                      'token and appears in exports, so changing it later is '
                      'disruptive — choose carefully.',
                  helperMaxLines: 4,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Vistar Logitek — Sanand JIT',
                ),
              ),
              if (widget.existing != null) ...[
                const SizedBox(height: 6),
                SwitchListTile.adaptive(
                  value: _isActive,
                  onChanged: (v) => setState(() => _isActive = v),
                  title: const Text('Active'),
                  subtitle: Text(
                    userCount > 0
                        ? 'Cannot be switched off while anyone here can still '
                            'sign in. Disable those accounts first.'
                        : 'An inactive organization is hidden from the login '
                            'screen and nobody can be assigned to it.',
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.existing == null ? 'Create' : 'Save'),
        ),
      ],
    );
  }
}
