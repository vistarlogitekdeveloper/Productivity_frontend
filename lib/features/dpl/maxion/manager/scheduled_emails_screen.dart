import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/dpl_theme.dart';
import '../../core/dpl_api_service.dart';
import '../../core/dpl_permissions_provider.dart';
import '../../core/widgets/dpl_app_bar.dart';
import '../../core/widgets/dpl_card.dart';
import '../../core/widgets/dpl_empty_state.dart';
import '../../core/widgets/dpl_error_retry.dart';
import '../../core/widgets/dpl_snack.dart';
import '../../models/dpl_report_subscription.dart';
import '../common/maxion_kit.dart';
import 'manager_maxion_providers.dart';

const List<String> _weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// "Every day", "Mon–Fri" style summary of ISO weekdays (1 = Monday).
String dplWeekdaysLabel(List<int> days) {
  final set = days.where((d) => d >= 1 && d <= 7).toSet().toList()..sort();
  if (set.length == 7) return 'every day';
  if (set.isEmpty) return 'no days';
  if (set.length == 5 && set.first == 1 && set.last == 5) return 'Mon–Fri';
  if (set.length == 6 && set.first == 1 && set.last == 6) return 'Mon–Sat';
  return set.map((d) => _weekdayNames[d - 1]).join(', ');
}

/// Splits "a@x.com, b@y.com; c@z.com" into addresses.
List<String> dplSplitEmails(String raw) =>
    raw.split(RegExp(r'[,;\s]+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

/// The four reports that can be mailed on a schedule (API.md §11.2): who gets
/// each, when, and how the last send went.
class DplScheduledEmailsScreen extends ConsumerStatefulWidget {
  final bool showAppBar;

  const DplScheduledEmailsScreen({super.key, this.showAppBar = true});

  @override
  ConsumerState<DplScheduledEmailsScreen> createState() => _DplScheduledEmailsScreenState();
}

class _DplScheduledEmailsScreenState extends ConsumerState<DplScheduledEmailsScreen> {
  final Set<String> _sending = {};

  Future<void> _edit(DplReportSubscription sub) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _SubscriptionEditSheet(sub: sub),
    );
    if (saved == true && mounted) {
      ref.invalidate(dplReportSubscriptionsProvider);
      DplSnacks.success(context, '${sub.label} schedule saved.');
    }
  }

  Future<void> _sendNow(DplReportSubscription sub) async {
    setState(() => _sending.add(sub.reportKey));
    final res = await ref.read(dplApiServiceProvider).sendReportNow(sub.reportKey);
    if (!mounted) return;
    setState(() => _sending.remove(sub.reportKey));
    ref.invalidate(dplReportSubscriptionsProvider);
    if (res.isError) {
      showFloorError(context, res, fallback: 'Could not send the email.');
      return;
    }
    final d = res.data ?? const <String, dynamic>{};
    final status = d['status']?.toString() ?? 'sent';
    final to = d['to'] is List ? (d['to'] as List).join(', ') : d['to']?.toString();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(status == 'sent' ? 'Email sent' : 'Email $status'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (d['subject'] != null) Text(d['subject'].toString(), style: DplText.body()),
            if (to != null && to.isNotEmpty) ...[
              const SizedBox(height: DplSpacing.sm),
              Text('To: $to', style: DplText.bodySm()),
            ],
            if (d['reason'] != null) ...[
              const SizedBox(height: DplSpacing.sm),
              Text(d['reason'].toString(), style: DplText.bodySm().copyWith(color: DplColors.warning)),
            ],
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(dplReportSubscriptionsProvider);
    final canEdit = ref.watch(dplPermissionsProvider).can(DplPermission.reportsSchedule);
    Future<void> refresh() => ref.refresh(dplReportSubscriptionsProvider.future);

    final body = async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => DplInlineErrorRetry(message: e.toString(), onRetry: refresh),
      data: (res) {
        if (res.isError) {
          return DplInlineErrorRetry(
            message: res.floorMessage.isEmpty ? 'Could not load scheduled emails.' : res.floorMessage,
            onRetry: refresh,
          );
        }
        final subs = res.data ?? const [];
        return RefreshIndicator(
          onRefresh: refresh,
          child: ListView(
            padding: const EdgeInsets.all(DplSpacing.md),
            children: [
              if (subs.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: DplSpacing.xxxl),
                  child: DplEmptyView(title: 'No reports to schedule', icon: Icons.mail_outline),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: DplSpacing.md),
                  child: Text(
                    'Each email carries the same Excel file as the download, at most once per plant day.',
                    style: DplText.caption(),
                  ),
                ),
                for (final s in subs)
                  _SubscriptionCard(
                    sub: s,
                    canEdit: canEdit,
                    sending: _sending.contains(s.reportKey),
                    onEdit: () => _edit(s),
                    onSendNow: () => _sendNow(s),
                  ),
              ],
            ],
          ),
        );
      },
    );

    if (!widget.showAppBar) return body;
    return Scaffold(
      backgroundColor: DplColors.pageBg,
      appBar: const DplAppBar(title: 'Scheduled emails'),
      body: body,
    );
  }
}

