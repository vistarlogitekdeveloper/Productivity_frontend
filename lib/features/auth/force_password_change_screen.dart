import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/shimmer_skeleton.dart';
import '../dpl/core/dpl_api_service.dart';
import '../dpl/core/dpl_password_gate_provider.dart';
import '../dpl/core/dpl_permissions_provider.dart';
import 'auth_provider.dart';

/// Pins an account to a password change before it can reach anything else.
///
/// Shown when the backend reports `must_change_password` — an administrator
/// created this account, or reset its password, so the value that got the user
/// in is one somebody else knows. That includes the built-in bootstrap
/// password, which is a constant in the repository.
///
/// A full screen rather than a dialog on purpose. A dialog can be dismissed,
/// popped by the system back gesture, or simply out-lived by a page refresh,
/// and every one of those leaves the account working on the old password. The
/// only ways out of here are changing the password or signing out.
class ForcePasswordChangeScreen extends ConsumerStatefulWidget {
  const ForcePasswordChangeScreen({super.key});

  @override
  ConsumerState<ForcePasswordChangeScreen> createState() =>
      _ForcePasswordChangeScreenState();
}

class _ForcePasswordChangeScreenState
    extends ConsumerState<ForcePasswordChangeScreen> {
  final _formKey = GlobalKey<FormState>();
  final _oldCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool _oldObscure = true;
  bool _newObscure = true;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _oldCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  String? _validateNew(String? value) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return 'Choose a new password.';
    if (text.length < 8) return 'Use at least 8 characters.';
    if (text.length > 128) return 'Use at most 128 characters.';
    if (text == _oldCtrl.text.trim()) {
      return 'The new password must be different from the one you were given.';
    }
    return null;
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _submitting = true;
      _error = null;
    });

    final res = await ref
        .read(dplApiServiceProvider)
        .changePassword(_oldCtrl.text.trim(), _newCtrl.text.trim());

    if (!mounted) return;

    if (res.isError) {
      setState(() {
        _submitting = false;
        _error = (res.code ?? '').toUpperCase() == 'OLD_PASSWORD_MISMATCH'
            ? 'That is not the password you were given. Check it with whoever '
                'set up your account.'
            : (res.error ?? 'Could not change the password. Please try again.');
      });
      return;
    }

    // The server has cleared must_change_password; mirror it locally so the
    // router lets go, and re-read the permission list because this is also the
    // first point at which a freshly created account has one.
    await ref.read(dplMustChangePasswordProvider.notifier).set(false);
    await ref.read(dplPermissionsProvider.notifier).refresh();

    if (!mounted) return;
    setState(() => _submitting = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Password changed. Welcome in.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authControllerProvider).asData?.value;

    return Scaffold(
      backgroundColor: const Color(0xFFF8F7FB),
      // No AppBar back button, and PopScope stops the hardware/system back
      // gesture: there is nowhere to go back TO that this screen is not
      // guarding.
      body: PopScope(
        canPop: false,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                  side: const BorderSide(color: Color(0xFFE2EAF6)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.lock_reset_rounded,
                          size: 34,
                          color: Color(0xFF6B1F8C),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Choose your own password',
                          style: TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          user == null
                              ? 'The password you signed in with was set by '
                                  'somebody else. Pick your own before you '
                                  'continue.'
                              : 'The password you signed in with was set by '
                                  'somebody else, so it is not private to you. '
                                  'Pick your own before you continue.',
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF5D6A7A),
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 18),
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
                          const SizedBox(height: 14),
                        ],
                        TextFormField(
                          controller: _oldCtrl,
                          obscureText: _oldObscure,
                          enabled: !_submitting,
                          decoration: InputDecoration(
                            labelText: 'The password you were given',
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: IconButton(
                              onPressed: () =>
                                  setState(() => _oldObscure = !_oldObscure),
                              icon: Icon(
                                _oldObscure
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                              ),
                            ),
                          ),
                          validator: (v) => (v ?? '').trim().isEmpty
                              ? 'Enter the password you signed in with.'
                              : null,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _newCtrl,
                          obscureText: _newObscure,
                          enabled: !_submitting,
                          decoration: InputDecoration(
                            labelText: 'Your new password',
                            helperText: 'At least 8 characters.',
                            prefixIcon: const Icon(Icons.lock_reset_outlined),
                            suffixIcon: IconButton(
                              onPressed: () =>
                                  setState(() => _newObscure = !_newObscure),
                              icon: Icon(
                                _newObscure
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                              ),
                            ),
                          ),
                          validator: _validateNew,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _confirmCtrl,
                          obscureText: _newObscure,
                          enabled: !_submitting,
                          decoration: const InputDecoration(
                            labelText: 'Type it again',
                            prefixIcon: Icon(Icons.verified_user_outlined),
                          ),
                          validator: (v) =>
                              (v ?? '').trim() != _newCtrl.text.trim()
                                  ? 'The two passwords do not match.'
                                  : null,
                          onFieldSubmitted: (_) => _submitting ? null : _submit(),
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: _submitting ? null : _submit,
                            child: _submitting
                                ? const SizedBox(
                                    height: 18,
                                    child: Center(
                                      child: ShimmerButtonDots(
                                        size: 6,
                                        spacing: 3,
                                      ),
                                    ),
                                  )
                                : const Text('Set my password'),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Center(
                          child: TextButton(
                            onPressed: _submitting
                                ? null
                                : () => ref
                                    .read(authControllerProvider.notifier)
                                    .logout(),
                            child: const Text('Sign out instead'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
