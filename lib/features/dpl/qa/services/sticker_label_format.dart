import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;

import '../../core/dpl_permissions_provider.dart';
import '../../models/dpl_part.dart';
import '../../models/dpl_part_sticker.dart';
import 'part_sticker_label_pdf.dart';
import 'pdf417_label_pdf.dart';

/// Which artwork the issued serials are printed as.
///
/// Both print the SAME server-issued serials and their symbols hold the same
/// payload, so the choice never changes what the system records — only what
/// comes out of the printer, and on which stock.
enum StickerLabelFormat {
  /// The 50 x 25 mm QR sticker every plant prints today.
  qr('QR sticker', '50 × 25 mm'),

  /// The 75 x 25 mm Antolin/TML PDF417 label (`labels.print_pdf417`).
  // 'PDF417', not 'PDF417 barcode': the segment wrapped onto two lines on a
  // phone, and the barcode icon beside it already says what it is.
  pdf417('PDF417', '75 × 25 mm');

  const StickerLabelFormat(this.label, this.stock);

  final String label;
  final String stock;

  /// The die-cut page box for this layout.
  PdfPageFormat get rollFormat => switch (this) {
        StickerLabelFormat.qr => PartStickerLabelPdf.rollFormat,
        StickerLabelFormat.pdf417 => Pdf417LabelPdf.rollFormat,
      };

  /// One page per sticker, at this layout's die-cut size.
  Future<Uint8List> buildRoll(
    List<DplPartSticker> stickers, {
    required DplPart part,
  }) =>
      switch (this) {
        StickerLabelFormat.qr => PartStickerLabelPdf.buildRoll(stickers),
        StickerLabelFormat.pdf417 =>
          Pdf417LabelPdf.buildRoll(stickers, part: part),
      };
}

/// The operator's last choice, kept for the session.
///
/// An operator prints part after part from the plan, re-entering the print
/// screen each time; asking them to pick the barcode layout again on every
/// part is how the wrong stock ends up printed on.
class StickerLabelFormatController extends Notifier<StickerLabelFormat> {
  @override
  StickerLabelFormat build() => StickerLabelFormat.qr;

  void select(StickerLabelFormat format) => state = format;
}

final stickerLabelFormatChoiceProvider =
    NotifierProvider<StickerLabelFormatController, StickerLabelFormat>(
  StickerLabelFormatController.new,
);

/// The layout that will actually print: the operator's choice, but only
/// while this organization holds `labels.print_pdf417`.
///
/// If an administrator switches the PDF417 label off, a choice remembered
/// from earlier in the session must fall back to the QR sticker rather than
/// keep printing a layout the plant no longer uses.
final effectiveStickerLabelFormatProvider = Provider<StickerLabelFormat>((ref) {
  final allowed =
      ref.watch(dplPermissionsProvider).can(DplPermission.labelsPrintPdf417);
  if (!allowed) return StickerLabelFormat.qr;
  return ref.watch(stickerLabelFormatChoiceProvider);
});
