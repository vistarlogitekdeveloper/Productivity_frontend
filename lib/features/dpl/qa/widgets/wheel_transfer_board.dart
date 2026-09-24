import 'package:flutter/material.dart';

import '../../core/design/dpl_theme.dart';
import '../../models/dpl_pallet.dart';
import '../../models/dpl_spd.dart';

/// Two pallets side by side with their wheels, draggable between them.
///
/// WHY DRAG AND DROP AT ALL. The automatic merge takes the oldest wheels to
/// fill a pallet, which is the right default and the wrong answer whenever the
/// operator can see something the system cannot — a scuffed wheel to keep
/// back, a serial a customer asked for, two wheels that must ship together.
/// This hands them the decision.
///
/// EVERY DRAG HAS A TAP EQUIVALENT, and that is not a nicety. This is used on a
/// tablet on a shop floor by someone wearing gloves, often one-handed while the
/// other hand steadies a wheel. Drag is the pleasant path; the arrow button on
/// each row is the one that works when dragging does not.
class WheelTransferBoard extends StatelessWidget {
  const WheelTransferBoard({
    super.key,
    required this.left,
    required this.right,
    required this.assignment,
    required this.onMove,
    this.enabled = true,
  });

  final DplPalletWheels left;
  final DplPalletWheels right;

  /// sticker id -> the pallet id it is currently assigned to. Starts as where
  /// the wheels actually are and diverges as the operator drags.
  final Map<int, int> assignment;

  final void Function(int stickerId, int toPalletId) onMove;
  final bool enabled;

  List<DplWheel> _wheelsFor(int palletId) {
    final all = [...left.sellable, ...right.sellable];
    return all.where((w) => assignment[w.id] == palletId).toList();
  }

  @override
  Widget build(BuildContext context) {
    final a = left.pallet;
    final b = right.pallet;

    return LayoutBuilder(
      builder: (context, box) {
        // Side by side only when each column can still show a serial without
        // wrapping. Below that they stack, because two cramped columns are
        // harder to drag between than two full-width ones.
        final sideBySide = box.maxWidth >= 560;
        final columns = [
          _column(context, a, _wheelsFor(a.id), b.id),
          _column(context, b, _wheelsFor(b.id), a.id),
        ];

        if (!sideBySide) {
          return Column(
            children: [
              columns[0],
              const SizedBox(height: 10),
              columns[1],
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: columns[0]),
            const SizedBox(width: 10),
            Expanded(child: columns[1]),
          ],
        );
      },
    );
  }

  Widget _column(
    BuildContext context,
    DplPallet pallet,
    List<DplWheel> wheels,
    int otherPalletId,
  ) {
    final standard = pallet.standardQty ?? 0;
    final over = standard > 0 && wheels.length > standard;
    final full = standard > 0 && wheels.length == standard;

    return DragTarget<int>(
      onWillAcceptWithDetails: (d) =>
          enabled && assignment[d.data] != pallet.id,
      onAcceptWithDetails: (d) => onMove(d.data, pallet.id),
      builder: (context, candidate, _) {
        final hovering = candidate.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: hovering ? DplColors.primaryTint : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: over
                  ? DplColors.error
                  : hovering
                      ? DplColors.primary
                      : const Color(0xFFE2EAF6),
              width: hovering || over ? 1.6 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      pallet.palletNo,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  Text(
                    standard > 0
                        ? '${wheels.length} / $standard'
                        : '${wheels.length}',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      color: over
                          ? DplColors.error
                          : full
                              ? DplColors.success
                              : DplColors.textPrimary,
                    ),
                  ),
                ],
              ),
              if (over)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'Too many — a full pallet is $standard.',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: DplColors.error,
                    ),
                  ),
                )
              else if (wheels.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Text(
                    'Empty — this pallet stops existing.',
                    style: TextStyle(fontSize: 11.5, color: Color(0xFF6B7280)),
                  ),
                ),
              const SizedBox(height: 8),
              if (wheels.isEmpty)
                Container(
                  height: 56,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: const Color(0xFFD5DCE6),
                      style: BorderStyle.solid,
                    ),
                  ),
                  child: const Text(
                    'Drop wheels here',
                    style: TextStyle(fontSize: 12, color: Color(0xFF9AA5B4)),
                  ),
                )
              else
                for (final w in wheels)
                  _wheelTile(context, w, pallet.id, otherPalletId),
            ],
          ),
        );
      },
    );
  }

  Widget _wheelTile(
    BuildContext context,
    DplWheel w,
    int here,
    int there,
  ) {
    final tile = Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9FC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE2EAF6)),
      ),
      child: Row(
        children: [
          const Icon(Icons.drag_indicator, size: 16, color: Color(0xFF9AA5B4)),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  w.serialNo,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                if (w.shiftCode.isNotEmpty || w.machineName.isNotEmpty)
                  Text(
                    [
                      if (w.shiftCode.isNotEmpty) 'Shift ${w.shiftCode}',
                      if (w.machineName.isNotEmpty) w.machineName,
                    ].join(' · '),
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF6B7280),
                    ),
                  ),
              ],
            ),
          ),
          // The tap equivalent. Gloves and drag gestures do not get along, and
          // an operator who cannot move a wheel has no way round it.
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            tooltip: 'Move to the other pallet',
            icon: const Icon(Icons.swap_horiz, size: 18),
            onPressed: enabled ? () => onMove(w.id, there) : null,
          ),
        ],
      ),
    );

    if (!enabled) return tile;

    return Draggable<int>(
      data: w.id,
      feedback: Material(
        color: Colors.transparent,
        child: Opacity(
          opacity: 0.9,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: DplColors.primary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                w.serialNo,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: tile),
      child: tile,
    );
  }
}
