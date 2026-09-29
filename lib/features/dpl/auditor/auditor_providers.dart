import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/dpl_api_response.dart';
import '../core/dpl_api_service.dart';
import '../models/dpl_pallet.dart';
import '../models/dpl_pallet_audit.dart';

/// What the auditor is filtering the pallet register by.
///
/// Held as one object rather than a provider per field so the list refetches
/// once when several filters change together — a date range is two fields and
/// nobody wants two round trips for one gesture.
class DplAuditPalletFilter {
  /// `closed` by default. An open pallet has no number and no printed label,
  /// so there is nothing for the auditor to scan and its contents change under
  /// them while they count — the server refuses it, and offering it in the
  /// list would just be a trap.
  final String status;

  /// 'P' full, 'H' half, 'PM' production merge, or empty for all.
  final String palletType;

  final String shiftCode;

  /// Matches the pallet number or the part.
  final String search;

  /// `yyyy-MM-dd`, inclusive.
  final String from;
  final String to;

  const DplAuditPalletFilter({
    this.status = 'closed',
    this.palletType = '',
    this.shiftCode = '',
    this.search = '',
    this.from = '',
    this.to = '',
  });

  DplAuditPalletFilter copyWith({
    String? status,
    String? palletType,
    String? shiftCode,
    String? search,
    String? from,
    String? to,
  }) {
    return DplAuditPalletFilter(
      status: status ?? this.status,
      palletType: palletType ?? this.palletType,
      shiftCode: shiftCode ?? this.shiftCode,
      search: search ?? this.search,
      from: from ?? this.from,
      to: to ?? this.to,
    );
  }

  /// Everything except the default status, which is not really a filter the
  /// operator chose — it is where the screen starts.
  bool get hasAny =>
      palletType.isNotEmpty ||
      shiftCode.isNotEmpty ||
      search.trim().isNotEmpty ||
      from.isNotEmpty ||
      to.isNotEmpty ||
      status != 'closed';

  @override
  bool operator ==(Object other) =>
      other is DplAuditPalletFilter &&
      other.status == status &&
      other.palletType == palletType &&
      other.shiftCode == shiftCode &&
      other.search == search &&
      other.from == from &&
      other.to == to;

  @override
  int get hashCode =>
      Object.hash(status, palletType, shiftCode, search, from, to);
}

class DplAuditPalletFilterNotifier extends Notifier<DplAuditPalletFilter> {
  @override
  DplAuditPalletFilter build() => const DplAuditPalletFilter();

  void set(DplAuditPalletFilter next) => state = next;
  void clear() => state = const DplAuditPalletFilter();
}

final dplAuditPalletFilterProvider =
    NotifierProvider<DplAuditPalletFilterNotifier, DplAuditPalletFilter>(
  DplAuditPalletFilterNotifier.new,
);

/// The pallet register as the auditor sees it.
///
/// Reads `/warehouse/pallets`, NOT `/qa/pallets`. Same controller and the same
/// filters, but the QA router role-locks to dpl_qa/dpl_supervisor/dpl_manager
/// before any permission is consulted, so the auditor cannot call that one
/// however the administrator sets the grid.
final dplAuditPalletsProvider =
    FutureProvider.autoDispose<DplApiResponse<List<DplPallet>>>((ref) async {
  final f = ref.watch(dplAuditPalletFilterProvider);
  return ref.watch(dplApiServiceProvider).getPalletsForAudit(
        status: f.status,
        palletType: f.palletType,
        shiftCode: f.shiftCode,
        search: f.search,
        from: f.from,
        to: f.to,
        limit: 100,
      );
});

/// Which verdicts the register list is filtered to.
class DplAuditRegisterFilterNotifier extends Notifier<String> {
  @override
  String build() => 'all';

  void set(String v) => state = v;
}

final dplAuditRegisterFilterProvider =
    NotifierProvider<DplAuditRegisterFilterNotifier, String>(
  DplAuditRegisterFilterNotifier.new,
);

/// Audits already recorded — what has been checked, and what failed.
final dplAuditRegisterProvider =
    FutureProvider.autoDispose<DplApiResponse<DplPalletAuditPage>>((ref) async {
  final status = ref.watch(dplAuditRegisterFilterProvider);
  return ref.watch(dplApiServiceProvider).getPalletAudits(
        status: status == 'all' ? null : status,
        limit: 100,
      );
});
