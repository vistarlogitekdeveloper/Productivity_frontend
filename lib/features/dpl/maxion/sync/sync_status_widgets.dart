import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_permissions_provider.dart';
import '../../core/dpl_api_service.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_empty_state.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/_json_helpers.dart';
import '../../models/dpl_sync.dart';
import '../common/maxion_kit.dart';
import 'offline_outbox.dart';
import 'sync_providers.dart';

/// App-bar chip: where this handheld's offline queue stands. Tap to push now.
///
/// * "Synced" — nothing waiting.
/// * "Offline: N queued" — waiting for a connection (amber).
/// * "Blocked — ask a supervisor" — the server refused one of this device's
///   actions and is holding the rest behind it until someone resolves it (red).
class DplSyncStatusChip extends ConsumerWidget {
  /// Hide the chip entirely while nothing is queued.
  final bool hideWhenSynced;

  const DplSyncStatusChip({super.key, this.hideWhenSynced = false});

  static ({String label, Color color, IconData icon}) describe(DplOutboxState s) {
    if (s.blocked && s.hasPending) {
      return (label: 'Blocked — ask a supervisor', color: DplColors.error, icon: Icons.block);
    }
    if (s.hasPending) {
      return (
        label: s.flushing ? 'Syncing ${s.pending}…' : 'Offline: ${s.pending} queued',
        color: DplColors.warning,
        icon: s.flushing ? Icons.sync : Icons.cloud_off,
      );
    }
    return (label: 'Synced', color: DplColors.success, icon: Icons.cloud_done_outlined);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(dplOfflineOutboxProvider);
    if (hideWhenSynced && !s.hasPending) return const SizedBox.shrink();
    final d = describe(s);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: ActionChip(
        visualDensity: VisualDensity.compact,
        avatar: Icon(d.icon, size: 16, color: d.color),
        backgroundColor: d.color.withValues(alpha: 0.1),
        side: BorderSide(color: d.color.withValues(alpha: 0.35)),
        label: Text(d.label, style: TextStyle(color: d.color, fontWeight: FontWeight.w700, fontSize: 12)),
        tooltip: s.lastSyncAt == null ? 'Sync now' : 'Last synced ${DateFormat('HH:mm').format(s.lastSyncAt!)} — tap to sync now',
        onPressed: s.flushing
            ? null
            : () async {
                final outbox = ref.read(dplOfflineOutboxProvider.notifier);
                final r = await outbox.flush();
                if (!context.mounted) return;
                final after = ref.read(dplOfflineOutboxProvider);
                if (!after.hasPending) {
                  DplSnacks.success(context, 'Everything is synced.');
                } else if (after.blocked) {
                  DplSnacks.error(
                    context,
                    'The server refused one of this handheld’s actions. '
                    '${after.pending} waiting until a supervisor skips or retries it.',
                  );
                } else if (r == null) {
                  DplSnacks.warning(context, 'Still offline — ${after.pending} queued. ${after.lastError ?? ''}'.trim());
                } else {
                  DplSnacks.info(context, '${after.pending} still waiting.');
                }
              },
      ),
    );
  }
}

/// Supervisor view of offline sync: refused transactions to skip or retry,
/// and every handheld with its queue counts.
class DplSyncConflictsScreen extends ConsumerWidget {
  final bool showAppBar;

  const DplSyncConflictsScreen({super.key, this.showAppBar = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canResolve = ref.watch(dplPermissionsProvider).can(DplPermission.syncResolve);
    final Widget body = !canResolve
        ? const DplEmptyView(
            icon: Icons.lock_outline,
            title: 'Not available',
            message: 'Resolving handheld sync needs the "sync.resolve" permission.',
          )
        : RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(dplSyncConflictsProvider);
              ref.invalidate(dplSyncDevicesProvider);
              await ref.read(dplSyncConflictsProvider.future);
            },
            child: ListView(
              padding: const EdgeInsets.all(DplSpacing.lg),
              children: const [
                _SectionTitle('Refused on replay'),
                _ConflictsSection(),
                SizedBox(height: DplSpacing.xl),
                _SectionTitle('Handhelds'),
                _DevicesSection(),
              ],
            ),
          );
    if (!showAppBar) return body;
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: const DplAppBar(title: 'Handheld sync'),
      body: body,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: DplSpacing.sm),
        child: Text(text, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: DplColors.textPrimary)),
      );
}

class _ConflictsSection extends ConsumerStatefulWidget {
  const _ConflictsSection();

  @override
  ConsumerState<_ConflictsSection> createState() => _ConflictsSectionState();
}

class _ConflictsSectionState extends ConsumerState<_ConflictsSection> {
  final Set<int> _busy = {};

