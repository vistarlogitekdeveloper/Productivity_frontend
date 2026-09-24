import '_json_helpers.dart';

/// A pallet the pack point operator builds (backend migration 151).
///
/// Maxion SSR v3.0 Module 4. The TYPE is decided by the system at close, never
/// by the operator — asking would invite a full pallet being labelled half on
/// a busy shift, and the type decides whether it goes back for topping up.
class DplPallet {
  final int id;
  final String palletNo;

  /// `P` full, `H` half, `PM` merged. Empty while the pallet is still open —
  /// until it closes, nobody knows which it is.
  final String palletType;

  final String status; // open | closed | merged | dispatched

  final int partId;
  final String customerPartNo;
  final String partDescription;

  final int machineId;
  final String machineName;

  /// The standard pallet quantity, snapshotted when the pallet was opened.
  ///
  /// `null` when the part has no standard quantity set — which is the case for
  /// every Maxion item until that master data arrives. The screen must render
  /// that as "no target" rather than as zero, or the counter reads "37 / 0".
  final int? standardQty;

  final int qty;

  /// `standardQty - qty`, or null when there is no target.
  final int? remaining;
  final bool isFull;

  final String closeReason;
  final String shiftCode;
  final DateTime? closedAt;

  /// How many days a stored half pallet has been waiting. The register
  /// highlights old ones; SSR §4 calls ageing half pallets out by name as the
  /// thing the system exists to stop.
  final int? ageDays;

  /// The rack it is standing on, e.g. "FG-A-03". Empty while the pallet is
  /// open, or once it has been dispatched off the rack.
  final String locationCode;

  /// How many wheels came from the half pallet this was opened from.
  ///
  /// Zero when the pallet was started empty. Drives the discard warning: a
  /// brought-back pallet is not simply undone — the half pallet is restored
  /// with exactly these wheels, and only the extras go to unpacked.
  final int broughtBackQty;

  /// What this pallet was called before a merge moved it onto the M series.
  /// What this pallet was called before a merge moved it onto the M series.
  /// Shown so somebody holding an old label or an old dispatch note can tell
  /// it is the same pallet.
  final String previousPalletNo;

  final List<String> serials;

  const DplPallet({
    this.id = 0,
    this.palletNo = '',
    this.palletType = '',
    this.status = 'open',
    this.partId = 0,
    this.customerPartNo = '',
    this.partDescription = '',
    this.machineId = 0,
    this.machineName = '',
    this.standardQty,
    this.qty = 0,
    this.remaining,
    this.isFull = false,
    this.closeReason = '',
    this.shiftCode = '',
    this.closedAt,
    this.ageDays,
    this.locationCode = '',
    this.previousPalletNo = '',
    this.broughtBackQty = 0,
    this.serials = const [],
  });

  factory DplPallet.fromJson(Map<String, dynamic> json) {
    final part = json['part'];
    final partMap = part is Map ? Map<String, dynamic>.from(part) : const {};
    final machine = json['machine'];
    final machineMap =
        machine is Map ? Map<String, dynamic>.from(machine) : const {};
    final location = json['location'];
    final locationMap =
        location is Map ? Map<String, dynamic>.from(location) : const {};
    final rawSerials = json['serials'];

    return DplPallet(
      id: parseIntOr(json['id']),
      palletNo: parseStringOr(json['pallet_no']),
      palletType: parseStringOr(json['pallet_type']),
      status: parseStringOr(json['status'], 'open'),
      partId: parseIntOr(json['part_id']),
      customerPartNo: parseStringOr(partMap['customer_part_no']),
      partDescription: parseStringOr(partMap['description']),
      machineId: parseIntOr(json['machine_id']),
      machineName: parseStringOr(machineMap['machine_name']),
      // parseIntOrNull, not parseIntOr — the difference between "no target
      // set" and "a target of zero" is the whole point.
      standardQty: parseIntOrNull(json['standard_qty']),
      qty: parseIntOr(json['qty']),
      remaining: parseIntOrNull(json['remaining']),
      isFull: json['is_full'] == true,
      closeReason: parseStringOr(json['close_reason']),
      shiftCode: parseStringOr(json['shift_code']),
      closedAt: parseDateTimeOrNull(json['closed_at']),
      ageDays: parseIntOrNull(json['age_days']),
      locationCode: parseStringOr(locationMap['code']),
      previousPalletNo: parseStringOr(json['previous_pallet_no']),
      broughtBackQty: parseIntOr(json['brought_back_qty']),
      serials: rawSerials is List
          ? rawSerials
              .whereType<Map>()
              .map((e) => parseStringOr(e['serial_no']))
              .where((s) => s.isNotEmpty)
              .toList()
          : const [],
    );
  }

