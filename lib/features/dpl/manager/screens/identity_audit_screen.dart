import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/vistar_palette.dart';
import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_refresh_icon_button.dart';
import '../../models/dpl_identity.dart';
import '../../models/dpl_shift.dart';
import '../providers/dpl_identity_audit_provider.dart';
import '../providers/dpl_shifts_provider.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_retry.dart';

Color get _kPrimary => VistarPalette.info;
Color get _kBad => VistarPalette.bad;
Color get _kNeutral => DplColors.textSecondary;
Color get _kBorder => DplColors.divider;
Color get _kSurfaceAlt => VistarPalette.surface2;

class DplIdentityAuditScreen extends ConsumerWidget {
  const DplIdentityAuditScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listAsync = ref.watch(dplIdentityAuditListProvider);
    final filters = ref.watch(dplIdentityAuditFiltersProvider);

    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: DplAppBar(
        title: 'Identity Audit',
        actions: [
          DplRefreshIconButton(
            onRefresh: () async {
              ref.invalidate(dplIdentityAuditListProvider);
              await ref.read(dplIdentityAuditListProvider.future);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _FilterBar(filters: filters),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(dplIdentityAuditListProvider);
                await ref.read(dplIdentityAuditListProvider.future);
              },
              child: listAsync.when(
                loading: () => const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  ),
                ),
                error: (e, _) => ListView(
                  children: [
                    DplErrorRetry(
                      message: e.toString(),
                      onRetry: () =>
                          ref.invalidate(dplIdentityAuditListProvider),
                    ),
                  ],
                ),
                data: (res) {
                  if (res.isError) {
                    return ListView(
                      children: [
                        DplErrorRetry(
                          message: res.error ?? 'Failed to load audit log.',
                          onRetry: () =>
                              ref.invalidate(dplIdentityAuditListProvider),
                        ),
                      ],
                    );
                  }
                  final paged = res.data;
                  final items = paged?.items ?? const [];
                  if (items.isEmpty) {
                    return ListView(
                      children: const [
                        DplEmptyState(
                          icon: Icons.fact_check_outlined,
                          title: 'No verifications',
                          message: 'No selfie verifications match the '
                              'current filters.',
                        ),
                      ],
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    itemCount: items.length + 1,
                    itemBuilder: (context, i) {
                      if (i == items.length) {
                        return _Pager(
                          page: paged!.page,
                          limit: paged.limit,
                          total: paged.total,
                          onPage: (p) => ref
                              .read(dplIdentityAuditFiltersProvider.notifier)
                              .setPage(p),
                        );
                      }
                      return _VerificationCard(item: items[i]);
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Filter bar — date range + shift + flagged toggle
// ---------------------------------------------------------------------------

class _FilterBar extends ConsumerWidget {
  final DplIdentityAuditFilters filters;
  const _FilterBar({required this.filters});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shiftsAsync = ref.watch(dplShiftsProvider);
    final shifts = shiftsAsync.asData?.value.data ?? const <DplShift>[];

    String rangeLabel() {
      final from = filters.from;
      final to = filters.to;
      if (from == null && to == null) return 'All dates';
      String d(DateTime dt) => DateFormat('d MMM').format(dt);
      if (from != null && to != null) return '${d(from)} → ${d(to)}';
      if (from != null) return 'From ${d(from)}';
      return 'Until ${d(to!)}';
    }

    final activeShift = shifts.where((s) => s.id == filters.shiftId).toList();
    final shiftLabel = filters.shiftId == null
        ? 'All shifts'
        : (activeShift.isNotEmpty ? activeShift.first.name : 'Shift');

    String flaggedLabel() {
      if (filters.flagged == null) return 'Any status';
      return filters.flagged! ? 'Flagged only' : 'Unflagged only';
    }

    return Container(
      color: DplColors.cardBg,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _ChipBtn(
              icon: Icons.event_outlined,
              label: rangeLabel(),
              active: filters.from != null || filters.to != null,
              onTap: () => _pickRange(context, ref),
              onClear: (filters.from != null || filters.to != null)
                  ? () => ref
                      .read(dplIdentityAuditFiltersProvider.notifier)
                      .setRange(null, null)
                  : null,
            ),
            const SizedBox(width: 8),
            _ChipBtn(
              icon: Icons.access_time,
              label: shiftLabel,
              active: filters.shiftId != null,
              onTap: () => _pickShift(context, ref, shifts),
              onClear: filters.shiftId != null
                  ? () => ref
                      .read(dplIdentityAuditFiltersProvider.notifier)
                      .setShift(null)
                  : null,
            ),
            const SizedBox(width: 8),
            _ChipBtn(
              icon: Icons.flag_outlined,
              label: flaggedLabel(),
              active: filters.flagged != null,
              onTap: () => _pickFlagged(context, ref),
              onClear: filters.flagged != null
                  ? () => ref
                      .read(dplIdentityAuditFiltersProvider.notifier)
                      .setFlagged(null)
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickRange(BuildContext context, WidgetRef ref) async {
    final now = DateTime.now();
    final initial = DateTimeRange(
      start: filters.from ?? now.subtract(const Duration(days: 7)),
      end: filters.to ?? now,
    );
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 1),
      initialDateRange: initial,
    );
    if (picked != null) {
      ref
          .read(dplIdentityAuditFiltersProvider.notifier)
          .setRange(picked.start, picked.end);
    }
  }

  Future<void> _pickShift(
    BuildContext context,
    WidgetRef ref,
    List<DplShift> shifts,
  ) async {
    final id = await showModalBottomSheet<int?>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.clear),
              title: const Text('All shifts'),
              onTap: () => Navigator.pop(context, -1),
            ),
            const Divider(height: 1),
            for (final s in shifts)
              ListTile(
                leading: const Icon(Icons.access_time),
                title: Text('${s.name}  •  ${s.windowLabel}'),
                onTap: () => Navigator.pop(context, s.id),
              ),
          ],
        ),
      ),
    );
    if (id == null) return;
    ref
        .read(dplIdentityAuditFiltersProvider.notifier)
        .setShift(id == -1 ? null : id);
  }

  Future<void> _pickFlagged(BuildContext context, WidgetRef ref) async {
    final v = await showModalBottomSheet<int>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.clear),
              title: const Text('Any status'),
              onTap: () => Navigator.pop(context, 0),
            ),
            ListTile(
              leading: Icon(Icons.flag, color: _kBad),
              title: const Text('Flagged only'),
              onTap: () => Navigator.pop(context, 1),
            ),
            ListTile(
              leading: const Icon(Icons.outlined_flag),
              title: const Text('Unflagged only'),
              onTap: () => Navigator.pop(context, 2),
            ),
          ],
        ),
      ),
    );
    if (v == null) return;
    final notifier = ref.read(dplIdentityAuditFiltersProvider.notifier);
    if (v == 0) notifier.setFlagged(null);
    if (v == 1) notifier.setFlagged(true);
    if (v == 2) notifier.setFlagged(false);
  }
}