class _SubscriptionCard extends StatelessWidget {
  final DplReportSubscription sub;
  final bool canEdit;
  final bool sending;
  final VoidCallback onEdit;
  final VoidCallback onSendNow;

  const _SubscriptionCard({
    required this.sub,
    required this.canEdit,
    required this.sending,
    required this.onEdit,
    required this.onSendNow,
  });

  @override
  Widget build(BuildContext context) {
    final (String stateLabel, Color stateColor) = !sub.configured
        ? ('Not set up', DplColors.neutral)
        : sub.isActive
            ? ('Active', DplColors.success)
            : ('Paused', DplColors.warning);
    final failed = sub.lastStatus != null && sub.lastStatus != 'sent' && sub.lastStatus != 'skipped';

    return DplCard(
      margin: const EdgeInsets.only(bottom: DplSpacing.md),
      accentColor: stateColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(sub.label.isEmpty ? sub.reportKey : sub.label, style: DplText.h3())),
              _StatePill(label: stateLabel, color: stateColor),
            ],
          ),
          const SizedBox(height: DplSpacing.sm),
          if (sub.configured) ...[
            _line(Icons.people_outline, sub.recipients.isEmpty ? 'No recipients' : sub.recipients.join(', ')),
            if (sub.cc.isNotEmpty) _line(Icons.copy_all_outlined, 'Cc: ${sub.cc.join(', ')}'),
            _line(Icons.schedule, 'At ${sub.sendAt}, ${dplWeekdaysLabel(sub.weekdays)}'),
          ] else
            _line(Icons.info_outline, 'Nobody receives this report yet.'),
          if (sub.lastSentOn != null || sub.lastStatus != null)
            _line(
              failed ? Icons.error_outline : Icons.history,
              'Last: ${sub.lastSentOn ?? '—'} · ${sub.lastStatus ?? '—'}',
              color: failed ? DplColors.error : null,
            ),
          if (sub.lastError != null && sub.lastError!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 26, top: 2),
              child: Text(sub.lastError!, style: DplText.bodySm().copyWith(color: DplColors.error)),
            ),
          if (canEdit) ...[
            const SizedBox(height: DplSpacing.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: sending || !sub.configured ? null : onSendNow,
                  icon: sending
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send, size: 18),
                  label: const Text('Send now'),
                ),
                const SizedBox(width: DplSpacing.sm),
                FilledButton.tonalIcon(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit, size: 18),
                  label: Text(sub.configured ? 'Edit' : 'Set up'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _line(IconData icon, String text, {Color? color}) => Padding(
        padding: const EdgeInsets.only(bottom: DplSpacing.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: color ?? DplColors.textSecondary),
            const SizedBox(width: DplSpacing.sm),
            Expanded(child: Text(text, style: DplText.bodySm().copyWith(color: color))),
          ],
        ),
      );
}

/// A small status pill (label only), styled like DplCountChip.
class _StatePill extends StatelessWidget {
  final String label;
  final Color color;