  bool get isOpen => status == 'open';

  /// True when the part has a standard pallet quantity, so the screen can show
  /// a target and a progress bar at all.
  bool get hasTarget => standardQty != null && standardQty! > 0;

  /// "37 / 96", or just "37" when nothing says what full looks like.
  String get countLabel => hasTarget ? '$qty / $standardQty' : '$qty';

  double get progress {
    if (!hasTarget) return 0;
    final p = qty / standardQty!;
    return p > 1 ? 1 : p;
  }

  /// What the Close button promises it is about to do, in the operator's
  /// words. SSR Module 4: "Says in plain words what type it will be".
  String get closePreview {
    if (!hasTarget) {
      // Names the remedy, not just the symptom. The standard pallet quantity
      // is editable today under Manager > Packaging Qtys; without saying so
      // this reads as a defect the operator can do nothing about, and every
      // pallet quietly closes as HALF for ever.
      return 'This will close as a HALF pallet with $qty on it — no standard '
          'pallet quantity is set for this item. A manager can set it under '
          'Packaging Qtys.';
    }
    if (qty >= standardQty!) {
      return 'This will close as a FULL pallet with all $standardQty on it.';
    }
    return 'This will close as a HALF pallet with $qty of $standardQty on it.';
  }

  String get typeLabel {
    switch (palletType) {
      case 'P':
        return 'Full';
      case 'H':
        return 'Half';
      case 'PM':
        return 'Merged';
      default:
        return palletType.isEmpty ? 'Open' : palletType;
    }
  }
}

/// Everything the 100 x 75 mm pallet label prints.
///
/// Fed by `GET /qa/pallets/:id/label`. Separate from [DplPallet] because a
/// label needs facts a list row does not — the oldest wheel's date, the half
/// pallet a merge consumed, the rack it is standing on — and carrying them on
/// every list row would mean four extra queries per pallet to render a table.
class DplPalletSticker {
  final int palletId;
  final String palletNo;

  /// `P`, `H` or `PM`.
  final String palletType;

  final int qty;
  final int? standardQty;

  final String customerPartNo;
  final String description;
  final String partName;

  final String machineName;
  final String locationCode;
  final String shiftCode;

  final DateTime? closedAt;

  /// The oldest wheel on the pallet, read off the wheels rather than off the
  /// pallet row. SSR §4: "a merged pallet keeps the oldest production date of
  /// the wheels on it, so merging never makes old stock look new."
  final DateTime? oldestWheelAt;

  /// SSR §5: "...and, for a merged pallet, the old half pallet number."
  final String mergedFromPalletNo;

  final String serialFrom;
  final String serialTo;

  const DplPalletSticker({
    this.palletId = 0,
    this.palletNo = '',
    this.palletType = '',
    this.qty = 0,
    this.standardQty,
    this.customerPartNo = '',
    this.description = '',
    this.partName = '',
    this.machineName = '',
    this.locationCode = '',
    this.shiftCode = '',
    this.closedAt,
    this.oldestWheelAt,
    this.mergedFromPalletNo = '',
    this.serialFrom = '',
    this.serialTo = '',
  });

  factory DplPalletSticker.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic> sub(String k) {
      final v = json[k];
      return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
    }

    final p = sub('pallet');
    final part = sub('part');