class _ChipBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  const _ChipBtn({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? VistarPalette.surface3 : DplColors.cardBg,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: active ? _kPrimary : _kBorder,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: active ? _kPrimary : _kNeutral),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: active ? _kPrimary : _kNeutral,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
              if (onClear != null) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: onClear,
                  child: Icon(
                    Icons.close,
                    size: 14,
                    color: _kNeutral,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// List card + detail viewer
// ---------------------------------------------------------------------------

class _VerificationCard extends StatelessWidget {
  final DplIdentityVerification item;
  const _VerificationCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final captured = item.createdAt.toLocal();
    final whenLine = DateFormat('d MMM yyyy, HH:mm').format(captured);
    final shift = (item.shiftCode ?? '').isNotEmpty
        ? 'Shift ${item.shiftCode}'
        : (item.shiftName ?? '').isNotEmpty
            ? item.shiftName!
            : '—';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: DplColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _openDetail(context),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: item.flagged ? _kBad : _kBorder,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: VistarPalette.surface3,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _kBorder),
                  ),
                  child: Icon(
                    Icons.person_outline,
                    color: _kPrimary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.supervisorName ?? 'Supervisor #${item.supervisorId ?? '-'}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          _Tag(text: shift, color: _kPrimary),
                          _Tag(
                            text: _humanContext(item.context),
                            color: _kNeutral,
                          ),
                          if (item.flagged)
                            _Tag(text: 'Flagged', color: _kBad),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        whenLine,
                        style: TextStyle(
                          color: _kNeutral,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: _kNeutral),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openDetail(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: DplColors.cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _PhotoDetailSheet(item: item),
    );
  }

  static String _humanContext(String c) {
    switch (c) {
      case 'login':
        return 'Login';
      case 'plan_access':
        return 'Plan access';
      case 'item_start':
        return 'Item start';
      case 'downtime_start':
        return 'Downtime start';
      default:
        return c;
    }
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final Color color;
  const _Tag({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(28),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _PhotoDetailSheet extends ConsumerStatefulWidget {
  final DplIdentityVerification item;
  const _PhotoDetailSheet({required this.item});

  @override
  ConsumerState<_PhotoDetailSheet> createState() =>
      _PhotoDetailSheetState();
}

class _PhotoDetailSheetState extends ConsumerState<_PhotoDetailSheet> {
  bool _flagging = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final photoAsync = ref.watch(dplIdentityPhotoProvider(item.id));
    final media = MediaQuery.of(context);
    final captured = item.createdAt.toLocal();
    final whenLine =
        DateFormat('EEE, d MMM yyyy • HH:mm:ss').format(captured);

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: media.size.height * 0.92),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 12,
            bottom: 16 + media.viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: DplColors.divider,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Icon(Icons.image_outlined, color: _kPrimary),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Verification photo',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: AspectRatio(
                          aspectRatio: 3 / 4,
                          child: Container(
                            color: _kSurfaceAlt,
                            child: photoAsync.when(
                              loading: () => const Center(
                                child: CircularProgressIndicator(),
                              ),
                              error: (e, _) => Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text(
                                    e.toString(),
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: _kBad),
                                  ),
                                ),
                              ),
                              data: (res) {
                                if (res.isError || res.data == null) {
                                  return Center(
                                    child: Text(
                                      res.error ?? 'Photo unavailable',
                                      style: TextStyle(color: _kBad),
                                    ),
                                  );
                                }
                                return Image.memory(
                                  res.data!,
                                  fit: BoxFit.cover,
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _MetaRow(
                        icon: Icons.event,
                        label: 'Captured',
                        value: whenLine,
                      ),
                      _MetaRow(
                        icon: Icons.person_outline,
                        label: 'Supervisor',
                        value: item.supervisorName ??
                            'ID ${item.supervisorId ?? '-'}',
                      ),
                      _MetaRow(
                        icon: Icons.access_time,
                        label: 'Shift',
                        value: (item.shiftName ?? '').isNotEmpty
                            ? '${item.shiftName} (${item.shiftCode ?? ''})'
                                .trim()
                            : (item.shiftCode ?? '—'),
                      ),
                      _MetaRow(
                        icon: Icons.bookmark_outline,
                        label: 'Context',
                        value: _VerificationCard._humanContext(item.context),
                      ),
                      if (item.planId != null)
                        _MetaRow(
                          icon: Icons.assignment_outlined,
                          label: 'Plan',
                          value: '#${item.planId}'
                              '${item.planItemId != null ? ' / item #${item.planItemId}' : ''}',
                        ),
                      if (item.deviceIp.isNotEmpty)
                        _MetaRow(
                          icon: Icons.dns_outlined,
                          label: 'Device IP',
                          value: item.deviceIp,
                        ),
                      if (item.userAgent.isNotEmpty)
                        _MetaRow(
                          icon: Icons.phone_iphone,
                          label: 'User agent',
                          value: item.userAgent,
                        ),
                      if (item.flagged) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: VistarPalette.badBg,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: VistarPalette.badLine,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.flag, color: _kBad, size: 16),
                                  SizedBox(width: 6),
                                  Text(
                                    'Flagged',
                                    style: TextStyle(
                                      color: _kBad,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ),
                              if ((item.flagReason ?? '').isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  item.flagReason!,
                                  style: TextStyle(
                                    color: VistarPalette.badInk,
                                  ),
                                ),
                              ],
                              if (item.flaggedAt != null)
                                Text(
                                  DateFormat('d MMM yyyy, HH:mm')
                                      .format(item.flaggedAt!.toLocal()),
                                  style: TextStyle(
                                    color: _kNeutral,
                                    fontSize: 11,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (!item.flagged)
                SizedBox(
                  height: 48,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _kBad,
                      side: BorderSide(color: _kBad),
                    ),
                    icon: _flagging
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.flag_outlined),
                    label: Text(_flagging ? 'Flagging…' : 'Flag as suspicious'),
                    onPressed: _flagging ? null : _flag,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _flag() async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _FlagReasonDialog(),
    );
    if (reason == null || reason.trim().isEmpty) return;
    setState(() => _flagging = true);
    final res = await ref
        .read(dplApiServiceProvider)
        .flagIdentityVerification(widget.item.id, reason.trim());
    if (!mounted) return;
    setState(() => _flagging = false);
    if (res.isError) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(res.error ?? 'Could not flag.')),
      );
      return;
    }
    ref.invalidate(dplIdentityAuditListProvider);
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Flagged.')),
    );
  }
}

