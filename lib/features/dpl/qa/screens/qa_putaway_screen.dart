import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_permissions_provider.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_location.dart';
import '../../models/dpl_pallet.dart';
import '../widgets/location_picker_sheet.dart';
import 'dpl_qr_scan_sheet.dart';

/// Putting a closed pallet on a rack — Maxion SSR Module 6, Warehouse Bin
/// Putaway.
///
/// THE SHAPE OF THIS SCREEN IS TAKEN FROM MAXION'S OWN APP, not invented. Their
/// `putaway_screen.dart` scans the PALLET first and then fills in a recommended
/// zone and a suggested bay — half pallets to the dedicated half-pallet bays,
/// full ones to the main finished-goods racks — and lets the operator override
/// it. Scanning the pallet first is what makes the suggestion possible at all:
/// until you know which pallet it is, there is nothing to route.
///
/// The suggestion is a suggestion. A bay that cannot be refused becomes a lie
/// the first time a rack is blocked by a forklift, and an operator who has been
/// lied to once stops reading the field.
///
/// Why this matters downstream: the rack recorded here is what a picking list
/// reads back later. A pallet with no location is a pallet somebody has to walk
/// the warehouse to find.
class QaPutawayScreen extends ConsumerStatefulWidget {
  const QaPutawayScreen({super.key, this.showAppBar = true, this.initialCode});

  final bool showAppBar;

  /// Pre-filled when the operator arrives straight from closing a pallet, so
  /// they do not scan a label they are already holding.
  final String? initialCode;

  @override
  ConsumerState<QaPutawayScreen> createState() => _QaPutawayScreenState();
}

class _QaPutawayScreenState extends ConsumerState<QaPutawayScreen> {
  final _scanCtrl = TextEditingController();
  final _scanFocus = FocusNode();
  final _remarksCtrl = TextEditingController();

  bool _busy = false;
  DplPalletResolution? _found;
  DplLocation? _chosen;

  /// The suggested bay, held separately so the screen can say "you changed it"
  /// — an override is a decision worth showing back, not hiding.
  int? _suggestedId;