  const _StatePill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: DplSpacing.sm, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          border: Border.all(color: color.withValues(alpha: 0.3)),
          borderRadius: BorderRadius.circular(DplRadius.pill),
        ),
        child: Text(label, style: DplText.caption().copyWith(color: color, fontWeight: FontWeight.w700)),
      );
}

class _SubscriptionEditSheet extends ConsumerStatefulWidget {
  final DplReportSubscription sub;

  const _SubscriptionEditSheet({required this.sub});

  @override
  ConsumerState<_SubscriptionEditSheet> createState() => _SubscriptionEditSheetState();
}

class _SubscriptionEditSheetState extends ConsumerState<_SubscriptionEditSheet> {
  late final TextEditingController _to;
  late final TextEditingController _cc;
  late TimeOfDay _time;
  late Set<int> _days;
  late bool _active;
  bool _saving = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    final s = widget.sub;
    _to = TextEditingController(text: s.recipients.join(', '));
    _cc = TextEditingController(text: s.cc.join(', '));
    final parts = s.sendAt.split(':');
    _time = TimeOfDay(
      hour: int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 20,
      minute: int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0,
    );
    _days = s.weekdays.toSet();
    // A report being set up for the first time is meant to start sending.
    _active = s.configured ? s.isActive : true;
  }

  @override
  void dispose() {
    _to.dispose();
    _cc.dispose();
    super.dispose();
  }

  String get _hhmm => '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}';

  Future<void> _pickTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: _time,
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (t != null) setState(() => _time = t);
  }

  Future<void> _save() async {
    final recipients = dplSplitEmails(_to.text);
    final cc = dplSplitEmails(_cc.text);
    if (_active && recipients.isEmpty) {
      setState(() => _problem = 'Add at least one recipient, or switch the schedule off.');
      return;
    }
    if (_days.isEmpty) {
      setState(() => _problem = 'Pick at least one day.');
      return;
    }
    setState(() {
      _saving = true;
      _problem = null;
    });
    final res = await ref.read(dplApiServiceProvider).saveReportSubscription(widget.sub.reportKey, {
      'recipients': recipients,
      'cc': cc,
      'send_at': _hhmm,
      'weekdays': (_days.toList()..sort()),
      'is_active': _active,
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (res.isError) {
      setState(() => _problem = res.floorMessage.isEmpty ? 'Could not save.' : res.floorMessage);
      return;
    }
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(DplSpacing.lg, 0, DplSpacing.lg, DplSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.sub.label.isEmpty ? widget.sub.reportKey : widget.sub.label, style: DplText.h2()),
            const SizedBox(height: DplSpacing.lg),
            TextField(
              controller: _to,
              keyboardType: TextInputType.emailAddress,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Recipients',
                helperText: 'Separate addresses with commas',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: DplSpacing.md),
            TextField(
              controller: _cc,
              keyboardType: TextInputType.emailAddress,
              minLines: 1,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Cc (optional)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: DplSpacing.md),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule),
              title: const Text('Send at (plant time)'),
              trailing: OutlinedButton(onPressed: _pickTime, child: Text(_hhmm)),
            ),
            Text('On', style: DplText.bodySm()),
            const SizedBox(height: DplSpacing.xs),
            Wrap(
              spacing: DplSpacing.xs,
              runSpacing: DplSpacing.xs,
              children: [
                for (var d = 1; d <= 7; d++)
                  FilterChip(
                    label: Text(_weekdayNames[d - 1]),
                    selected: _days.contains(d),
                    onSelected: (on) => setState(() => on ? _days.add(d) : _days.remove(d)),
                  ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Active'),
              subtitle: const Text('Off keeps the settings but stops sending.'),
              value: _active,
              onChanged: (v) => setState(() => _active = v),
            ),
            if (_problem != null)
              Padding(
                padding: const EdgeInsets.only(bottom: DplSpacing.sm),
                child: Text(_problem!, style: DplText.bodySm().copyWith(color: DplColors.error)),
              ),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
