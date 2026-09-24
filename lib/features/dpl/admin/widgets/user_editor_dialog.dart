import 'package:flutter/material.dart';

import '../../models/dpl_admin.dart';

/// What the editor hands back.
///
/// [password] is set only when creating — an existing account's password is
/// changed through its own dialog, so "rename this person" and "change their
/// password" can never be the same accidental save.
class UserEditorResult {
  final DplManagedUser user;
  final String? password;

  const UserEditorResult({required this.user, this.password});
}

/// Add or edit one account.
///
/// The role dropdown shows each role's description under the name. Picking
/// between eleven roles by name alone is guesswork, and the wrong role is not
/// a cosmetic mistake — it decides which screens the person lands on and what
/// the server will let them do.
class UserEditorDialog extends StatefulWidget {
  final DplManagedUser? existing;
  final List<DplAdminOrganization> organizations;
  final List<DplRoleInfo> roles;

  const UserEditorDialog({
    super.key,
    this.existing,
    required this.organizations,
    required this.roles,
  });

  @override
  State<UserEditorDialog> createState() => _UserEditorDialogState();
}

class _UserEditorDialogState extends State<UserEditorDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _codeCtrl;
  final _passwordCtrl = TextEditingController();

  late int _organizationId;
  late String _role;
  bool _obscure = true;
  String? _error;

  bool get _isNew => widget.existing == null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _emailCtrl = TextEditingController(text: e?.email ?? '');
    _codeCtrl = TextEditingController(text: e?.employeeCode ?? '');

    // Default to the first organization rather than leaving the dropdown
    // empty: a form that opens in an invalid state teaches people to ignore
    // the field, and the organization decides whose data this person sees.
    _organizationId = e?.organizationId ??
        (widget.organizations.isNotEmpty ? widget.organizations.first.id : 0);
    _role = e?.role ??
        (widget.roles.isNotEmpty ? widget.roles.first.key : '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _codeCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    final email = _emailCtrl.text.trim();

    if (name.length < 2) {
      setState(() => _error = 'Enter the person\'s full name.');
      return;
    }
    if (!email.contains('@') || !email.contains('.')) {
      setState(() => _error = 'Enter a valid email address — it is what they sign in with.');
      return;
    }
    if (_organizationId <= 0) {
      setState(() => _error = 'Pick an organization.');
      return;
    }
    if (_role.isEmpty) {
      setState(() => _error = 'Pick a role.');
      return;
    }
    if (_isNew && _passwordCtrl.text.length < 8) {
      setState(() => _error = 'The temporary password needs at least 8 characters.');
      return;
    }

    final org = widget.organizations
        .where((o) => o.id == _organizationId)
        .firstOrNull;

    Navigator.of(context).pop(
      UserEditorResult(
        user: DplManagedUser(
          id: widget.existing?.id ?? 0,
          organizationId: _organizationId,
          organizationCode: org?.code ?? '',
          organizationName: org?.name ?? '',
          name: name,
          email: email,
          employeeCode: _codeCtrl.text.trim(),
          role: _role,
          isActive: widget.existing?.isActive ?? true,
          mustChangePassword: _isNew,
        ),
        password: _isNew ? _passwordCtrl.text : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedRole =
        widget.roles.where((r) => r.key == _role).firstOrNull;

    return AlertDialog(
      title: Text(_isNew ? 'Add user' : 'Edit ${widget.existing!.name}'),
      content: SizedBox(
        width: 460,
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
                    color: const Color(0xFFFFECEA),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFFFB4AA)),
                  ),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: Color(0xFF8F1D18),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _nameCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Full name',
                  hintText: 'Ramesh Patel',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  helperText: 'This is what they sign in with. Must be unique.',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _codeCtrl,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Employee code (optional)',
                  hintText: 'DPL-Q-002',
                  helperText: 'Their badge number. Unique within the organization.',
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<int>(
                initialValue: widget.organizations.any((o) => o.id == _organizationId)
                    ? _organizationId
                    : null,
                decoration: const InputDecoration(
                  labelText: 'Organization',
                  helperText: 'Decides whose plans, parts and trips they see.',
                  helperMaxLines: 2,
                ),
                items: widget.organizations
                    .map(
                      (o) => DropdownMenuItem<int>(
                        value: o.id,
                        child: Text(o.label),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _organizationId = v ?? 0),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: widget.roles.any((r) => r.key == _role) ? _role : null,
                decoration: const InputDecoration(labelText: 'Role'),
                items: widget.roles
                    .map(
                      (r) => DropdownMenuItem<String>(
                        value: r.key,
                        child: Text(r.label),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _role = v ?? ''),
              ),
              if (selectedRole != null && selectedRole.description.isNotEmpty) ...[
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    selectedRole.description,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF4B5563),
                    ),
                  ),
                ),
              ],
              if (_isNew) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordCtrl,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    labelText: 'Temporary password',
                    helperText:
                        'Give this to them in person. They will be asked to '
                        'change it the first time they sign in.',
                    helperMaxLines: 3,
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure ? Icons.visibility_off : Icons.visibility,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
              ] else ...[
                const SizedBox(height: 14),
                const Text(
                  'To change this person\'s password, use "Set new password" '
                  'from the row menu. Passwords are never shown — the system '
                  'stores only a one-way hash of them.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
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
          child: Text(_isNew ? 'Create user' : 'Save'),
        ),
      ],
    );
  }
}
