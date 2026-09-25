import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_permissions_provider.dart';
import '../../models/dpl_pallet.dart';

/// What the operator chose to do with the wheel they just scanned.
enum DplStartKind {
  /// Bring a stored half pallet back and fill it. Closes as PM.
  productionMerge,

  /// A fresh pallet for this item — the original flow.
  newPallet,

  /// Park the wheel on the trolley. No pallet is opened at all.
  trolley,
}

/// The operator's answer, plus the half pallet they picked when it needs one.
class DplStartDecision {
  final DplStartKind kind;

  /// The stored half pallet to bring back. Only set for
  /// [DplStartKind.productionMerge], and never null there.
  final DplPallet? half;

  const DplStartDecision(this.kind, {this.half});
}

/// Asked once, after the first wheel is scanned and before anything is opened.
///
/// Until now the scan went straight to a new pallet, which is right for a plant
/// that runs one item to a full pallet and moves on. It is wrong for Maxion:
/// there, a changeover mid-run leaves a part-filled pallet behind every time,
/// and the SSR names ageing half pallets as the problem the system exists to
/// solve. So the moment the item is known — and it IS known, the wheel's label
/// says so — the operator is shown what already exists for it and asked what
/// this wheel is joining.
///
/// The question is asked HERE, before the pallet is created, on purpose. After
/// a pallet exists the only way back is to discard it, and a discard that
/// releases wheels is a worse thing to put in an operator's way than a
/// question.
///
/// Returns null when the operator backs out — the wheel is then still unpacked
/// and nothing has been written.
class StartPalletChoiceSheet extends ConsumerStatefulWidget {
  /// The item the scanned wheel resolved to.
  final int partId;
  final String customerPartNo;
  final String partDescription;

  /// The cart this wheel is already parked on, if any.
  ///
  /// Not a refusal — the operator is holding it, so it has already left the
  /// cart physically. But packing it draws that cart down by one, and somebody
  /// else may be planning a merge from it, so it is said out loud here rather
  /// than discovered afterwards.
  final String parkedOnTrolleyNo;

  const StartPalletChoiceSheet({
    super.key,
    required this.partId,
    required this.customerPartNo,
    required this.partDescription,
    this.parkedOnTrolleyNo = '',
  });

  static Future<DplStartDecision?> show(
    BuildContext context, {
    required int partId,
    required String customerPartNo,
    required String partDescription,
    String parkedOnTrolleyNo = '',
  }) {
    return showModalBottomSheet<DplStartDecision>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => StartPalletChoiceSheet(
        partId: partId,
        customerPartNo: customerPartNo,
        partDescription: partDescription,
        parkedOnTrolleyNo: parkedOnTrolleyNo,
      ),
    );
  }

  @override
  ConsumerState<StartPalletChoiceSheet> createState() =>
      _StartPalletChoiceSheetState();
}

