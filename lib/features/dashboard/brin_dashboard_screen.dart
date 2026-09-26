import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme/theme_mode_provider.dart';
import '../../core/theme/vistar_palette.dart';
import '../../core/widgets/shimmer_skeleton.dart';
import '../../data/models/production_entry_model.dart';
import '../auth/auth_provider.dart';
import '../auth/change_password_dialog.dart';
import 'brin_management_provider.dart';

enum _BrinMenuAction { refresh, toggleTheme, changePassword, logout }

class BrinDashboardScreen extends ConsumerStatefulWidget {
  const BrinDashboardScreen({super.key});

  @override
  ConsumerState<BrinDashboardScreen> createState() =>
      _BrinDashboardScreenState();
}

class _BrinDashboardScreenState extends ConsumerState<BrinDashboardScreen>
    with WidgetsBindingObserver {
  final TextEditingController _rcSearchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshAll());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _rcSearchCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshAll();
    }
  }

  Future<void> _refreshAll() async {
    final brinState = ref.read(brinManagementControllerProvider);
    final activeRcNumber = brinState.activeRcNumber;

    await Future.wait([
      ref
          .read(brinManagementControllerProvider.notifier)
          .fetchRcSummary(range: brinState.summaryRange),
      if (activeRcNumber != null && activeRcNumber.trim().isNotEmpty)
        ref
            .read(brinManagementControllerProvider.notifier)
            .searchByRcNumber(activeRcNumber),
    ]);
  }

  String _cleanError(Object error) {
    final raw = error.toString();
    const prefix = 'Exception:';
    return raw.startsWith(prefix) ? raw.substring(prefix.length).trim() : raw;
  }

  String _safeValue(String? value) {
    final text = (value ?? '').trim();
    return text.isEmpty ? '-' : text;
  }

  String _formatDate(String rawDate) {
    final parsed = DateTime.tryParse(rawDate);
    if (parsed == null) return rawDate.trim().isEmpty ? '-' : rawDate;
    return DateFormat('dd MMM yyyy').format(parsed);
  }

  String _formatNumber(int value) {
    return NumberFormat.decimalPattern().format(value);
  }

  String _summarizeLocation(List<ProductionEntryModel> entries) {
    final locations = entries
        .map((entry) => (entry.location ?? '').trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList();

    if (locations.isEmpty) return 'Not assigned';
    if (locations.length == 1) return locations.first;
    return 'Multiple locations';
  }

  void _handleMenuAction(_BrinMenuAction action) {
    switch (action) {
      case _BrinMenuAction.refresh:
        _refreshAll();
        break;
      case _BrinMenuAction.toggleTheme:
        ref.read(themeModeProvider.notifier).toggleThemeMode();
        break;
      case _BrinMenuAction.changePassword:
        showChangePasswordDialog(context, ref);
        break;
      case _BrinMenuAction.logout:
        ref.read(authControllerProvider.notifier).logout();
        break;
    }
  }

  Future<void> _changeSummaryRange(BrinSummaryRange range) async {
    await ref
        .read(brinManagementControllerProvider.notifier)
        .fetchRcSummary(range: range);
  }

  Future<void> _searchRc() async {
    await ref
        .read(brinManagementControllerProvider.notifier)
        .searchByRcNumber(_rcSearchCtrl.text);
  }

  Future<void> _openLocationDialog(BrinManagementState brinState) async {
    final rcNumber = brinState.activeRcNumber;
    if (rcNumber == null || rcNumber.trim().isEmpty) return;

    final nextLocation = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _LocationUpdateDialog(
        rcNumber: rcNumber,
        initialLocation: _summarizeLocation(brinState.entries),
      ),
    );

    if (nextLocation == null) return;

    try {
      await ref
          .read(brinManagementControllerProvider.notifier)
          .updateLocation(rcNumber: rcNumber, location: nextLocation);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Location updated for RC $rcNumber.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_cleanError(e))));
    }
  }

  Future<void> _openQuantityDialog(ProductionEntryModel entry) async {
    final entryId = entry.id;
    if (entryId == null || entryId.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This entry cannot be edited right now.')),
      );
      return;
    }

    final result = await showDialog<_QuantityUpdateResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _QuantityUpdateDialog(entry: entry),
    );

    if (result == null) return;

    try {
      await ref
          .read(brinManagementControllerProvider.notifier)
          .updateQuantity(
            entryId: entryId,
            quantity: result.quantity,
            comment: result.comment,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Quantity updated successfully.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_cleanError(e))));
    }
  }

  Widget _sectionCard(Widget child) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VistarPalette.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: VistarPalette.line),
      ),
      child: child,
    );
  }

  Widget _buildRcManagementSection(BrinManagementState brinState) {
    final entries = brinState.entries;
    final totalQty = entries.fold<int>(
      0,
      (sum, entry) => sum + entry.actualQuantity,
    );
    final totalReject = entries.fold<int>(
      0,
      (sum, entry) => sum + entry.rejectionQuantity,
    );
    final locationSummary = _summarizeLocation(entries);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'RC Management',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        _sectionCard(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Search by RC number to assign a location and edit logged quantities with audit comments.',
                style: TextStyle(color: VistarPalette.txt2),
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 620;
                  final searchField = TextField(
                    controller: _rcSearchCtrl,
                    onChanged: ref
                        .read(brinManagementControllerProvider.notifier)
                        .setQuery,
                    onSubmitted: (_) => _searchRc(),
                    decoration: const InputDecoration(
                      labelText: 'RC Number',
                      hintText: 'Enter RC number',
                      prefixIcon: Icon(Icons.qr_code_2_outlined),
                    ),
                  );
                  final searchButton = FilledButton.icon(
                    onPressed: brinState.isLoading ? null : _searchRc,
                    icon: const Icon(Icons.search),
                    label: const Text('Search'),
                  );
                  final clearButton = OutlinedButton.icon(
                    onPressed: () {
                      _rcSearchCtrl.clear();
                      ref
                          .read(brinManagementControllerProvider.notifier)
                          .clearSearch();
                    },
                    icon: const Icon(Icons.clear),
                    label: const Text('Clear'),
                  );

                  if (compact) {
                    return Column(
                      children: [
                        searchField,
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(child: searchButton),
                            const SizedBox(width: 10),
                            Expanded(child: clearButton),
                          ],
                        ),
                      ],
                    );
                  }

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: searchField),
                      const SizedBox(width: 10),
                      searchButton,
                      const SizedBox(width: 10),
                      clearButton,
                    ],
                  );
                },
              ),
              if (brinState.errorMessage != null) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: VistarPalette.badBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: VistarPalette.badLine),
                  ),
                  child: Text(
                    brinState.errorMessage!,
                    style: TextStyle(
                      color: VistarPalette.badInk,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (brinState.isLoading)
          const AppShimmer(
            child: SkeletonBox(
              height: 180,
              borderRadius: BorderRadius.all(Radius.circular(18)),
            ),
          )
        else if (brinState.activeRcNumber != null &&
            brinState.activeRcNumber!.trim().isNotEmpty &&
            entries.isEmpty)
          _sectionCard(
            Text(
              'No entries found for RC ${brinState.activeRcNumber}.',
              style: TextStyle(color: VistarPalette.txt2),
            ),
          )
        else if (entries.isNotEmpty) ...[
          _sectionCard(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'RC ${brinState.activeRcNumber}',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: brinState.isSubmitting
                          ? null
                          : () => _openLocationDialog(brinState),
                      icon: const Icon(Icons.edit_location_alt_outlined),
                      label: const Text('Update Location'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _InfoChip(
                      icon: Icons.inventory_2_outlined,
                      label: 'Entries',
                      value: entries.length.toString(),
                    ),
                    _InfoChip(
                      icon: Icons.scale_outlined,
                      label: 'Actual Qty',
                      value: totalQty.toString(),
                    ),
                    _InfoChip(
                      icon: Icons.report_problem_outlined,
                      label: 'Rejected',
                      value: totalReject.toString(),
                    ),
                    _InfoChip(
                      icon: Icons.location_on_outlined,
                      label: 'Location',
                      value: locationSummary,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          ...entries.map(
            (entry) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _BrinRcEntryCard(
                entry: entry,
                onEditQuantity: entry.id == null || brinState.isSubmitting
                    ? null
                    : () => _openQuantityDialog(entry),
                formatDate: _formatDate,
                safeValue: _safeValue,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildRcSummarySection(BrinManagementState brinState) {
    final summaryItems = brinState.rcSummary;
    final totalActual = summaryItems.fold<int>(
      0,
      (sum, item) => sum + item.totalActualQuantity,
    );
    final totalCorrected = summaryItems.fold<int>(
      0,
      (sum, item) => sum + item.totalCorrectedQuantity,
    );
    final uniqueRcCount = summaryItems
        .map((item) => item.rcNumber.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'RC-wise Summary',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        _sectionCard(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Track RC totals by date range and compare actual versus corrected quantities before drilling into individual RC entries.',
                style: TextStyle(color: VistarPalette.txt2),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final range in BrinSummaryRange.values)
                    ChoiceChip(
                      label: Text(range.label),
                      selected: brinState.summaryRange == range,
                      onSelected: brinState.isSummaryLoading &&
                              brinState.summaryRange == range
                          ? null
                          : (_) => _changeSummaryRange(range),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 720;
                  final metrics = [
                    _SummaryMetricCard(
                      label: 'Rows',
                      value: _formatNumber(summaryItems.length),
                      icon: Icons.table_rows_outlined,
                    ),
                    _SummaryMetricCard(
                      label: 'RCs',
                      value: _formatNumber(uniqueRcCount),
                      icon: Icons.qr_code_2_outlined,
                    ),
                    _SummaryMetricCard(
                      label: 'Actual Qty',
                      value: _formatNumber(totalActual),
                      icon: Icons.scale_outlined,
                    ),
                    _SummaryMetricCard(
                      label: 'Corrected Qty',
                      value: _formatNumber(totalCorrected),
                      icon: Icons.rule_folder_outlined,
                    ),
                  ];

                  if (compact) {
                    return Column(
                      children: [
                        for (final metric in metrics) ...[
                          metric,
                          if (metric != metrics.last) const SizedBox(height: 10),
                        ],
                      ],
                    );
                  }

                  return Row(
                    children: [
                      for (var i = 0; i < metrics.length; i++) ...[
                        Expanded(child: metrics[i]),
                        if (i != metrics.length - 1) const SizedBox(width: 10),
                      ],
                    ],
                  );
                },
              ),
              if (brinState.summaryErrorMessage != null) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: VistarPalette.badBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: VistarPalette.badLine),
                  ),
                  child: Text(
                    brinState.summaryErrorMessage!,
                    style: TextStyle(
                      color: VistarPalette.badInk,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              if (brinState.isSummaryLoading && summaryItems.isEmpty)
                const AppShimmer(
                  child: SkeletonBox(
                    height: 180,
                    borderRadius: BorderRadius.all(Radius.circular(18)),
                  ),
                )
              else if (summaryItems.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: VistarPalette.surface2,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: VistarPalette.line),
                  ),
                  child: Text(
                    'No RC summary data available for ${brinState.summaryRange.label.toLowerCase()}.',
                    style: TextStyle(color: VistarPalette.txt2),
                  ),
                )
              else
                LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 900;
                    if (compact) {
                      return Column(
                        children: [
                          for (var i = 0; i < summaryItems.length; i++) ...[
                            _BrinRcSummaryCard(
                              item: summaryItems[i],
                              safeValue: _safeValue,
                              formatNumber: _formatNumber,
                            ),
                            if (i != summaryItems.length - 1)
                              const SizedBox(height: 10),
                          ],
                        ],
                      );
                    }

                    return Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: VistarPalette.surface2,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: VistarPalette.line),
                      ),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          horizontalMargin: 10,
                          columnSpacing: 18,
                          headingRowColor: WidgetStateProperty.all(
                            VistarPalette.surface3,
                          ),
                          columns: const [
                            DataColumn(label: Text('RC Number')),
                            DataColumn(label: Text('Item Code')),
                            DataColumn(label: Text('Location')),
                            DataColumn(label: Text('Actual Qty')),
                            DataColumn(label: Text('Corrected Qty')),
                          ],
                          rows: summaryItems.map((item) {
                            return DataRow(
                              cells: [
                                DataCell(
                                  Text(
                                    _safeValue(item.rcNumber),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                DataCell(Text(_safeValue(item.itemCode))),
                                DataCell(
                                  SizedBox(
                                    width: 180,
                                    child: Text(
                                      _safeValue(item.location),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                DataCell(
                                  Text(_formatNumber(item.totalActualQuantity)),
                                ),
                                DataCell(
                                  Text(
                                    _formatNumber(item.totalCorrectedQuantity),
                                  ),
                                ),
                              ],
                            );
                          }).toList(),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final brinState = ref.watch(brinManagementControllerProvider);
    final authState = ref.watch(authControllerProvider);
    final themeMode = ref.watch(themeModeProvider);
    final user = authState.asData?.value;
    final name = user?.name.trim() ?? '';
    final username = user?.username.trim() ?? '';
    final displayName = name.isNotEmpty
        ? name
        : username.isNotEmpty
        ? username
        : 'BRIN';
    final isDarkMode = themeMode == ThemeMode.dark;
    final isCompactAppBar = MediaQuery.of(context).size.width < 760;
    final userInitial = displayName.isEmpty
        ? 'B'
        : displayName[0].toUpperCase();

    if (_rcSearchCtrl.text != brinState.query) {
      _rcSearchCtrl.value = TextEditingValue(
        text: brinState.query,
        selection: TextSelection.collapsed(offset: brinState.query.length),
      );
    }

    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: const Text('BRIN Dashboard'),
        actions: [
          if (!isCompactAppBar)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _refreshAll,
              tooltip: 'Refresh',
            ),
          PopupMenuButton<_BrinMenuAction>(
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
                value: _BrinMenuAction.refresh,
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.refresh),
                  title: Text('Refresh'),
                ),
              ),
              PopupMenuItem(
                value: _BrinMenuAction.toggleTheme,
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
                value: _BrinMenuAction.changePassword,
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.lock_reset_outlined),
                  title: Text('Change Password'),
                ),
              ),
              const PopupMenuItem(
                value: _BrinMenuAction.logout,
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
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  gradient: VistarPalette.heroGradient,
                  boxShadow: [
                    BoxShadow(
                      color: VistarPalette.purple.withValues(alpha: 0.22),
                      blurRadius: 18,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Welcome, $displayName',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Use BRIN tools to search RC numbers, assign locations, and correct quantities with comments.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.92),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              _buildRcSummarySection(brinState),
              const SizedBox(height: 20),
              _buildRcManagementSection(brinState),
            ],
          ),
        ),
      ),
      bottomNavigationBar: brinState.isSubmitting
          ? const ShimmerLinearBar(height: 2)
          : null,
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: VistarPalette.surface2,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: VistarPalette.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: VistarPalette.txt2),
          const SizedBox(width: 6),
          Text(
            '$label: $value',
            style: TextStyle(
              color: VistarPalette.txt2,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryMetricCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _SummaryMetricCard({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: VistarPalette.surface2,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: VistarPalette.line),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: VistarPalette.infoBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: VistarPalette.info),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: VistarPalette.txt2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: VistarPalette.txt,
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

class _BrinRcSummaryCard extends StatelessWidget {
  final BrinRcSummaryItem item;
  final String Function(String?) safeValue;
  final String Function(int) formatNumber;

  const _BrinRcSummaryCard({
    required this.item,
    required this.safeValue,
    required this.formatNumber,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VistarPalette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: VistarPalette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  safeValue(item.rcNumber),
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _InfoChip(
                icon: Icons.pin_outlined,
                label: 'Item',
                value: safeValue(item.itemCode),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Location: ${safeValue(item.location)}',
            style: TextStyle(color: VistarPalette.txt2),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _InfoChip(
                icon: Icons.scale_outlined,
                label: 'Actual',
                value: formatNumber(item.totalActualQuantity),
              ),
              _InfoChip(
                icon: Icons.rule_folder_outlined,
                label: 'Corrected',
                value: formatNumber(item.totalCorrectedQuantity),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BrinRcEntryCard extends StatelessWidget {
  final ProductionEntryModel entry;
  final VoidCallback? onEditQuantity;
  final String Function(String) formatDate;
  final String Function(String?) safeValue;

  const _BrinRcEntryCard({
    required this.entry,
    required this.onEditQuantity,
    required this.formatDate,
    required this.safeValue,
  });

  @override
  Widget build(BuildContext context) {
    final approval = safeValue(entry.approvalStatus ?? 'Pending');
    final date = formatDate(entry.entryDate);
    final machine = safeValue(entry.machineName ?? entry.machineId);
    final item = safeValue(entry.itemDescription ?? entry.itemId);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VistarPalette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: VistarPalette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$machine | $item',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Date: $date | Shift: ${safeValue(entry.shift)}',
                      style: TextStyle(color: VistarPalette.txt2),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _StatusPill(status: approval),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _InfoChip(
                icon: Icons.scale_outlined,
                label: 'Actual',
                value: entry.actualQuantity.toString(),
              ),
              _InfoChip(
                icon: Icons.report_gmailerrorred_outlined,
                label: 'Reject',
                value: entry.rejectionQuantity.toString(),
              ),
              _InfoChip(
                icon: Icons.location_on_outlined,
                label: 'Location',
                value: safeValue(entry.location),
              ),
              _InfoChip(
                icon: Icons.schedule_outlined,
                label: 'Parts/Hr',
                value: entry.partsPerHour.toStringAsFixed(1),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: onEditQuantity,
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Edit Qty'),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String status;

  const _StatusPill({required this.status});

  @override
  Widget build(BuildContext context) {
    final normalized = status.toUpperCase();
    final bgColor = normalized == 'APPROVED'
        ? VistarPalette.okBg
        : normalized == 'REJECTED'
        ? VistarPalette.badBg
        : VistarPalette.warnBg;
    final textColor = normalized == 'APPROVED'
        ? VistarPalette.ok
        : normalized == 'REJECTED'
        ? VistarPalette.bad
        : VistarPalette.warn;

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

class _LocationUpdateDialog extends StatefulWidget {
  final String rcNumber;
  final String initialLocation;

  const _LocationUpdateDialog({
    required this.rcNumber,
    required this.initialLocation,
  });

  @override
  State<_LocationUpdateDialog> createState() => _LocationUpdateDialogState();
}

class _LocationUpdateDialogState extends State<_LocationUpdateDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _locationCtrl;

  @override
  void initState() {
    super.initState();
    _locationCtrl = TextEditingController(
      text:
          widget.initialLocation == 'Not assigned' ||
              widget.initialLocation == 'Multiple locations'
          ? ''
          : widget.initialLocation,
    );
  }

  @override
  void dispose() {
    _locationCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(_locationCtrl.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Update RC Location'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This will update the location for all entries under RC ${widget.rcNumber}.',
              style: TextStyle(color: VistarPalette.txt2),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _locationCtrl,
              decoration: const InputDecoration(
                labelText: 'Location',
                hintText: 'Enter assigned place/RAC',
              ),
              validator: (value) {
                final text = (value ?? '').trim();
                if (text.isEmpty) return 'Location is required.';
                if (text.length < 2) return 'Enter a valid location.';
                return null;
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Apply')),
      ],
    );
  }
}

class _QuantityUpdateResult {
  final int quantity;
  final String comment;

  const _QuantityUpdateResult({required this.quantity, required this.comment});
}

class _QuantityUpdateDialog extends StatefulWidget {
  final ProductionEntryModel entry;

  const _QuantityUpdateDialog({required this.entry});

  @override
  State<_QuantityUpdateDialog> createState() => _QuantityUpdateDialogState();
}

class _QuantityUpdateDialogState extends State<_QuantityUpdateDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _quantityCtrl;
  late final TextEditingController _commentCtrl;

  @override
  void initState() {
    super.initState();
    _quantityCtrl = TextEditingController(
      text: widget.entry.actualQuantity.toString(),
    );
    _commentCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _quantityCtrl.dispose();
    _commentCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final quantity = int.parse(_quantityCtrl.text.trim());
    Navigator.of(context).pop(
      _QuantityUpdateResult(
        quantity: quantity,
        comment: _commentCtrl.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text('Edit Quantity'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'RC: ${(widget.entry.rcNumber ?? '').trim().isEmpty ? '-' : widget.entry.rcNumber!}',
                style: TextStyle(
                  color: VistarPalette.txt2,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Current Quantity: ${widget.entry.actualQuantity}',
                style: TextStyle(
                  color: VistarPalette.txt2,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _quantityCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'New Quantity'),
                validator: (value) {
                  final text = (value ?? '').trim();
                  if (text.isEmpty) return 'Quantity is required.';
                  final qty = int.tryParse(text);
                  if (qty == null) return 'Quantity must be a valid number.';
                  if (qty < 0) return 'Quantity cannot be negative.';
                  return null;
                },
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _commentCtrl,
                minLines: 3,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Comment',
                  hintText: 'Reason for this quantity correction',
                ),
                validator: (value) {
                  final text = (value ?? '').trim();
                  if (text.isEmpty) return 'Comment is required.';
                  if (text.length < 3) return 'Please add a short reason.';
                  return null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Update')),
      ],
    );
  }
}
