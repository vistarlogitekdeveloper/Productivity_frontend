import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/theme_mode_provider.dart';
import '../../core/theme/vistar_palette.dart';
import '../../core/widgets/shimmer_skeleton.dart';
import '../../features/auth/auth_provider.dart';
import '../../features/auth/change_password_dialog.dart';
import '../master_management/item_management_screen.dart';
import '../master_management/machine_management_screen.dart';
import '../user_management/user_management_screen.dart';
import '../reports/reports_list_screen.dart';
import '../reports/reports_provider.dart';
import '../reports/review_actions_screen.dart';
import 'admin_dashboard_provider.dart';
import 'shift_details_screen.dart';

enum _AdminMenuAction { refresh, toggleTheme, changePassword, logout }

class AdminDashboardScreen extends ConsumerStatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  ConsumerState<AdminDashboardScreen> createState() =>
      _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends ConsumerState<AdminDashboardScreen>
    with WidgetsBindingObserver {
  int _currentIndex = 0;
  final GlobalKey<ShiftDetailsScreenState> _shiftDetailsKey =
      GlobalKey<ShiftDetailsScreenState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshCurrentTabData();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _refreshCurrentTabData() {
    final role =
        ref
            .read(authControllerProvider)
            .asData
            ?.value
            ?.role ??
        '';
    final hasReviewActions = AppConstants.isSupervisorRole(role);

    if (_currentIndex == 0) {
      ref.read(adminDashboardControllerProvider.notifier).refresh();
      return;
    }

    if (_currentIndex == 1 || (_currentIndex == 2 && hasReviewActions)) {
      ref.read(reportsControllerProvider.notifier).fetchPage(0, 10);
      return;
    }

    if (_currentIndex == 3) {
      _shiftDetailsKey.currentState?.refresh();
    }
  }

  String _pageTitle({required bool isSupervisor}) {
    switch (_currentIndex) {
      case 0:
        return isSupervisor ? 'Supervisor Dashboard' : 'Admin Dashboard';
      case 1:
        return 'Reports';
      case 2:
        return isSupervisor ? 'Review Actions' : 'Management';
      case 3:
        return 'Shift Details';
      default:
        return 'Dashboard';
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshCurrentTabData();
    }
  }

  @override
  Widget build(BuildContext context) {
    final role =
        ref
            .watch(authControllerProvider)
            .asData
            ?.value
            ?.role ??
        '';
    final authState = ref.watch(authControllerProvider);
    final themeMode = ref.watch(themeModeProvider);
    final isDarkMode = themeMode == ThemeMode.dark;
    final user = authState.asData?.value;
    final name = user?.name.trim() ?? '';
    final username = user?.username.trim() ?? '';
    final displayName = name.isNotEmpty
        ? name
        : username.isNotEmpty
            ? username
            : (role.isNotEmpty ? role : 'User');
    final isCompactAppBar = MediaQuery.of(context).size.width < 760;
    final userInitial = displayName.isEmpty ? 'U' : displayName[0].toUpperCase();

    void handleMenuAction(_AdminMenuAction action) {
      switch (action) {
        case _AdminMenuAction.refresh:
          _refreshCurrentTabData();
          break;
        case _AdminMenuAction.toggleTheme:
          ref.read(themeModeProvider.notifier).toggleThemeMode();
          break;
        case _AdminMenuAction.changePassword:
          showChangePasswordDialog(context, ref);
          break;
        case _AdminMenuAction.logout:
          ref.read(authControllerProvider.notifier).logout();
          break;
      }
    }

    final isSupervisor = AppConstants.isSupervisorRole(role);
    final pages = <Widget>[
      const _AdminHomeView(embedded: true),
      const ReportsListScreen(embedded: true),
      isSupervisor
          ? const ReviewActionsScreen(embedded: true)
          : const _ManagementHubScreen(embedded: true),
      ShiftDetailsScreen(key: _shiftDetailsKey, embedded: true),
    ];
    final destinations = <NavigationDestination>[
      const NavigationDestination(
        icon: Icon(Icons.dashboard),
        label: 'Dashboard',
      ),
      const NavigationDestination(
        icon: Icon(Icons.bar_chart),
        label: 'Reports',
      ),
      NavigationDestination(
        icon: Icon(
          isSupervisor
              ? Icons.fact_check_outlined
              : Icons.manage_accounts_outlined,
        ),
        label: isSupervisor ? 'Review Actions' : 'Manage',
      ),
      const NavigationDestination(
        icon: Icon(Icons.event_note_outlined),
        label: 'Shift Details',
      ),
    ];
    final selectedIndex = _currentIndex >= pages.length
        ? pages.length - 1
        : _currentIndex;

    final showLogShiftFab = isSupervisor && selectedIndex == 0;

    return Scaffold(
      floatingActionButton: showLogShiftFab
          ? FloatingActionButton.extended(
              onPressed: () async {
                await context.push('/new-entry');
                if (!mounted) return;
                _refreshCurrentTabData();
              },
              label: const Text('Log Shift'),
              icon: const Icon(Icons.add_task),
            )
          : null,
      appBar: AppBar(
        centerTitle: false,
        title: Text(_pageTitle(isSupervisor: isSupervisor)),
        actions: isCompactAppBar
            ? [
                PopupMenuButton<_AdminMenuAction>(
                  tooltip: displayName,
                  onSelected: handleMenuAction,
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
                      value: _AdminMenuAction.refresh,
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.refresh),
                        title: Text('Refresh'),
                      ),
                    ),
                    PopupMenuItem(
                      value: _AdminMenuAction.toggleTheme,
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
                      value: _AdminMenuAction.changePassword,
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.lock_reset_outlined),
                        title: Text('Change Password'),
                      ),
                    ),
                    const PopupMenuItem(
                      value: _AdminMenuAction.logout,
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
                      backgroundColor:
                          Theme.of(context).colorScheme.primary.withValues(alpha: 0.14),
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
                      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.10),
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
                  onPressed: _refreshCurrentTabData,
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
                  tooltip:
                      isDarkMode ? 'Switch to light mode' : 'Switch to dark mode',
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
                ),
              ],
      ),
      body: pages[selectedIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: (i) {
          setState(() => _currentIndex = i);
          _refreshCurrentTabData();
        },
        destinations: destinations,
      ),
    );
  }
}