class _StartPalletChoiceSheetState
    extends ConsumerState<StartPalletChoiceSheet> {
  /// Stored half pallets for THIS item only, oldest first.
  List<DplPallet> _halves = const [];
  bool _loading = true;
  String? _error;

  /// True once "Production merge" is tapped: the sheet swaps to the list
  /// rather than nesting a second sheet, because a handheld has no room for
  /// two and a nested dismiss is ambiguous.
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final res = await ref
        .read(dplApiServiceProvider)
        .getHalfPallets(partId: widget.partId);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (res.isError) {
        _error = res.error ?? 'Could not load stored half pallets.';
      } else {
        _halves = res.data ?? const <DplPallet>[];
      }
    });
  }

  void _answer(DplStartKind kind, {DplPallet? half}) {
    Navigator.of(context).pop(DplStartDecision(kind, half: half));
  }

  @override
  Widget build(BuildContext context) {
    final canTrolley =
        ref.watch(dplPermissionsProvider).can(DplPermission.palletTrolley);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(),
            const SizedBox(height: 14),
            if (_picking) ..._halfList() else ..._choices(canTrolley),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    final desc = widget.partDescription;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_picking)
          IconButton(
            icon: const Icon(Icons.arrow_back, size: 20),
            tooltip: 'Back',
            onPressed: () => setState(() => _picking = false),
          ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _picking ? 'Which half pallet?' : 'Where does this wheel go?',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 17,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                // The item is named, not assumed. It came off the label the
                // operator just scanned, and if the label resolved to the
                // wrong item this is the last moment anyone will notice
                // before a pallet's worth is packed under it.
                desc.isEmpty
                    ? widget.customerPartNo
                    : '${widget.customerPartNo} · $desc',
                // Not const: DplColors members are theme-aware getters, so
                // they resolve at build time, not compile time.
                style: TextStyle(fontSize: 12.5, color: DplColors.neutral),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // The three choices
  // -------------------------------------------------------------------------

  List<Widget> _choices(bool canTrolley) {
    return [
      if (widget.parkedOnTrolleyNo.isNotEmpty) ...[
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: DplColors.infoBg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            'This wheel is parked on ${widget.parkedOnTrolleyNo}. Packing it '
            'takes it off that trolley.',
            style: TextStyle(fontSize: 12, color: DplColors.info),
          ),
        ),
        const SizedBox(height: 10),
      ],
      if (_loading)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: LinearProgressIndicator(minHeight: 2),
        ),
      if (_error != null) ...[
        // The half pallet list failing must NOT block the sheet. Starting a
        // fresh pallet is always legal, and a pack point that cannot pack
        // because a list would not load is a worse outcome than one that
        // occasionally starts a pallet it could have topped up.
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: DplColors.warningBg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '$_error You can still start a new pallet.',
            style: TextStyle(fontSize: 12, color: DplColors.warning),
          ),
        ),
        const SizedBox(height: 10),
      ],

      // Offered FIRST, and only when there is something to offer. SSR §4:
      // fill a stored half pallet before starting a fresh one.
      if (_halves.isNotEmpty)
        _option(
          icon: Icons.merge_type_rounded,
          colour: DplColors.primary,
          title: 'Production merge',
          subtitle: _halves.length == 1
              ? 'One half pallet of this item is waiting. Bring it back and '
                  'fill it — it closes as PM.'
              : '${_halves.length} half pallets of this item are waiting. '
                  'Bring one back and fill it — it closes as PM.',
          badge: _oldestBadge(),
          onTap: () => setState(() => _picking = true),
        ),

      _option(
        icon: Icons.add_box_outlined,
        colour: DplColors.info,
        title: 'New pallet',
        subtitle: _halves.isEmpty
            ? 'Nothing is waiting for this item. Start a fresh pallet.'
            : 'Start a fresh pallet anyway and leave the stored ones alone.',
        onTap: () => _answer(DplStartKind.newPallet),
      ),

      // Not offered for a wheel that is ALREADY on a cart.
      //
      // Parking re-submits the same code, and the server answers
      // ALREADY_ON_THIS_TROLLEY — so the option could only ever produce a
      // refusal. The banner above already says where the wheel is; what is
      // left to decide is which pallet it goes on.
      if (canTrolley && widget.parkedOnTrolleyNo.isEmpty)
        _option(
          icon: Icons.shopping_cart_outlined,
          colour: DplColors.neutral,
          title: 'Park on the trolley',
          subtitle:
              'Hold this wheel loose instead of opening a pallet for it. '
              'They get merged into half pallets later.',
          onTap: () => _answer(DplStartKind.trolley),
        ),
    ];
  }

  /// "Oldest 23 days" — red once it has been sitting a week.
  ///
  /// The count alone gets skimmed. The AGE is the thing that decides whether
  /// this is a merge worth doing now.
  Widget? _oldestBadge() {
    final days = _halves
        .map((p) => p.ageDays ?? 0)
        .fold<int>(0, (a, b) => a > b ? a : b);
    if (days < 1) return null;
    final old = days >= 7;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: old ? DplColors.errorBg : DplColors.neutralBg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        'Oldest $days d',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: old ? DplColors.error : DplColors.neutral,
        ),
      ),
    );
  }

  Widget _option({
    required IconData icon,
    required Color colour,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Widget? badge,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: DplColors.divider),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 22, color: colour),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 14.5,
                            ),
                          ),
                        ),
                        ?badge,
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        color: DplColors.neutral,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Picking which half pallet
  // -------------------------------------------------------------------------

  List<Widget> _halfList() {
    return [
      Text(
        'Oldest first. The one at the top has been waiting longest.',
        style: TextStyle(fontSize: 12, color: DplColors.neutral),
      ),
      const SizedBox(height: 8),
      ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.45,
        ),
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: _halves.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final p = _halves[i];
            final old = (p.ageDays ?? 0) >= 7;
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                p.palletNo,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              subtitle: Text(
                '${p.countLabel} on it'
                '${p.ageDays != null ? ' · ${p.ageDays} days old' : ''}'
                '${p.locationCode.isNotEmpty ? ' · ${p.locationCode}' : ''}',
                style: TextStyle(
                  fontSize: 11.5,
                  color: old ? DplColors.error : DplColors.neutral,
                  fontWeight: old ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () =>
                  _answer(DplStartKind.productionMerge, half: p),
            );
          },
        ),
      ),
    ];
  }
}