    return DplPalletSticker(
      palletId: parseIntOr(p['id']),
      palletNo: parseStringOr(p['pallet_no']),
      palletType: parseStringOr(p['pallet_type']),
      qty: parseIntOr(p['qty']),
      standardQty: parseIntOrNull(p['standard_qty']),
      customerPartNo: parseStringOr(part['customer_part_no']),
      description: parseStringOr(part['description']),
      partName: parseStringOr(part['part_name']),
      machineName: parseStringOr(json['machine_name']),
      locationCode: parseStringOr(json['location_code']),
      shiftCode: parseStringOr(p['shift_code']),
      closedAt: parseDateTimeOrNull(p['closed_at']),
      oldestWheelAt: parseDateTimeOrNull(p['oldest_wheel_at']),
      mergedFromPalletNo: parseStringOr(p['merged_from_pallet_no']),
      serialFrom: parseStringOr(json['serial_from']),
      serialTo: parseStringOr(json['serial_to']),
    );
  }

  /// SSR §5: `MWP|PM26000012` — the pallet NUMBER and nothing else.
  ///
  /// Do not be tempted to add fields. §5 says the pallet QR "is reprinted when
  /// the pallet changes, for example on a merge", so anything encoded beyond
  /// the number is a fact that can go stale on a label already stuck to a
  /// shroud. The number always resolves to the truth.
  String get qrPayload => 'MWP|$palletNo';

  String get typeWord {
    switch (palletType) {
      case 'P':
        return 'FULL';
      case 'H':
        return 'HALF';
      case 'PM':
        return 'MERGED';
      default:
        return palletType.isEmpty ? 'PALLET' : palletType.toUpperCase();
    }
  }

  String get qtyLine =>
      standardQty != null && standardQty! > 0
          ? 'QTY: $qty / $standardQty NOS'
          : 'QTY: $qty NOS';

  static String _d(DateTime? t) {
    if (t == null) return '';
    final l = t.toLocal();
    final dd = l.day.toString().padLeft(2, '0');
    final mm = l.month.toString().padLeft(2, '0');
    return '$dd/$mm/${l.year}';
  }

  /// The detail row, in the order SSR §5 names them: item, quantity, dates,
  /// and for a merged pallet the old half pallet number. Blanks are dropped
  /// rather than printed as "—", because an empty label cell reads as a
  /// system that lost something.
  List<MapEntry<String, String>> get detailCells {
    final out = <MapEntry<String, String>>[];
    void add(String k, String v) {
      if (v.trim().isNotEmpty) out.add(MapEntry(k, v.trim()));
    }

    add('PACKED', _d(closedAt));
    // Only shown when it differs from the packing date — on an ordinary pallet
    // the two are the same and the extra cell is noise; on a merged one the
    // gap is the whole point.
    final oldest = _d(oldestWheelAt);
    if (oldest.isNotEmpty && oldest != _d(closedAt)) add('OLDEST', oldest);
    add('SHIFT', shiftCode);
    add('LINE', machineName);
    add('LOC', locationCode);
    add('FROM', serialFrom);
    add('TO', serialTo);
    add('MERGED FROM', mergedFromPalletNo);
    return out;
  }
}

/// One page of the pallet register, plus how many there are in total.
///
/// The total is carried separately from the rows because "showing 50 of 2,310"
/// is the difference between a list the storeman trusts and one they assume is
/// everything on the floor.
class DplPalletPage {
  final List<DplPallet> pallets;
  final int total;
  final int limit;
  final int offset;

  const DplPalletPage({
    this.pallets = const [],
    this.total = 0,
    this.limit = 50,
    this.offset = 0,
  });

  factory DplPalletPage.fromJson(Map<String, dynamic> json) {
    final raw = json['pallets'];
    return DplPalletPage(
      pallets: raw is List
          ? raw
              .whereType<Map>()
              .map((e) => DplPallet.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      total: parseIntOr(json['total']),
      limit: parseIntOr(json['limit'], 50),
      offset: parseIntOr(json['offset']),
    );
  }

  bool get hasMore => offset + pallets.length < total;
}

/// What the register is filtered by.
///
/// Immutable with a [copyWith] so the provider can be a plain state notifier:
/// every filter change produces a new value, which is what makes the list
/// rebuild exactly once per change rather than once per field.
class DplPalletFilter {
  /// `open`, `closed`, `merged`, `dispatched`, or empty for all.
  final String status;

  /// `P`, `H`, `PM`, or empty for all.
  final String palletType;

  final int? partId;
  final int? machineId;
  final String search;
  final DateTime? from;
  final DateTime? to;

  /// SSR Module 5's standing question: what is still sitting part-filled.
  final bool staleHalfOnly;

  final int offset;
  final int limit;

  const DplPalletFilter({
    this.status = '',
    this.palletType = '',
    this.partId,
    this.machineId,
    this.search = '',
    this.from,
    this.to,
    this.staleHalfOnly = false,
    this.offset = 0,
    this.limit = 50,
  });

