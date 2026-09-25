import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_wheel_trolley.dart';

/// Which cart, when there is more than one.
///
/// Never shown for the common case. A plant with no cart gets its first one
/// created by the server on the first park, and a plant with exactly one never
/// has to say which — asking would be a tap for a question with one answer.
/// This exists for the plant that runs two lines into two carts, and for the
/// moment somebody needs a second one.
class TrolleyPickerSheet extends ConsumerStatefulWidget {
  final List<DplWheelTrolley> trolleys;

  /// Shown above the list. The reason they are being asked differs: parking a
  /// wheel and merging from a cart are different questions.
  final String prompt;

  const TrolleyPickerSheet({
    super.key,
    required this.trolleys,
    this.prompt = 'Which trolley?',
  });

  /// Returns the chosen cart, or null if dismissed.
  static Future<DplWheelTrolley?> show(
    BuildContext context, {
    required List<DplWheelTrolley> trolleys,
    String prompt = 'Which trolley?',
  }) {
    return showModalBottomSheet<DplWheelTrolley>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => TrolleyPickerSheet(trolleys: trolleys, prompt: prompt),
    );
  }

  @override
  ConsumerState<TrolleyPickerSheet> createState() => _TrolleyPickerSheetState();
}

class _TrolleyPickerSheetState extends ConsumerState<TrolleyPickerSheet> {
  bool _busy = false;

  Future<void> _create() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NameTrolleyDialog(),
    );
    if (name == null || !mounted) return;

    setState(() => _busy = true);
    final res = await ref.read(dplApiServiceProvider).createTrolley(name: name);
    if (!mounted) return;
    setState(() => _busy = false);

    if (res.isError || res.data == null) {
      DplSnacks.error(context, res.error ?? 'Could not create the trolley.');
      return;
    }
    Navigator.of(context).pop(res.data);
  }

  @override
  Widget build(BuildContext context) {
    final active =
        widget.trolleys.where((t) => t.isActive).toList(growable: false);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.prompt,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.45,
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: active.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final t = active[i];
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      t.label,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    subtitle: Text(
                      t.isEmpty
                          ? 'Nothing on it'
                          : '${t.wheelQty} wheel${t.wheelQty == 1 ? '' : 's'} on it',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: DplColors.textSecondary,
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_right, size: 20),
                    onTap: _busy ? null : () => Navigator.of(context).pop(t),
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _create,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New trolley'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A cart is a physical object somebody labels, so it gets a name it can be
/// called by. Optional: the number is the identity, and refusing to create one
/// over a nickname would be pedantry at the moment an operator needs somewhere
/// to put a wheel.
class _NameTrolleyDialog extends StatefulWidget {
  const _NameTrolleyDialog();

  @override
  State<_NameTrolleyDialog> createState() => _NameTrolleyDialogState();
}

class _NameTrolleyDialogState extends State<_NameTrolleyDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New trolley'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        maxLength: 64,
        decoration: const InputDecoration(
          labelText: 'What is it called? (optional)',
          hintText: 'Line 3 cart',
          helperText: 'It gets a TR number either way — print that on it.',
          helperMaxLines: 2,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          // '' rather than null: null is the cancel signal and must not also
          // mean "created without a name".
          onPressed: () => Navigator.of(context).pop(_ctrl.text.trim()),
          child: const Text('Create'),
        ),
      ],
    );
  }
}