  @override
  void initState() {
    super.initState();
    final code = widget.initialCode?.trim() ?? '';
    if (code.isNotEmpty) {
      _scanCtrl.text = code;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _resolve(code);
      });
    }
  }

  @override
  void dispose() {
    _scanCtrl.dispose();
    _scanFocus.dispose();
    _remarksCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
      children: [
        _scanCard(),
        if (_found != null) ...[
          const SizedBox(height: 12),
          _palletCard(_found!),
          const SizedBox(height: 12),
          _rackCard(_found!),
        ],
      ],
    );

    if (!widget.showAppBar) return body;
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: AppBar(title: const Text('Put a pallet away')),
      body: body,
    );
  }

  // -------------------------------------------------------------------------
  // Scan
  // -------------------------------------------------------------------------

  Widget _scanCard() {
    final canCamera =
        ref.watch(dplPermissionsProvider).can(DplPermission.palletScanCamera);

    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Scan the pallet label',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _scanCtrl,
            focusNode: _scanFocus,
            enabled: !_busy,
            // NOT autofocused: the handheld delivers here by position, and a
            // soft keyboard on entry is pure obstruction on a rugged device.
            textInputAction: TextInputAction.done,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              hintText: 'Scan, or type the pallet number',
              prefixIcon: Icon(Icons.qr_code_scanner_rounded),
              isDense: true,
              // Names the fallback, because the number is printed in plain text
              // under the QR precisely so a scuffed label can still be used.
              helperText:
                  'The pallet number is printed under the code, so a damaged '
                  'label can be keyed in by hand.',
              helperMaxLines: 3,
            ),
            onSubmitted: _busy ? null : _resolve,
          ),
          if (canCamera) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _scanWithCamera,
                icon: const Icon(Icons.photo_camera_outlined, size: 18),
                label: const Text('Scan with the camera'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _scanWithCamera() async {
    final code = await DplQrScanSheet.open(context, kind: DplScanKind.pallet);
    if (code == null || !mounted) return;
    _scanCtrl.text = code;
    await _resolve(code);
  }

  Future<void> _resolve(String raw) async {
    final code = raw.trim();
    if (code.isEmpty) return;

    setState(() {
      _busy = true;
      _found = null;
      _chosen = null;
      _suggestedId = null;
    });

    final res =
        await ref.read(dplApiServiceProvider).resolvePalletForPutaway(code);
    if (!mounted) return;
    setState(() => _busy = false);

    if (res.isError || res.data == null) {
      // Verbatim: the server distinguishes "no pallet here is numbered X" from
      // "that is a wheel label, not a pallet label", and those need different
      // reactions from the operator.
      DplSnacks.error(context, res.error ?? 'Could not read that pallet label.');
      _scanCtrl.selection =
          TextSelection(baseOffset: 0, extentOffset: _scanCtrl.text.length);
      _scanFocus.requestFocus();
      return;
    }

    final found = res.data!;
    if (found.wasRenamed) {
      DplSnacks.warning(
        context,
        '${found.renamedFrom} was merged and is now ${found.pallet.palletNo}. '
        'That label is out of date — reprint it.',
      );
    }
    setState(() {
      _found = found;
      _suggestedId = found.suggestion?.id;
      // Pre-select the suggestion so the common case is one press. The picker
      // is still right there for the rack that is actually reachable today.
      _chosen = found.suggestion == null
          ? null
          : DplLocation(
              id: found.suggestion!.id,
              code: found.suggestion!.code,
              name: found.suggestion!.name,
              zone: found.suggestion!.zone,
              freeQty: found.suggestion!.freeQty,
            );
    });
  }

  // -------------------------------------------------------------------------
  // What was scanned
  // -------------------------------------------------------------------------

  Widget _palletCard(DplPalletResolution r) {
    final p = r.pallet;
    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  p.palletNo,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: DplColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  p.typeLabel.toUpperCase(),
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    color: DplColors.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${p.customerPartNo}'
            '${p.partDescription.isEmpty ? '' : ' · ${p.partDescription}'}',
            style: TextStyle(fontSize: 12.5, color: DplColors.textSecondary),
          ),
          const SizedBox(height: 6),
          Text(
            '${p.qty} wheels on this pallet',
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
          if (r.isMove) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: DplColors.warningBg,
                borderRadius: BorderRadius.circular(8),
              ),
              // Saying this out loud matters. Somebody put this pallet
              // somewhere on purpose, and relocating it silently is how stock
              // goes missing from the rack a picking list still points at.
              child: Text(
                'Already stored at ${r.current!.code}. Saving a different rack '
                'MOVES it, and frees the space it is using now.',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: VistarPalette.warnInk,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Where it goes
  // -------------------------------------------------------------------------

  Widget _rackCard(DplPalletResolution r) {
    final suggestion = r.suggestion;
    final chosen = _chosen;
    final overridden =
        chosen != null && _suggestedId != null && chosen.id != _suggestedId;

    return DplCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Rack',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          const SizedBox(height: 6),
          if (suggestion != null)
            Text(
              // The REASON, not just the code. A suggestion an operator does
              // not understand is one they override at random.
              suggestion.reason,
              style: TextStyle(fontSize: 12, color: DplColors.textSecondary),
            )
          else
            Text(
              'No rack could be suggested — choose one.',
              style: TextStyle(fontSize: 12, color: DplColors.textSecondary),
            ),
          const SizedBox(height: 12),
          InkWell(
            onTap: _busy ? null : () => _pickRack(r),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(
                  color: chosen == null
                      ? VistarPalette.line
                      : DplColors.primary,
                  width: chosen == null ? 1 : 1.5,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.warehouse_outlined,
                    size: 20,
                    color: chosen == null
                        ? DplColors.textTertiary
                        : DplColors.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          chosen?.code ?? 'Choose a rack',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                            color: chosen == null
                                ? DplColors.textTertiary
                                : DplColors.textPrimary,
                          ),
                        ),
                        if (chosen != null)
                          Text(
                            '${chosen.zone.isEmpty ? '' : '${chosen.zone} · '}'
                            'room for ${chosen.freeQty}',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: DplColors.textSecondary,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 20),
                ],
              ),
            ),
          ),
          if (overridden) ...[
            const SizedBox(height: 8),
            Text(
              'Changed from the suggested ${suggestion?.code ?? ''}.',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: DplColors.warning,
              ),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _remarksCtrl,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: 'Note (optional)',
              isDense: true,
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: (_busy || chosen == null) ? null : () => _save(r),
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_rounded, size: 18),
              label: Text(
                _busy
                    ? 'Saving…'
                    : r.isMove
                        ? 'Move it here'
                        : 'Store it here',
              ),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickRack(DplPalletResolution r) async {
    final picked = await LocationPickerSheet.show(
      context,
      // Capacity is counted in PIECES, so a pallet takes its whole wheel count
      // — not one slot. Passing anything else makes the picker offer racks
      // that the server will then refuse.
      requiredQty: r.pallet.qty,
      selectedLocationId: _chosen?.id,
      fromWarehouse: true,
    );
    if (picked == null || !mounted) return;
    setState(() => _chosen = picked);
  }

  Future<void> _save(DplPalletResolution r) async {
    final chosen = _chosen;
    if (chosen == null) return;

    setState(() => _busy = true);
    final res = await ref.read(dplApiServiceProvider).putPalletAway(
          palletId: r.pallet.id,
          locationId: chosen.id,
          remarks: _remarksCtrl.text,
        );
    if (!mounted) return;
    setState(() => _busy = false);

    if (res.isError) {
      // LOCATION_FULL, ALREADY_ASSIGNED and PALLET_NOT_CLOSED each name a
      // different remedy and the server words them precisely, so they are
      // shown as written rather than flattened into "could not save".
      DplSnacks.error(context, res.error ?? 'Failed to record the location.');
      return;
    }

    DplSnacks.success(
      context,
      '${r.pallet.palletNo} is at ${chosen.code}.',
    );

    // Straight back to an empty scan field: this screen is worked in a loop,
    // one pallet after another, and leaving the last result on screen is how
    // the next pallet gets saved to the previous one's rack.
    setState(() {
      _found = null;
      _chosen = null;
      _suggestedId = null;
      _scanCtrl.clear();
      _remarksCtrl.clear();
    });
    _scanFocus.requestFocus();
  }
}