  DplPalletFilter copyWith({
    String? status,
    String? palletType,
    int? partId,
    int? machineId,
    String? search,
    DateTime? from,
    DateTime? to,
    bool? staleHalfOnly,
    int? offset,
    int? limit,
    // Explicit clears — copyWith(partId: null) cannot mean "clear it", since
    // null is also "leave it alone". Every nullable filter needs its own flag
    // or clearing the item filter silently does nothing.
    bool clearPartId = false,
    bool clearMachineId = false,
    bool clearFrom = false,
    bool clearTo = false,
  }) {
    return DplPalletFilter(
      status: status ?? this.status,
      palletType: palletType ?? this.palletType,
      partId: clearPartId ? null : (partId ?? this.partId),
      machineId: clearMachineId ? null : (machineId ?? this.machineId),
      search: search ?? this.search,
      from: clearFrom ? null : (from ?? this.from),
      to: clearTo ? null : (to ?? this.to),
      staleHalfOnly: staleHalfOnly ?? this.staleHalfOnly,
      // Any change to a filter resets the page. Keeping the offset would
      // land the storeman on page 4 of a 2-page result and look empty.
      offset: offset ?? 0,
      limit: limit ?? this.limit,
    );
  }

  static String _ymd(DateTime? d) =>
      d == null
          ? ''
          : '${d.year.toString().padLeft(4, '0')}-'
              '${d.month.toString().padLeft(2, '0')}-'
              '${d.day.toString().padLeft(2, '0')}';

  Map<String, dynamic> toQuery() => {
        'status': status.isEmpty ? null : status,
        'pallet_type': palletType.isEmpty ? null : palletType,
        'part_id': partId,
        'machine_id': machineId,
        'search': search.trim().isEmpty ? null : search.trim(),
        'from': _ymd(from).isEmpty ? null : _ymd(from),
        'to': _ymd(to).isEmpty ? null : _ymd(to),
        'stale_half': staleHalfOnly ? true : null,
        'limit': limit,
        'offset': offset,
      };

  /// True when anything narrows the list. Drives the "Clear" button and the
  /// wording of the empty state — "no pallets yet" and "nothing matches these
  /// filters" need completely different reactions from the reader.
  bool get isFiltered =>
      status.isNotEmpty ||
      palletType.isNotEmpty ||
      partId != null ||
      machineId != null ||
      search.trim().isNotEmpty ||
      from != null ||
      to != null ||
      staleHalfOnly;

  int get activeCount => [
        status.isNotEmpty,
        palletType.isNotEmpty,
        partId != null,
        machineId != null,
        search.trim().isNotEmpty,
        from != null || to != null,
        staleHalfOnly,
      ].where((e) => e).length;

  @override
  bool operator ==(Object other) =>
      other is DplPalletFilter &&
      other.status == status &&
      other.palletType == palletType &&
      other.partId == partId &&
      other.machineId == machineId &&
      other.search == search &&
      other.from == from &&
      other.to == to &&
      other.staleHalfOnly == staleHalfOnly &&
      other.offset == offset &&
      other.limit == limit;

  @override
  int get hashCode => Object.hash(
        status,
        palletType,
        partId,
        machineId,
        search,
        from,
        to,
        staleHalfOnly,
        offset,
        limit,
      );
}

/// What `GET /warehouse/pallets/resolve` answers when a pallet label is scanned.
///
/// Three things in one round trip, because the operator is standing in front of
/// a rack with a scanner in one hand and every extra call is a pause: WHICH
/// pallet, WHERE it is now, and WHERE it should go.
class DplPalletResolution {
  final DplPallet pallet;

  /// Set when the label that was scanned carries the pallet's OLD number,
  /// because a merge renumbered it onto the M series.
  ///
  /// The screen must say so. Showing a different number than the one in the
  /// operator's hand, with no explanation, reads as the scanner misreading —
  /// and the next thing they do is scan it again.
  final String renamedFrom;

  /// Where it is already stored, if anywhere. Non-null means this scan is a
  /// MOVE rather than a first putaway, and the screen must say so — silently
  /// relocating a pallet somebody else put away is how stock goes missing.
  final DplLocationRef? current;

  /// Where the system thinks it should go. Null when nothing sensible can be
  /// suggested, which the screen renders as an ordinary picker rather than as
  /// an error.
  final DplPutawaySuggestion? suggestion;

  const DplPalletResolution({
    this.pallet = const DplPallet(),
    this.current,
    this.suggestion,
    this.renamedFrom = '',
  });

  bool get wasRenamed => renamedFrom.trim().isNotEmpty;

