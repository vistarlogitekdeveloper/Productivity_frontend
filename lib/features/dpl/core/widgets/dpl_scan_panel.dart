import 'package:flutter/material.dart';

import '../design/dpl_theme.dart';
import 'dpl_card.dart';

/// The one way every scanning screen asks for a scan.
///
/// Before this, the Pallet tab had a big "Scan" button and every other tab a
/// bare text field with a grey camera button under it — four screens doing
/// the same job four ways, which on a phone read as four different apps.
///
/// Layout, top to bottom:
///   * an optional step marker ("STEP 2 OF 3") and the title, with an
///     optional action on the right (e.g. "Start over");
///   * one line saying what to do;
///   * the big primary button, when the camera is allowed — the obvious
///     thing to press on a phone;
///   * the "or type it" field, which is also where a hardware scanner types,
///     with a Go button so a touch user does not need the keyboard's enter
///     key.
///
/// NOT autofocused. A handheld trigger needs no cursor (HardwareScanScope
/// delivers by position), and autofocus raises the soft keyboard over half a
/// phone screen the moment the tab opens.
class DplScanPanel extends StatelessWidget {
  const DplScanPanel({
    super.key,
    required this.title,
    required this.controller,
    required this.onSubmitted,
    this.step,
    this.subtitle,
    this.cameraLabel = 'Scan',
    this.onCamera,
    this.focusNode,
    this.hint = 'or type the number',
    this.enabled = true,
    this.busy = false,
    this.trailing,
    this.footer = const <Widget>[],
    this.capitalize = true,
  });

  /// e.g. "Step 1 of 3". Shown above the title when given.
  final String? step;
  final String title;
  final String? subtitle;

  /// The big button. Hidden when [onCamera] is null — a plant that has not
  /// switched the camera on scans with the hardware scanner into the field.
  final String cameraLabel;
  final VoidCallback? onCamera;

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hint;
  final ValueChanged<String> onSubmitted;

  final bool enabled;
  final bool busy;

  /// An action beside the title, e.g. "Start over".
  final Widget? trailing;

  /// Extra controls under the field, e.g. "Or fill it from a trolley".
  final List<Widget> footer;

  /// Capitals on the soft keyboard. Right for pallet numbers; OFF for wheel
  /// labels, because the plant's old Maxion labels are mixed case
  /// (`06Oct26`) and are matched exactly.
  final bool capitalize;

  void _submit() {
    final v = controller.text;
    if (v.trim().isEmpty) return;
    onSubmitted(v);
  }

  @override
  Widget build(BuildContext context) {
    final live = enabled && !busy;
    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (step != null) ...[
            Text(
              step!.toUpperCase(),
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
                color: DplColors.primary,
              ),
            ),
            const SizedBox(height: 4),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                ),
              ),
              ?trailing,
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.35,
                color: DplColors.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: 14),
          if (onCamera != null) ...[
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: live ? onCamera : null,
                icon: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.qr_code_scanner_rounded, size: 20),
                label: Text(cameraLabel),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  textStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
          TextField(
            controller: controller,
            focusNode: focusNode,
            enabled: live,
            textInputAction: TextInputAction.go,
            textCapitalization:
                capitalize ? TextCapitalization.characters : TextCapitalization.none,
            decoration: InputDecoration(
              hintText: onCamera != null ? '…$hint' : _capitalised(hint),
              prefixIcon: Icon(
                onCamera != null
                    ? Icons.keyboard_alt_outlined
                    : Icons.qr_code_scanner_rounded,
              ),
              suffixIcon: IconButton(
                tooltip: 'Go',
                icon: const Icon(Icons.arrow_forward_rounded),
                onPressed: live ? _submit : null,
              ),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: live ? (_) => _submit() : null,
          ),
          if (footer.isNotEmpty) ...[
            const SizedBox(height: 10),
            ...footer,
          ],
        ],
      ),
    );
  }

  static String _capitalised(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
