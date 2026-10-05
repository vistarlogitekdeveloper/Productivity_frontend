import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../core/dpl_permissions_provider.dart';
import '../../core/widgets/dpl_card.dart';
import '../services/sticker_label_format.dart';

/// "QR sticker" or "PDF417 barcode", for an organization that prints both.
///
/// Renders nothing unless the organization holds `labels.print_pdf417`, so
/// every other plant's print screen is exactly what it was.
class LabelFormatPicker extends ConsumerWidget {
  final bool enabled;

  const LabelFormatPicker({super.key, this.enabled = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allowed =
        ref.watch(dplPermissionsProvider).can(DplPermission.labelsPrintPdf417);
    if (!allowed) return const SizedBox.shrink();

    final format = ref.watch(effectiveStickerLabelFormatProvider);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DplCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Label format',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<StickerLabelFormat>(
                segments: [
                  for (final f in StickerLabelFormat.values)
                    ButtonSegment(
                      value: f,
                      icon: Icon(
                        f == StickerLabelFormat.qr
                            ? Icons.qr_code_2_rounded
                            : Icons.view_week_rounded,
                        size: 18,
                      ),
                      label: Text(f.label),
                    ),
                ],
                selected: {format},
                showSelectedIcon: false,
                onSelectionChanged: enabled
                    ? (s) => ref
                        .read(stickerLabelFormatChoiceProvider.notifier)
                        .select(s.first)
                    : null,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              // The stock is the thing an operator gets wrong: the printer
              // does not know which roll is loaded, and a 75 mm label sent to
              // a 50 mm roll prints across two stickers.
              'Load ${format.stock} labels in the printer. Same serials '
              'either way — only the layout changes.',
              style: TextStyle(
                color: VistarPalette.txt2,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