  factory DplPalletResolution.fromJson(Map<String, dynamic> json) {
    final p = json['pallet'];
    final loc = json['location'];
    final sug = json['suggestion'];
    return DplPalletResolution(
      pallet: p is Map
          ? DplPallet.fromJson(Map<String, dynamic>.from(p))
          : const DplPallet(),
      current: loc is Map
          ? DplLocationRef.fromJson(Map<String, dynamic>.from(loc))
          : null,
      suggestion: sug is Map
          ? DplPutawaySuggestion.fromJson(Map<String, dynamic>.from(sug))
          : null,
      renamedFrom: parseStringOr(json['renamed_from']),
    );
  }

  bool get isMove => current != null;
}

/// Just enough of a location to name it on screen.
class DplLocationRef {
  final int id;
  final String code;
  final String name;
  final String zone;

  const DplLocationRef({
    this.id = 0,
    this.code = '',
    this.name = '',
    this.zone = '',
  });

  factory DplLocationRef.fromJson(Map<String, dynamic> json) => DplLocationRef(
        id: parseIntOr(json['id']),
        code: parseStringOr(json['code']),
        name: parseStringOr(json['name']),
        zone: parseStringOr(json['zone']),
      );
}

/// The "directed" half of directed putaway — Maxion SSR Module 6.
///
/// Carries [reason] because a suggestion an operator does not understand is a
/// suggestion they override at random. "Half pallets are kept together so they
/// get filled rather than forgotten" is the difference between a rule people
/// follow and a box that fills itself in.
class DplPutawaySuggestion {
  final int id;
  final String code;
  final String name;
  final String zone;
  final int freeQty;
  final String reason;

  const DplPutawaySuggestion({
    this.id = 0,
    this.code = '',
    this.name = '',
    this.zone = '',
    this.freeQty = 0,
    this.reason = '',
  });

  factory DplPutawaySuggestion.fromJson(Map<String, dynamic> json) =>
      DplPutawaySuggestion(
        id: parseIntOr(json['id']),
        code: parseStringOr(json['code']),
        name: parseStringOr(json['name']),
        zone: parseStringOr(json['zone']),
        freeQty: parseIntOr(json['free_qty']),
        reason: parseStringOr(json['reason']),
      );
}

/// The outcome of filling one pallet from another — SSR Module 5.
///
/// Both pallets come back because both changed, and [reprint] says whose label
/// is now stale. A remainder pallet walking the floor with a label claiming its
/// old count is exactly what §5's reprint rule exists to stop.
class DplMergeResult {
  final DplPallet target;
  final DplPallet source;

  /// How many wheels actually moved — capped at what the target still needed,
  /// never at what the source held.
  final int moved;

  /// True when the source gave up everything and is no longer a pallet.
  final bool sourceEmptied;

  /// Pallet ids whose label must be printed again. The server decides this,
  /// not the screen: when the source is emptied it stops existing, and a label
  /// for a pallet that no longer exists is worse than no label.
  final List<int> reprint;

  const DplMergeResult({
    this.target = const DplPallet(),
    this.source = const DplPallet(),
    this.moved = 0,
    this.sourceEmptied = false,
    this.reprint = const [],
  });

  factory DplMergeResult.fromJson(Map<String, dynamic> json) {
    final t = json['target'];
    final s = json['source'];
    final r = json['reprint'];
    return DplMergeResult(
      target: t is Map
          ? DplPallet.fromJson(Map<String, dynamic>.from(t))
          : const DplPallet(),
      source: s is Map
          ? DplPallet.fromJson(Map<String, dynamic>.from(s))
          : const DplPallet(),
      moved: parseIntOr(json['moved']),
      sourceEmptied: json['source_emptied'] == true,
      reprint: r is List
          ? r.map(parseIntOr).where((e) => e > 0).toList()
          : const [],
    );
  }
}

/// The outcome of a drag-and-drop merge.
///
/// Both pallets come back because either or both may have changed, and
/// [reprint] names the ones that still exist and therefore need a label. A
/// pallet that gave everything away is no longer a pallet, and a label for it
/// would be a label for something that is not there.
class DplRedistributeResult {
  final List<DplPallet> pallets;
  final int moved;
  final List<int> reprint;

  const DplRedistributeResult({
    this.pallets = const [],
    this.moved = 0,
    this.reprint = const [],
  });

  factory DplRedistributeResult.fromJson(Map<String, dynamic> json) {
    final raw = json['pallets'];
    final r = json['reprint'];
    return DplRedistributeResult(
      pallets: raw is List
          ? raw
              .whereType<Map>()
              .map((e) => DplPallet.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      moved: parseIntOr(json['moved']),
      reprint: r is List
          ? r.map(parseIntOr).where((e) => e > 0).toList()
          : const [],
    );
  }
}