class _MetaRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _MetaRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: _kNeutral),
          const SizedBox(width: 10),
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: TextStyle(
                color: _kNeutral,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FlagReasonDialog extends StatefulWidget {
  const _FlagReasonDialog();

  @override
  State<_FlagReasonDialog> createState() => _FlagReasonDialogState();
}

class _FlagReasonDialogState extends State<_FlagReasonDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Flag verification'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        maxLines: 3,
        decoration: const InputDecoration(
          hintText: 'Reason (visible to admins)',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: _kBad),
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: const Text('Flag'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Pagination
// ---------------------------------------------------------------------------

class _Pager extends StatelessWidget {
  final int page;
  final int limit;
  final int total;
  final ValueChanged<int> onPage;

  const _Pager({
    required this.page,
    required this.limit,
    required this.total,
    required this.onPage,
  });

  @override
  Widget build(BuildContext context) {
    if (total <= limit) return const SizedBox.shrink();
    final last = ((total - 1) ~/ limit) + 1;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: page > 1 ? () => onPage(page - 1) : null,
          ),
          Text(
            'Page $page of $last',
            style: TextStyle(
              color: _kNeutral,
              fontWeight: FontWeight.w700,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: page < last ? () => onPage(page + 1) : null,
          ),
        ],
      ),
    );
  }
}