class _ManagementHubScreen extends StatelessWidget {
  final bool embedded;

  const _ManagementHubScreen({
    this.embedded = false,
  });

  @override
  Widget build(BuildContext context) {
    final modules = <_ManagementOption>[
      _ManagementOption(
        module: _ManagementModule.user,
        title: 'User Management',
        subtitle: 'Create, update, and organize user access.',
        icon: Icons.group_outlined,
        accent: VistarPalette.primary,
      ),
      _ManagementOption(
        module: _ManagementModule.machine,
        title: 'Machine Management',
        subtitle: 'Maintain machine records and production mapping.',
        icon: Icons.precision_manufacturing_outlined,
        accent: VistarPalette.ok,
      ),
      _ManagementOption(
        module: _ManagementModule.item,
        title: 'Item Management',
        subtitle: 'Manage item codes, descriptions, and master details.',
        icon: Icons.inventory_2_outlined,
        accent: Color(0xFF7A4DCC),
      ),
    ];

    final body = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [VistarPalette.bg, VistarPalette.bg2, VistarPalette.bg],
        ),
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          if (embedded)
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Text(
                'Management',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: VistarPalette.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: VistarPalette.line),
            ),
            child: Text(
              'Use these modules to maintain masters and control system setup.',
              style: TextStyle(color: VistarPalette.txt2),
            ),
          ),
          const SizedBox(height: 12),
          ...modules.map(
            (module) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ManagementOptionCard(
                option: module,
                onTap: () {
                  Widget screen;
                  switch (module.module) {
                    case _ManagementModule.user:
                      screen = const UserManagementScreen();
                      break;
                    case _ManagementModule.machine:
                      screen = const MachineManagementScreen();
                      break;
                    case _ManagementModule.item:
                      screen = const ItemManagementScreen();
                      break;
                  }
                  Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => screen));
                },
              ),
            ),
          ),
        ],
      ),
    );

    if (embedded) return body;

    return Scaffold(
      appBar: AppBar(title: const Text('Management')),
      body: body,
    );
  }
}

enum _ManagementModule { user, machine, item }

class _ManagementOption {
  final _ManagementModule module;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color accent;