  Future<void> _resolve(DplSyncConflict c, String action) async {
    if (action == 'skip') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Skip this action?'),
          content: Text(
            'The ${c.type} from ${c.deviceId} (seq ${c.seq}) will NOT be applied, '
            'and the handheld’s queue moves on to the next action. '
            'Do this only when the action is wrong or has been done another way.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Skip it')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() => _busy.add(c.id));
    final res = await ref.read(dplApiServiceProvider).resolveSyncConflict(c.id, action);
    if (!mounted) return;
    setState(() => _busy.remove(c.id));
    if (res.isError) {
      showFloorError(context, res);
    } else {
      final r = res.data;
      if (r != null && r.isBlocked) {
        DplSnacks.warning(context, 'Resolved, but the handheld is blocked again by a later action.');
      } else {
        DplSnacks.success(context, action == 'skip' ? 'Skipped. The queue has moved on.' : 'Retried and applied.');
      }
    }
    ref.invalidate(dplSyncConflictsProvider);
    ref.invalidate(dplSyncDevicesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(dplSyncConflictsProvider);
    return async.when(
      loading: () => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
      error: (e, _) => DplInlineErrorChip(message: '$e', onRetry: () => ref.invalidate(dplSyncConflictsProvider)),
      data: (res) {
        if (res.isError) {
          return DplInlineErrorChip(message: res.floorMessage, onRetry: () => ref.invalidate(dplSyncConflictsProvider));
        }
        final list = res.data ?? const <DplSyncConflict>[];
        if (list.isEmpty) {
          return DplCard(
            child: Row(children: [
              Icon(Icons.check_circle_outline, color: DplColors.success),
              SizedBox(width: 8),
              Expanded(child: Text('Nothing waiting. Every handheld is applying its queue.')),
            ]),
          );
        }
        final fmt = DateFormat('d MMM, HH:mm');
        return Column(
          children: [
            for (final c in list)
              DplCard(
                margin: const EdgeInsets.only(bottom: DplSpacing.sm),
                accentColor: DplColors.error,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Text('${c.type}  ·  seq ${c.seq}',
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                      ),
                      if (c.code != null)
                        Text(c.code!, style: TextStyle(color: DplColors.error, fontWeight: FontWeight.w700, fontSize: 12)),
                    ]),
                    const SizedBox(height: 4),
                    Text(
                      [
                        c.deviceId,
                        if (c.operator != null) c.operator!,
                        if (c.occurredAt != null) fmt.format(c.occurredAt!.toLocal()),
                      ].join('  ·  '),
                      style: TextStyle(color: DplColors.textSecondary, fontSize: 12.5),
                    ),
                    if ((c.message ?? '').isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(c.message!),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton.icon(
                          onPressed: _busy.contains(c.id) ? null : () => _resolve(c, 'skip'),
                          icon: const Icon(Icons.skip_next, size: 18),
                          label: const Text('Skip'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          onPressed: _busy.contains(c.id) ? null : () => _resolve(c, 'retry'),
                          icon: const Icon(Icons.replay, size: 18),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _DevicesSection extends ConsumerWidget {
  const _DevicesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dplSyncDevicesProvider);
    return async.when(
      loading: () => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
      error: (e, _) => DplInlineErrorChip(message: '$e', onRetry: () => ref.invalidate(dplSyncDevicesProvider)),
      data: (res) {
        if (res.isError) {
          return DplInlineErrorChip(message: res.floorMessage, onRetry: () => ref.invalidate(dplSyncDevicesProvider));
        }
        final list = res.data ?? const <Map<String, dynamic>>[];
        if (list.isEmpty) {
          return const DplCard(child: Text('No handheld has synced yet.'));
        }
        final fmt = DateFormat('d MMM, HH:mm');
        return Column(
          children: [
            for (final d in list)
              Builder(builder: (context) {
                final seen = parseDateTimeOrNull(d['last_seen_at']);
                final blocked = d['blocked'] is Map;
                final name = parseStringOr(d['name']);
                return DplCard(
                  margin: const EdgeInsets.only(bottom: DplSpacing.sm),
                  accentColor: blocked ? DplColors.error : (d['is_active'] == false ? DplColors.neutral : DplColors.success),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                          child: Text(
                            name.isEmpty ? parseStringOr(d['device_id']) : '$name  ·  ${parseStringOr(d['device_id'])}',
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                        if (blocked)
                          Text('BLOCKED', style: TextStyle(color: DplColors.error, fontWeight: FontWeight.w800, fontSize: 12)),
                      ]),
                      const SizedBox(height: 4),
                      Text(
                        'Last seen ${seen == null ? '—' : fmt.format(seen.toLocal())}  ·  last applied seq ${parseIntOr(d['last_applied_seq'])}',
                        style: TextStyle(color: DplColors.textSecondary, fontSize: 12.5),
                      ),
                      const SizedBox(height: 6),
                      Wrap(spacing: 6, runSpacing: 4, children: [
                        DplCountChip(label: 'Pending', count: parseIntOr(d['pending']), color: DplColors.warning),
                        DplCountChip(label: 'Applied', count: parseIntOr(d['applied']), color: DplColors.success),
                        DplCountChip(label: 'Rejected', count: parseIntOr(d['rejected']), color: DplColors.error),
                        DplCountChip(label: 'Skipped', count: parseIntOr(d['skipped']), color: DplColors.neutral),
                      ]),
                    ],
                  ),
                );
              }),
          ],
        );
      },
    );
  }
}
