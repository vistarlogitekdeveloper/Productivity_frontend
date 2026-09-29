import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_permissions_provider.dart';
import '../../core/widgets/dpl_card.dart';
import '../../qa/screens/dpl_qr_scan_sheet.dart';
import '../auditor_shell.dart' show startAuditFor;

/// Where an audit starts: scan the pallet label in front of you.
///
/// The field is the primary route and stays focused, so a hardware trigger
/// lands in it without anyone tapping anything. The camera is behind a button
/// and never opens by itself — an auditor with a ring scanner does not want a
/// viewfinder appearing over the screen, and the camera is a permission a
/// plant issuing scanners can revoke.
class DplAuditScanScreen extends ConsumerStatefulWidget {
  const DplAuditScanScreen({super.key, this.showAppBar = true});

  final bool showAppBar;

  @override
  ConsumerState<DplAuditScanScreen> createState() => _DplAuditScanScreenState();
}

class _DplAuditScanScreenState extends ConsumerState<DplAuditScanScreen> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _start(String code) async {
    final value = code.trim();
    _ctrl.clear();
    _focus.requestFocus();
    if (value.isEmpty || _busy) return;

    setState(() => _busy = true);
    await startAuditFor(context, ref, code: value);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _camera() async {
    final code = await DplQrScanSheet.open(
      context,
      expecting: 'Scan the pallet label',
    );
    if (code == null || !mounted) return;
    await _start(code);
  }

  @override
  Widget build(BuildContext context) {
    final canCamera =
        ref.watch(dplPermissionsProvider).can(DplPermission.palletScanCamera);

    final body = ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
      children: [
        DplCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Scan a pallet to check it',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
              const SizedBox(height: 4),
              Text(
                'Then scan every wheel on it. The pallet passes when what you '
                'have in your hands is exactly what the system says is on it.',
                style: TextStyle(fontSize: 12.5, color: DplColors.textSecondary),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _ctrl,
                focusNode: _focus,
                enabled: !_busy,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'Pallet label',
                  isDense: true,
                ),
                onSubmitted: _start,
              ),
              const SizedBox(height: 12),
              if (canCamera)
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _camera,
                    icon: const Icon(Icons.qr_code_scanner, size: 18),
                    label: const Text('Use the camera'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                    ),
                  ),
                ),
              if (_busy) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(minHeight: 2),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        DplCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.info_outline, size: 18, color: DplColors.textSecondary),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'A pallet still being packed cannot be audited',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'It has no number and no printed label yet, and what is on it '
                'changes while you count. Audit it once it has been closed.',
                style: TextStyle(fontSize: 12, color: DplColors.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );

    if (!widget.showAppBar) return body;
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: AppBar(title: const Text('Audit a pallet')),
      body: body,
    );
  }
}