  const _ManagementOption({
    required this.module,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accent,
  });
}

class _ManagementOptionCard extends StatelessWidget {
  final _ManagementOption option;
  final VoidCallback onTap;

  const _ManagementOptionCard({required this.option, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: VistarPalette.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: VistarPalette.line),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: option.accent.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(option.icon, color: option.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      option.subtitle,
                      style: TextStyle(color: VistarPalette.txt2),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios_rounded, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _AdminHomeView extends ConsumerWidget {
  final bool embedded;

  const _AdminHomeView({
    this.embedded = false,
  });

  String _getDashboardTitle(String role) {
    final normalized = AppConstants.normalizeRole(role);
    if (normalized == AppConstants.roleSupervisor) {
      return 'Supervisor Dashboard';
    }
    if (normalized == AppConstants.roleAdmin) return 'Admin Dashboard';
    return 'Dashboard';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dashboardState = ref.watch(adminDashboardControllerProvider);
    final authState = ref.watch(authControllerProvider);
    final themeMode = ref.watch(themeModeProvider);
    final countFormat = NumberFormat.decimalPattern();

    final user = authState.asData?.value;
    final role = user?.role ?? '';
    final name = user?.name.trim() ?? '';
    final username = user?.username.trim() ?? '';
    final displayName = name.isNotEmpty
        ? name
        : username.isNotEmpty
        ? username
        : (role.isNotEmpty ? role : 'User');
    final isDarkMode = themeMode == ThemeMode.dark;
    final isCompactAppBar = MediaQuery.of(context).size.width < 760;
    final userInitial = displayName.isEmpty
        ? 'U'
        : displayName[0].toUpperCase();

    void handleMenuAction(_AdminMenuAction action) {
      switch (action) {
        case _AdminMenuAction.refresh:
          ref.read(adminDashboardControllerProvider.notifier).refresh();
          break;
        case _AdminMenuAction.toggleTheme:
          ref.read(themeModeProvider.notifier).toggleThemeMode();
          break;
        case _AdminMenuAction.changePassword:
          showChangePasswordDialog(context, ref);
          break;
        case _AdminMenuAction.logout:
          ref.read(authControllerProvider.notifier).logout();
          break;
      }
    }

    final body = dashboardState.when(
      loading: () => const _AdminDashboardLoadingView(),
      error: (err, stack) => Center(child: Text('Error: $err')),
      data: (data) => RefreshIndicator(
        onRefresh: ref
            .read(adminDashboardControllerProvider.notifier)
            .refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildDateFilterPanel(
              context,
              ref,
              startDate: data.startDate,
              endDate: data.endDate,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _buildKPICard(
                  context,
                  'Total Production',
                  countFormat.format(data.kpi.totalProduction),
                  'Weight: ${data.kpi.totalProductionWeight.toStringAsFixed(3)} kg',
                  Icons.inventory_2_outlined,
                  VistarPalette.primary,
                ),
                _buildKPICard(
                  context,
                  'Total Rejection',
                  countFormat.format(data.kpi.totalRejection),
                  'Weight: ${data.kpi.totalRejectionWeight.toStringAsFixed(3)} kg',
                  Icons.rule_folder_outlined,
                  VistarPalette.bad,
                ),
                _buildKPICard(
                  context,
                  'Running Hours',
                  '${data.kpi.totalRunningHours.toStringAsFixed(2)} h',
                  'Weight rate: ${data.kpi.totalRunningHoursWeight.toStringAsFixed(2)} kg/hr',
                  Icons.timer_outlined,
                  VistarPalette.ok,
                ),
                _buildKPICard(
                  context,
                  'Average Parts/Hr',
                  data.kpi.averagePartsPerHour.toStringAsFixed(2),
                  'Average throughput',
                  Icons.speed_outlined,
                  const Color(0xFF7A4DCC),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const Text(
              'Machine Output',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 250,
              child: _buildMachineOutputChart(context, data.machineOutput),
            ),
            const SizedBox(height: 24),
            const Text(
              'Shift-wise Production',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 250,
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  // Auto-calculate maxY with a safe non-zero minimum.
                  maxY: _chartMaxY(data.shiftProduction),
                  titlesData: FlTitlesData(
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          int idx = value.toInt();
                          if (idx >= 0 && idx < data.shiftProduction.length) {
                            return SideTitleWidget(
                              meta: meta,
                              space: 8,
                              child: Text(
                                'Shift ${data.shiftProduction[idx].shift}',
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                            );
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  barGroups: data.shiftProduction.asMap().entries.map((
                    entry,
                  ) {
                    final i = entry.key;
                    final s = entry.value;
                    return BarChartGroupData(
                      x: i,
                      barRods: [
                        BarChartRodData(
                          toY: s.totalQuantity.toDouble(),
                          color: VistarPalette.info,
                          width: 22,
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ),
            const SizedBox(height: 32),
            const Text(
              'Rejection Reasons Distribution',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 250,
              child: data.rejectionReasons.isEmpty
                  ? const Center(child: Text('No rejections recorded.'))
                  : PieChart(
                      PieChartData(
                        sectionsSpace: 2,
                        centerSpaceRadius: 40,
                        sections: data.rejectionReasons.asMap().entries.map((
                          entry,
                        ) {
                          final colors = [
                            Colors.red.shade400,
                            Colors.orange.shade400,
                            Colors.yellow.shade600,
                            Colors.purple.shade300,
                            Colors.blueGrey,
                          ];
                          final r = entry.value;
                          return PieChartSectionData(
                            color: colors[entry.key % colors.length],
                            value: r.count.toDouble(),
                            title: '${r.count}\n${r.reason}',
                            radius: 50,
                            titleStyle: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          );
                        }).toList(),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );

    if (embedded) return body;

    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: Text(_getDashboardTitle(role)),
        actions: isCompactAppBar
            ? [
                PopupMenuButton<_AdminMenuAction>(
                  tooltip: displayName,
                  onSelected: handleMenuAction,
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
                      value: _AdminMenuAction.refresh,
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.refresh),
                        title: Text('Refresh'),
                      ),
                    ),
                    PopupMenuItem(
                      value: _AdminMenuAction.toggleTheme,
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
                      value: _AdminMenuAction.changePassword,
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.lock_reset_outlined),
                        title: Text('Change Password'),
                      ),
                    ),
                    const PopupMenuItem(
                      value: _AdminMenuAction.logout,
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
                  onPressed: () => ref
                      .read(adminDashboardControllerProvider.notifier)
                      .refresh(),
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
                ),
              ],
      ),
      body: body,
    );
  }

  Widget _buildDateFilterPanel(
    BuildContext context,
    WidgetRef ref, {
    required DateTime? startDate,
    required DateTime? endDate,
  }) {
    final dateFmt = DateFormat('dd MMM yyyy');
    final hasFilter = startDate != null || endDate != null;

    Future<void> pickStartDate() async {
      final picked = await showDatePicker(
        context: context,
        initialDate: startDate ?? endDate ?? DateTime.now(),
        firstDate: DateTime(2000),
        lastDate: DateTime(2100),
      );
      if (picked == null) return;
      final adjustedEnd = (endDate != null && endDate.isBefore(picked))
          ? picked
          : endDate;
      await ref
          .read(adminDashboardControllerProvider.notifier)
          .setDateRange(startDate: picked, endDate: adjustedEnd);
    }

    Future<void> pickEndDate() async {
      final picked = await showDatePicker(
        context: context,
        initialDate: endDate ?? startDate ?? DateTime.now(),
        firstDate: DateTime(2000),
        lastDate: DateTime(2100),
      );
      if (picked == null) return;
      final adjustedStart = (startDate != null && startDate.isAfter(picked))
          ? picked
          : startDate;
      await ref
          .read(adminDashboardControllerProvider.notifier)
          .setDateRange(startDate: adjustedStart, endDate: picked);
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: VistarPalette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: VistarPalette.line),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            onPressed: pickStartDate,
            icon: const Icon(Icons.date_range_outlined),
            label: Text(
              startDate == null
                  ? 'Start Date'
                  : 'Start: ${dateFmt.format(startDate)}',
            ),
          ),
          OutlinedButton.icon(
            onPressed: pickEndDate,
            icon: const Icon(Icons.event_outlined),
            label: Text(
              endDate == null ? 'End Date' : 'End: ${dateFmt.format(endDate)}',
            ),
          ),
          if (hasFilter)
            TextButton.icon(
              onPressed: () => ref
                  .read(adminDashboardControllerProvider.notifier)
                  .setDateRange(),
              icon: const Icon(Icons.clear),
              label: const Text('Clear Filter'),
            ),
        ],
      ),
    );
  }


  Widget _buildMachineOutputChart(
    BuildContext context,
    List<MachineOutputData> machines,
  ) {
    if (machines.isEmpty) {
      return const Center(child: Text('No machine output data found.'));
    }

    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: _chartMaxYFromValues(machines.map((e) => e.value)),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                final idx = value.toInt();
                if (idx < 0 || idx >= machines.length) {
                  return const SizedBox.shrink();
                }
                final label = machines[idx].machineNumber.trim().isNotEmpty
                    ? machines[idx].machineNumber
                    : machines[idx].name;
                return SideTitleWidget(
                  meta: meta,
                  space: 8,
                  child: Text(
                    _shortLabel(label, maxLength: 8),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                      fontSize: 11,
                    ),
                  ),
                );
              },
            ),
          ),
          leftTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: true, reservedSize: 34),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
        ),
        borderData: FlBorderData(show: false),
        barGroups: machines.asMap().entries.map((entry) {
          final i = entry.key;
          final e = entry.value;
          return BarChartGroupData(
            x: i,
            barRods: [
              BarChartRodData(
                toY: e.value.toDouble(),
                color: VistarPalette.primary,
                width: 18,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(4),
                ),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _buildKPICard(
    BuildContext context,
    String title,
    String value,
    String subtitle,
    IconData icon,
    Color color,
  ) {
    final width = MediaQuery.of(context).size.width;
    final cardWidth = width > 900
        ? (width - 56) / 4
        : width > 640
        ? (width - 44) / 2
        : (width - 44) / 2;
    return SizedBox(
      width: cardWidth,
      child: Card(
        elevation: 1,
        child: Padding(
          padding: const EdgeInsets.all(14),
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
                    const SizedBox(height: 2),
                    Text(
                      value,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
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
        ),
      ),
    );
  }

  double _chartMaxY(List<ShiftProduction> shifts) {
    if (shifts.isEmpty) return 10;
    final maxValue = shifts
        .map((e) => e.totalQuantity)
        .reduce((a, b) => a > b ? a : b)
        .toDouble();
    final scaled = maxValue * 1.2;
    return scaled < 10 ? 10 : scaled;
  }

  double _chartMaxYFromValues(Iterable<int> values) {
    if (values.isEmpty) return 10;
    final maxValue = values.reduce((a, b) => a > b ? a : b).toDouble();
    final scaled = maxValue * 1.2;
    return scaled < 10 ? 10 : scaled;
  }

  String _shortLabel(String value, {int maxLength = 8}) {
    final text = value.trim();
    if (text.isEmpty) return '-';
    if (text.length <= maxLength) return text;
    return '${text.substring(0, maxLength)}...';
  }
}

class _AdminDashboardLoadingView extends StatelessWidget {
  const _AdminDashboardLoadingView();

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final cardWidth = width > 900
        ? (width - 56) / 4
        : width > 640
            ? (width - 44) / 2
            : (width - 44) / 2;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        AppShimmer(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: VistarPalette.surface,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    SkeletonBox(height: 40, width: 170),
                    SkeletonBox(height: 40, width: 170),
                    SkeletonBox(height: 40, width: 130),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
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
                        borderRadius: BorderRadius.circular(12),
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
                                SkeletonBox(height: 16, width: 90),
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
              ),
              const SizedBox(height: 24),
              const SkeletonBox(height: 20, width: 150),
              const SizedBox(height: 16),
              Container(
                height: 250,
                decoration: BoxDecoration(
                  color: VistarPalette.surface,
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              const SizedBox(height: 24),
              const SkeletonBox(height: 20, width: 170),
              const SizedBox(height: 16),
              Container(
                height: 250,
                decoration: BoxDecoration(
                  color: VistarPalette.surface,
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              const SizedBox(height: 24),
              const SkeletonBox(height: 20, width: 230),
              const SizedBox(height: 16),
              Container(
                height: 250,
                decoration: BoxDecoration(
                  color: VistarPalette.surface,
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
