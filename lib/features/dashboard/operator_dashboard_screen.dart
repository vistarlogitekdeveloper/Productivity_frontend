import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/theme/theme_mode_provider.dart';
import '../../core/theme/vistar_palette.dart';
import '../../core/widgets/shimmer_skeleton.dart';
import '../../data/models/production_entry_model.dart';
import '../../features/auth/auth_provider.dart';
import '../../features/auth/change_password_dialog.dart';
import 'operator_feed_provider.dart';
import 'operator_stats_provider.dart';

enum _OperatorMenuAction { refresh, toggleTheme, changePassword, logout }

class OperatorDashboardScreen extends ConsumerWidget {
  const OperatorDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      const _OperatorHomeView();
}

class _OperatorHomeView extends ConsumerStatefulWidget {
  const _OperatorHomeView();

  @override
  ConsumerState<_OperatorHomeView> createState() => _OperatorHomeViewState();
}

class _OperatorHomeViewState extends ConsumerState<_OperatorHomeView>
    with WidgetsBindingObserver {
  final ScrollController _scrollController = ScrollController();
  final NumberFormat _countFormat = NumberFormat.decimalPattern();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_handleScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshAll();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshAll();
    }
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) return;

    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 220) {
      ref.read(operatorFeedControllerProvider.notifier).loadMore();
    }
  }

  Future<void> _refreshAll() async {
    await Future.wait([
      ref.read(operatorFeedControllerProvider.notifier).refresh(),
      ref.refresh(operatorStatsProvider.future),
      ref.refresh(operatorProductivitySnapshotProvider.future),
    ]);
  }

  String _formatError(Object error) {
    final raw = error.toString();
    const prefix = 'Exception:';
    if (raw.startsWith(prefix)) {
      return raw.substring(prefix.length).trim();
    }
    return raw;
  }

  void _handleMenuAction(_OperatorMenuAction action) {
    switch (action) {
      case _OperatorMenuAction.refresh:
        _refreshAll();
        break;
      case _OperatorMenuAction.toggleTheme:
        ref.read(themeModeProvider.notifier).toggleThemeMode();
        break;
      case _OperatorMenuAction.changePassword:
        showChangePasswordDialog(context, ref);
        break;
      case _OperatorMenuAction.logout:
        ref.read(authControllerProvider.notifier).logout();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final feedStateAsync = ref.watch(operatorFeedControllerProvider);
    final statsAsync = ref.watch(operatorStatsProvider);
    final productivityAsync = ref.watch(operatorProductivitySnapshotProvider);
    final authState = ref.watch(authControllerProvider);
    final themeMode = ref.watch(themeModeProvider);
    final user = authState.asData?.value;
    final name = user?.name.trim() ?? '';
    final username = user?.username.trim() ?? '';
    final displayName = name.isNotEmpty
        ? name
        : username.isNotEmpty
        ? username
        : 'Operator';
    final isDarkMode = themeMode == ThemeMode.dark;
    final isCompactAppBar = MediaQuery.of(context).size.width < 760;
    final userInitial = displayName.isEmpty
        ? 'U'
        : displayName[0].toUpperCase();

    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: const Text('Operator Dashboard'),
        actions: isCompactAppBar
            ? [
                PopupMenuButton<_OperatorMenuAction>(
                  tooltip: displayName,
                  onSelected: _handleMenuAction,
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      enabled: false,
                      child: Text(
                        displayName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: _OperatorMenuAction.refresh,
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.refresh),
                        title: Text('Refresh'),
                      ),
                    ),
                    PopupMenuItem(
                      value: _OperatorMenuAction.toggleTheme,
                      child: ListTile(
                        dense: true,
                        leading: Icon(
                          isDarkMode
                              ? Icons.light_mode_outlined
                              : Icons.dark_mode_outlined,
                        ),
                        title: Text(isDarkMode ? 'Light Mode' : 'Dark Mode'),
                      ),
                    ),
                    const PopupMenuItem(
                      value: _OperatorMenuAction.changePassword,
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.lock_reset_outlined),
                        title: Text('Change Password'),
                      ),
                    ),
                    const PopupMenuItem(
                      value: _OperatorMenuAction.logout,
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.logout),
                        title: Text('Logout'),
                      ),
                    ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.14),
                      child: Text(
                        userInitial,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
              ]
            : [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    alignment: Alignment.center,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 120),
                      child: Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _refreshAll,
                  tooltip: 'Refresh',
                ),
                IconButton(
                  icon: Icon(
                    isDarkMode
                        ? Icons.light_mode_outlined
                        : Icons.dark_mode_outlined,
                  ),
                  onPressed: () =>
                      ref.read(themeModeProvider.notifier).toggleThemeMode(),
                  tooltip: isDarkMode
                      ? 'Switch to light mode'
                      : 'Switch to dark mode',
                ),
                IconButton(
                  icon: const Icon(Icons.lock_reset_outlined),
                  onPressed: () => showChangePasswordDialog(context, ref),
                  tooltip: 'Change Password',
                ),
                IconButton(
                  icon: const Icon(Icons.logout),
                  onPressed: () {
                    ref.read(authControllerProvider.notifier).logout();
                  },
                  tooltip: 'Logout',
                ),
              ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [VistarPalette.bg, VistarPalette.bg2, VistarPalette.bg],
          ),
        ),
        child: RefreshIndicator(
          onRefresh: _refreshAll,
          child: ListView(
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            children: [
              _HeroStatsBanner(
                statsAsync: statsAsync,
                countFormat: _countFormat,
              ),
              const SizedBox(height: 20),
              Text(
                'Performance Snapshot',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              statsAsync.when(
                loading: () => const _StatsLoadingView(),
                error: (error, _) => _SectionErrorCard(
                  title: 'Could not load stats',
                  message: _formatError(error),
                  onRetry: () => ref.refresh(operatorStatsProvider),
                ),
                data: (stats) =>
                    _OperatorStatsGrid(stats: stats, countFormat: _countFormat),
              ),
              const SizedBox(height: 12),
              productivityAsync.when(
                loading: () => const _ProductivitySnapshotLoadingCard(),
                error: (error, _) => _SectionErrorCard(
                  title: 'Could not load productivity snapshot',
                  message: _formatError(error),
                  onRetry: () =>
                      ref.refresh(operatorProductivitySnapshotProvider),
                ),
                data: (snapshot) => _ProductivitySnapshotCard(
                  snapshot: snapshot,
                  countFormat: _countFormat,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Recent Entries',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              feedStateAsync.when(
                loading: () => const _EntriesLoadingView(),
                error: (error, _) => _SectionErrorCard(
                  title: 'Could not load recent entries',
                  message: _formatError(error),
                  onRetry: () => ref
                      .read(operatorFeedControllerProvider.notifier)
                      .refresh(),
                ),
                data: (feed) {
                  if (feed.entries.isEmpty) {
                    return const _SectionEmptyCard(
                      title: 'No submissions yet',
                      subtitle:
                          'Tap "Log Shift" to add your first production log.',
                    );
                  }

                  return Column(
                    children: [
                      for (final entry in feed.entries)
                        _OperatorEntryCard(entry: entry),
                      if (feed.isLoadingMore)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: _EntriesLoadMoreShimmer(),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await context.push('/new-entry');
          if (!mounted) return;
          await _refreshAll();
        },
        label: const Text('Log Shift'),
        icon: const Icon(Icons.add_task),
      ),
    );
  }
}

class _HeroStatsBanner extends StatelessWidget {
  final AsyncValue<OperatorStats> statsAsync;
  final NumberFormat countFormat;

  const _HeroStatsBanner({required this.statsAsync, required this.countFormat});

  @override
  Widget build(BuildContext context) {
    final stats = statsAsync.asData?.value;
    final totalProduction = stats?.totalProduction ?? 0;
    final totalProductionWeight = stats?.totalProductionWeight ?? 0;
    final totalRejection = stats?.totalRejection ?? 0;
    final totalRejectionWeight = stats?.totalRejectionWeight ?? 0;
    final avgParts = stats?.averagePartsPerHour ?? 0;
    final weightPerRunningHour = stats?.totalRunningHoursWeight ?? 0;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: VistarPalette.heroGradient,
        boxShadow: [
          BoxShadow(
            color: VistarPalette.purple.withValues(alpha: 0.24),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Today at a glance',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Track your output and maintain quality targets in real time.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.white.withValues(alpha: 0.9),
              height: 1.35,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _HeroBadge(
                label: 'Production',
                value: countFormat.format(totalProduction),
                subtitle: '${totalProductionWeight.toStringAsFixed(3)} kg',
              ),
              _HeroBadge(
                label: 'Rejection',
                value: countFormat.format(totalRejection),
                subtitle: '${totalRejectionWeight.toStringAsFixed(3)} kg',
              ),
              _HeroBadge(
                label: 'Avg Parts/Hr',
                value: avgParts.toStringAsFixed(1),
                subtitle: '${weightPerRunningHour.toStringAsFixed(2)} kg/hr',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroBadge extends StatelessWidget {
  final String label;
  final String value;
  final String? subtitle;

  const _HeroBadge({required this.label, required this.value, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 17,
            ),
          ),
          if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              style: const TextStyle(
                color: Colors.white70,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _OperatorStatsGrid extends StatelessWidget {
  final OperatorStats stats;
  final NumberFormat countFormat;

  const _OperatorStatsGrid({required this.stats, required this.countFormat});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final bool twoColumns = constraints.maxWidth > 640;
            final double cardWidth = twoColumns
                ? (constraints.maxWidth - 12) / 2
                : constraints.maxWidth;

            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SizedBox(
                  width: cardWidth,
                  child: _StatCard(
                    title: 'Total Production',
                    value: countFormat.format(stats.totalProduction),
                    subtitle:
                        'Weight: ${stats.totalProductionWeight.toStringAsFixed(3)} kg',
                    icon: Icons.inventory_2_outlined,
                    color: VistarPalette.primary,
                  ),
                ),
                SizedBox(
                  width: cardWidth,
                  child: _StatCard(
                    title: 'Total Rejection',
                    value: countFormat.format(stats.totalRejection),
                    subtitle:
                        'Weight: ${stats.totalRejectionWeight.toStringAsFixed(3)} kg',
                    icon: Icons.rule_folder_outlined,
                    color: VistarPalette.bad,
                  ),
                ),
                SizedBox(
                  width: cardWidth,
                  child: _StatCard(
                    title: 'Running Hours',
                    value: '${stats.totalRunningHours.toStringAsFixed(2)} h',
                    subtitle:
                        'Weight rate: ${stats.totalRunningHoursWeight.toStringAsFixed(2)} kg/hr',
                    icon: Icons.timer_outlined,
                    color: VistarPalette.ok,
                  ),
                ),
                SizedBox(
                  width: cardWidth,
                  child: _StatCard(
                    title: 'Average Parts/Hr',
                    value: stats.averagePartsPerHour.toStringAsFixed(1),
                    subtitle: 'Average throughput',
                    icon: Icons.speed_outlined,
                    color: const Color(0xFF7A4DCC),
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        _RejectionReasonCard(
          rejectionReasons: stats.rejectionReasons,
          countFormat: countFormat,
        ),
      ],
    );
  }
}

class _ProductivitySnapshotCard extends StatelessWidget {
  final OperatorProductivitySnapshot snapshot;
  final NumberFormat countFormat;

  const _ProductivitySnapshotCard({
    required this.snapshot,
    required this.countFormat,
  });

  String _formatDate(String rawDate) {
    final parsed = DateTime.tryParse(rawDate);
    if (parsed == null) return rawDate.trim().isEmpty ? '-' : rawDate;
    return DateFormat('dd MMM yyyy').format(parsed.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    final previousShift = snapshot.previousShift;
    final previousTitle = previousShift == null
        ? 'Previous Shift'
        : 'Previous Shift ${previousShift.shift.trim().isEmpty ? '' : previousShift.shift}'
              .trim();
    final previousSubtitle = previousShift == null
        ? 'No completed shift found'
        : _formatDate(previousShift.entryDate);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VistarPalette.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: VistarPalette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFF00897B).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.trending_up_outlined,
                  color: Color(0xFF00897B),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Productivity Snapshot',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final twoColumns = constraints.maxWidth > 640;
              final cardWidth = twoColumns
                  ? (constraints.maxWidth - 10) / 2
                  : constraints.maxWidth;

              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  SizedBox(
                    width: cardWidth,
                    child: _ProductivityMiniCard(
                      title: 'Yesterday',
                      subtitle: snapshot.yesterday.hasData
                          ? '${countFormat.format(snapshot.yesterday.totalProduction)} pieces | ${snapshot.yesterday.totalRunningHours.toStringAsFixed(2)} h'
                          : 'No production found',
                      metric: snapshot.yesterday,
                      countFormat: countFormat,
                    ),
                  ),
                  SizedBox(
                    width: cardWidth,
                    child: _ProductivityMiniCard(
                      title: previousTitle,
                      subtitle: previousSubtitle,
                      metric: previousShift?.metric,
                      countFormat: countFormat,
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ProductivityMiniCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final OperatorProductivityMetric? metric;
  final NumberFormat countFormat;

  const _ProductivityMiniCard({
    required this.title,
    required this.subtitle,
    required this.metric,
    required this.countFormat,
  });

  @override
  Widget build(BuildContext context) {
    final value = metric == null || !metric!.hasData
        ? '-'
        : countFormat.format(metric!.piecesPerHour);
    final kgRate = metric == null || !metric!.hasData
        ? '- kg/hr'
        : '${metric!.kgPerHour.toStringAsFixed(2)} kg/hr';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: VistarPalette.surface2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: VistarPalette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: VistarPalette.txt2,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '$value pieces/hr',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          Text(
            kgRate,
            style: const TextStyle(
              color: Color(0xFF00897B),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: VistarPalette.txt2,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProductivitySnapshotLoadingCard extends StatelessWidget {
  const _ProductivitySnapshotLoadingCard();

  @override
  Widget build(BuildContext context) {
    return AppShimmer(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: VistarPalette.surface,
          borderRadius: BorderRadius.circular(18),
        ),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SkeletonBox(height: 42, width: 42),
                SizedBox(width: 12),
                SkeletonBox(height: 18, width: 190),
              ],
            ),
            SizedBox(height: 14),
            SkeletonBox(height: 74),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final String subtitle;
  final IconData icon;
  final Color color;

  const _StatCard({
    required this.title,
    required this.value,
    required this.subtitle,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VistarPalette.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: VistarPalette.line),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: VistarPalette.txt2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: VistarPalette.txt2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RejectionReasonCard extends StatelessWidget {
  final List<OperatorRejectionReason> rejectionReasons;
  final NumberFormat countFormat;

  const _RejectionReasonCard({
    required this.rejectionReasons,
    required this.countFormat,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VistarPalette.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: VistarPalette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Rejection Reasons',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          if (rejectionReasons.isEmpty)
            Text(
              'No rejection reasons recorded.',
              style: TextStyle(color: VistarPalette.txt2),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: rejectionReasons
                  .map(
                    (reason) => Chip(
                      label: Text(
                        '${reason.reason}: ${countFormat.format(reason.count)} (${reason.weight.toStringAsFixed(3)} kg)',
                      ),
                      backgroundColor: VistarPalette.badBg,
                      side: BorderSide(color: VistarPalette.badLine),
                      labelStyle: TextStyle(
                        color: VistarPalette.badInk,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                  .toList(),
            ),
        ],
      ),
    );
  }
}

class _StatsLoadingView extends StatelessWidget {
  const _StatsLoadingView();

  @override
  Widget build(BuildContext context) {
    return AppShimmer(
      child: Column(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final twoColumns = constraints.maxWidth > 640;
              final cardWidth = twoColumns
                  ? (constraints.maxWidth - 12) / 2
                  : constraints.maxWidth;

              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: List.generate(
                  4,
                  (_) => SizedBox(
                    width: cardWidth,
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: VistarPalette.surface,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: const Row(
                        children: [
                          SkeletonBox(height: 44, width: 44),
                          SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SkeletonBox(height: 12, width: 110),
                                SizedBox(height: 8),
                                SkeletonBox(height: 18, width: 100),
                                SizedBox(height: 8),
                                SkeletonBox(height: 11, width: 130),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: VistarPalette.surface,
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBox(height: 16, width: 150),
                SizedBox(height: 10),
                SkeletonBox(height: 28),
                SizedBox(height: 8),
                SkeletonBox(height: 28),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EntriesLoadingView extends StatelessWidget {
  const _EntriesLoadingView();

  @override
  Widget build(BuildContext context) {
    return AppShimmer(
      child: Column(
        children: List.generate(
          3,
          (_) => Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: VistarPalette.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: VistarPalette.line),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBox(height: 14, width: 240),
                SizedBox(height: 8),
                SkeletonBox(height: 12, width: 220),
                SizedBox(height: 8),
                SkeletonBox(height: 12, width: 200),
                SizedBox(height: 8),
                SkeletonBox(height: 12, width: 230),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EntriesLoadMoreShimmer extends StatelessWidget {
  const _EntriesLoadMoreShimmer();

  @override
  Widget build(BuildContext context) {
    return const AppShimmer(
      child: SkeletonBox(
        height: 52,
        borderRadius: BorderRadius.all(Radius.circular(14)),
      ),
    );
  }
}

class _SectionErrorCard extends StatelessWidget {
  final String title;
  final String message;
  final VoidCallback onRetry;

  const _SectionErrorCard({
    required this.title,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VistarPalette.badBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: VistarPalette.badLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: VistarPalette.bad,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(message, style: TextStyle(color: VistarPalette.badInk)),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _SectionEmptyCard extends StatelessWidget {
  final String title;
  final String subtitle;

  const _SectionEmptyCard({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: VistarPalette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: VistarPalette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(subtitle, style: TextStyle(color: VistarPalette.txt2)),
        ],
      ),
    );
  }
}

class _OperatorEntryCard extends StatelessWidget {
  final ProductionEntryModel entry;

  const _OperatorEntryCard({required this.entry});

  String _safeValue(String value) => value.trim().isEmpty ? '-' : value;

  String _formatDate(String rawDate) {
    final parsed = DateTime.tryParse(rawDate);
    if (parsed == null) return rawDate.trim().isEmpty ? '-' : rawDate;
    return DateFormat('dd MMM yyyy').format(parsed);
  }

  @override
  Widget build(BuildContext context) {
    final approval = _safeValue(entry.approvalStatus ?? 'Pending');
    final date = _formatDate(entry.entryDate);
    final machine = _safeValue(entry.machineName ?? entry.machineId);
    final item = _safeValue(entry.itemDescription ?? entry.itemId);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VistarPalette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: VistarPalette.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: VistarPalette.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              Icons.precision_manufacturing_outlined,
              color: VistarPalette.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$machine | $item',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  'Date: $date | Shift: ${_safeValue(entry.shift)}',
                  style: TextStyle(color: VistarPalette.txt2),
                ),
                const SizedBox(height: 3),
                Text(
                  'Actual Qty: ${entry.actualQuantity} | Rejection: ${entry.rejectionQuantity}',
                  style: TextStyle(color: VistarPalette.txt2),
                ),
                const SizedBox(height: 3),
                Text(
                  'Running Hours: ${entry.runningHours.toStringAsFixed(2)} | Parts/Hr: ${entry.partsPerHour.toStringAsFixed(1)}',
                  style: TextStyle(color: VistarPalette.txt2),
                ),
                const SizedBox(height: 3),
                Text(
                  'Weight (kg): ${entry.weightInKGs.toStringAsFixed(1)}',
                  style: TextStyle(color: VistarPalette.txt2),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _ApprovalStatusPill(status: approval),
        ],
      ),
    );
  }
}

class _ApprovalStatusPill extends StatelessWidget {
  final String status;

  const _ApprovalStatusPill({required this.status});

  @override
  Widget build(BuildContext context) {
    final normalized = status.toUpperCase();

    Color bgColor;
    Color textColor;

    if (normalized == 'APPROVED') {
      bgColor = VistarPalette.okBg;
      textColor = VistarPalette.ok;
    } else if (normalized == 'REJECTED') {
      bgColor = VistarPalette.badBg;
      textColor = VistarPalette.bad;
    } else {
      bgColor = VistarPalette.warnBg;
      textColor = VistarPalette.warn;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status,
        style: TextStyle(
          color: textColor,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}
