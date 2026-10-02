import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme_admin/services/admin_local_db_service.dart';
import 'package:matchme_admin/services/admin_offline_cache_manager.dart';

enum _PromoCodeListFilter { all, enabled, disabled, expired }

class AdminPromoCodeDashboard extends ConsumerStatefulWidget {
  const AdminPromoCodeDashboard({
    super.key,
    required this.t,
    required this.localeCode,
  });

  final String Function(String key, {Map<String, String>? params}) t;
  final String localeCode;

  @override
  ConsumerState<AdminPromoCodeDashboard> createState() =>
      _AdminPromoCodeDashboardState();
}

class _AdminPromoCodeDashboardState
    extends ConsumerState<AdminPromoCodeDashboard>
    with TickerProviderStateMixin {
  TabController? _tabController;
  final _codeController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _discountPercentController = TextEditingController();
  final _maxUsesController = TextEditingController();
  final _maxUsesPerUserController = TextEditingController(text: '1');
  final _listSearchController = TextEditingController();

  String _selectedCodeType = 'discount_percentage';
  final List<String> _selectedTiers = [];
  DateTime? _validUntil;

  bool _isEditing = false;
  String? _editingCodeId;
  _PromoCodeListFilter _listFilter = _PromoCodeListFilter.all;
  bool _promoCodesEnabled = true;
  static const _tabCount = 4;

  String _rangePreset = '30d';
  DateTime? _customStart;
  DateTime? _customEnd;

  // Cached data for instant display (populated synchronously after Hive init)
  List<Map<String, dynamic>>? _cachedCodes;
  Map<String, dynamic>? _cachedAnalytics;
  Future<List<Map<String, dynamic>>>? _codesFuture;
  Future<Map<String, dynamic>>? _analyticsFuture;

  String t(String key, {Map<String, String>? params}) =>
      widget.t(key, params: params);

  String get _localeCode {
    final trimmed = widget.localeCode.trim().toLowerCase();
    return trimmed.isEmpty ? 'en' : trimmed;
  }

  @override
  void initState() {
    super.initState();
    _ensureTabController();
    _initializeAndLoadFromLocalStorage().then((_) {
      _primeFutures();
    });
    _loadPromoCodesConfig();
  }

  Future<void> _initializeAndLoadFromLocalStorage() async {
    try {
      final localDb = await AdminLocalDbService.instance;
      final cachedCodes = localDb.loadPromoCodesSync();
      if (cachedCodes.isNotEmpty && mounted) {
        setState(() => _cachedCodes = cachedCodes);
      }
      final cachedAnalytics = localDb.loadPromoAnalyticsSync();
      if (cachedAnalytics != null && mounted) {
        setState(() => _cachedAnalytics = cachedAnalytics);
      }
    } catch (_) {}
  }

  void _primeFutures() {
    _codesFuture ??= _fetchActiveCodes().then((data) {
      if (mounted) setState(() => _cachedCodes = data);
      return data;
    });
    _analyticsFuture ??= _fetchAnalytics().then((data) {
      if (mounted) setState(() => _cachedAnalytics = data);
      return data;
    });
  }

  void _ensureTabController({int? preferredIndex}) {
    final current = _tabController;
    if (current != null && current.length == _tabCount) {
      return;
    }

    final previousIndex = preferredIndex ?? current?.index ?? 0;
    current?.dispose();
    _tabController = TabController(
      length: _tabCount,
      vsync: this,
      initialIndex: previousIndex.clamp(0, _tabCount - 1),
    );
  }

  TabController get _safeTabController {
    _ensureTabController();
    return _tabController!;
  }

  @override
  void dispose() {
    _tabController?.dispose();
    _codeController.dispose();
    _descriptionController.dispose();
    _discountPercentController.dispose();
    _maxUsesController.dispose();
    _maxUsesPerUserController.dispose();
    _listSearchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tabController = _safeTabController;
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: TabBar(
            controller: tabController,
            isScrollable: true,
            dividerColor: Colors.transparent,
            padding: EdgeInsets.zero,
            labelPadding: const EdgeInsets.symmetric(horizontal: 8),
            indicatorSize: TabBarIndicatorSize.tab,
            indicator: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            tabs: [
              Tab(
                icon: const Icon(Icons.insights_outlined),
                text: t('adminPromoCodesTabAnalytics'),
              ),
              Tab(
                icon: const Icon(Icons.tune_outlined),
                text: t('adminPromoCodesTabControls'),
              ),
              Tab(
                icon: const Icon(Icons.view_list_outlined),
                text: t('adminPromoCodesTabAllCodes'),
              ),
              Tab(
                icon: Icon(
                  _isEditing ? Icons.edit_outlined : Icons.add_circle_outline,
                ),
                text: _isEditing
                    ? t('generalEdit')
                    : t('adminPromoCodesTabCreate'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: TabBarView(
            controller: tabController,
            children: [
              _buildAnalyticsTab(),
              _buildControlsTab(),
              _buildActiveCodesTab(),
              _buildCreateCodeTab(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCreateCodeTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!_promoCodesEnabled) _buildPromoCodesDisabledBanner(),
          _buildSection(t('adminPromoCodesSectionCodeInfo'), [
            _buildTextField(
              label: t('adminPromoCodesFieldCode'),
              controller: _codeController,
              hint: t('adminPromoCodesFieldCodeHint'),
              onChanged: (value) {
                _codeController.text = value.toUpperCase();
                _codeController.selection = TextSelection.fromPosition(
                  TextPosition(offset: _codeController.text.length),
                );
              },
            ),
            _buildTextField(
              label: t('adminPromoCodesFieldDescription'),
              controller: _descriptionController,
              hint: t('adminPromoCodesFieldDescriptionHint'),
              lines: 3,
            ),
          ]),
          const SizedBox(height: 24),
          _buildSection(t('adminPromoCodesSectionDiscountType'), [
            _buildCodeTypeDropdown(),
          ]),
          const SizedBox(height: 16),
          _buildDiscountValueField(),
          const SizedBox(height: 24),
          _buildSection(t('adminPromoCodesSectionApplicableTiers'), [
            _buildTierCheckboxes(),
          ]),
          const SizedBox(height: 24),
          _buildSection(t('adminPromoCodesSectionUsageLimits'), [
            _buildTextField(
              label: t('adminPromoCodesFieldMaxUses'),
              controller: _maxUsesController,
              keyboardType: TextInputType.number,
            ),
            _buildTextField(
              label: t('adminPromoCodesFieldMaxUsesPerUser'),
              controller: _maxUsesPerUserController,
              keyboardType: TextInputType.number,
            ),
          ]),
          const SizedBox(height: 24),
          _buildSection(t('adminPromoCodesSectionValidity'), [
            _buildDatePicker(),
          ]),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isEditing ? _savePromoCode : _createPromoCode,
              icon: Icon(_isEditing ? Icons.save : Icons.add),
              label: Text(
                _isEditing
                    ? t('adminPromoCodesActionSaveChanges')
                    : t('adminPromoCodesActionCreate'),
              ),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),
          if (_isEditing) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _cancelEdit,
                child: Text(t('generalCancel')),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _cancelEdit() {
    setState(() {
      _isEditing = false;
      _editingCodeId = null;
      _resetForm();
    });
  }

  Future<void> _savePromoCode() async {
    if (_editingCodeId == null) return;

    // Check if offline
    if (adminOfflineCacheManager.shouldUseCachedData()) {
      _showError(t('adminPromoCodesOfflineUpdateError'));
      return;
    }

    int? amount;
    switch (_selectedCodeType) {
      case 'discount_percentage':
      case 'free_days':
        amount = int.tryParse(_discountPercentController.text);
        break;
      case 'discount_fixed':
        amount = (int.tryParse(_discountPercentController.text) ?? 0) * 100;
        break;
      default:
        break;
    }

    try {
      await Supabase.instance.client
          .rpc(
            'admin_update_promo_code',
            params: {
              'p_id': _editingCodeId,
              'p_code': _codeController.text.trim().toUpperCase(),
              'p_description': _descriptionController.text.isEmpty
                  ? null
                  : _descriptionController.text,
              'p_code_type': _selectedCodeType,
              'p_amount': amount,
              'p_max_uses': int.tryParse(_maxUsesController.text),
              'p_max_uses_per_user':
                  int.tryParse(_maxUsesPerUserController.text) ?? 1,
              'p_applicable_tiers': _selectedTiers.isEmpty
                  ? null
                  : _selectedTiers,
              'p_valid_until': _validUntil?.toIso8601String(),
            },
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;

      _showSuccess(t('adminPromoCodesUpdateSuccess'));
      setState(() {
        _isEditing = false;
        _editingCodeId = null;
        _resetForm();
      });
      _safeTabController.animateTo(2);

      // Trigger a sync to update local cache
      unawaited(_refreshLocalCache());
    } catch (error) {
      _showError(
        t('adminPromoCodesUpdateError', params: {'error': error.toString()}),
      );
    }
  }

  Widget _buildCodeTypeDropdown() {
    const codeTypes = [
      'discount_percentage',
      'discount_fixed',
      'free_days',
      'tier_upgrade',
    ];

    return DropdownButton<String>(
      value: _selectedCodeType,
      isExpanded: true,
      items: codeTypes
          .map(
            (type) => DropdownMenuItem<String>(
              value: type,
              child: Text(_localizedCodeType(type)),
            ),
          )
          .toList(),
      onChanged: (value) {
        if (value == null) return;
        setState(() => _selectedCodeType = value);
      },
    );
  }

  Widget _buildDiscountValueField() {
    switch (_selectedCodeType) {
      case 'discount_percentage':
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: _discountPercentController,
            decoration: InputDecoration(
              labelText: t('adminPromoCodesFieldDiscountPercentage'),
              hintText: t('adminPromoCodesFieldDiscountPercentageHint'),
              suffixText: '%',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            keyboardType: TextInputType.number,
          ),
        );
      case 'discount_fixed':
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: _discountPercentController,
            decoration: InputDecoration(
              labelText: t('adminPromoCodesFieldDiscountAmount'),
              hintText: t('adminPromoCodesFieldDiscountAmountHint'),
              prefixText: '\$ ',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            keyboardType: TextInputType.number,
          ),
        );
      case 'free_days':
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: _discountPercentController,
            decoration: InputDecoration(
              labelText: t('adminPromoCodesFieldFreeDays'),
              hintText: t('adminPromoCodesFieldFreeDaysHint'),
              suffixText: t('adminPromoCodesFieldFreeDaysSuffix'),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            keyboardType: TextInputType.number,
          ),
        );
      case 'tier_upgrade':
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue.withValues(alpha: 0.1),
              border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              t('adminPromoCodesTierUpgradeHelp'),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.blue[700]),
            ),
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildTierCheckboxes() {
    return Column(
      children: const ['plus', 'gold', 'platinum']
          .map(
            (tier) => CheckboxListTile(
              title: Text(_localizedTierLabel(tier)),
              value: _selectedTiers.contains(tier),
              onChanged: (checked) {
                setState(() {
                  if (checked ?? false) {
                    _selectedTiers.add(tier);
                  } else {
                    _selectedTiers.remove(tier);
                  }
                });
              },
            ),
          )
          .toList(),
    );
  }

  Widget _buildDatePicker() {
    final label = _validUntil == null
        ? t('adminPromoCodesExpiresDefault')
        : t(
            'adminPromoCodesExpiresOn',
            params: {'date': _formatAbsoluteDate(_validUntil!)},
          );

    return ListTile(
      title: Text(label),
      trailing: IconButton(
        icon: const Icon(Icons.calendar_today),
        tooltip: t('adminPromoCodesSectionValidity'),
        onPressed: () async {
          final now = DateTime.now();
          final picked = await showDatePicker(
            context: context,
            initialDate: _validUntil ?? now.add(const Duration(days: 90)),
            firstDate: now,
            lastDate: now.add(const Duration(days: 365)),
          );
          if (picked != null) {
            setState(() => _validUntil = picked);
          }
        },
      ),
    );
  }

  Widget _buildActiveCodesTab() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _codesFuture ?? _fetchActiveCodes(),
      builder: (context, snapshot) {
        final codes =
            _cachedCodes ?? snapshot.data ?? const <Map<String, dynamic>>[];

        if (codes.isEmpty &&
            snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError && codes.isEmpty) {
          return Center(
            child: Text(
              t(
                'adminPromoCodesLoadFailed',
                params: {'error': snapshot.error.toString()},
              ),
            ),
          );
        }

        final filteredCodes = _filterCodes(codes);

        if (codes.isEmpty) {
          return Center(child: Text(t('adminPromoCodesEmpty')));
        }

        return Column(
          children: [
            if (!_promoCodesEnabled)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: _buildPromoCodesDisabledBanner(),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                children: [
                  TextField(
                    controller: _listSearchController,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: t('adminPromoCodesSearchLabel'),
                      hintText: t('adminPromoCodesSearchHint'),
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _listSearchController.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: t('adminPromoCodesClearSearch'),
                              onPressed: () {
                                _listSearchController.clear();
                                setState(() {});
                              },
                              icon: const Icon(Icons.clear),
                            ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _buildFilterChip(
                          label: t('adminPromoCodesFilterAll'),
                          filter: _PromoCodeListFilter.all,
                        ),
                        const SizedBox(width: 8),
                        _buildFilterChip(
                          label: t('adminPromoCodesFilterEnabled'),
                          filter: _PromoCodeListFilter.enabled,
                        ),
                        const SizedBox(width: 8),
                        _buildFilterChip(
                          label: t('adminPromoCodesFilterDisabled'),
                          filter: _PromoCodeListFilter.disabled,
                        ),
                        const SizedBox(width: 8),
                        _buildFilterChip(
                          label: t('adminPromoCodesFilterExpired'),
                          filter: _PromoCodeListFilter.expired,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      t(
                        'adminPromoCodesShowingCount',
                        params: {
                          'shown': filteredCodes.length.toString(),
                          'total': codes.length.toString(),
                        },
                      ),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: filteredCodes.isEmpty
                  ? Center(child: Text(t('adminPromoCodesEmptyFiltered')))
                  : ListView.builder(
                      itemCount: filteredCodes.length,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      itemBuilder: (context, index) {
                        final code = filteredCodes[index];
                        return _buildCodeCard(code);
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCodeCard(Map<String, dynamic> code) {
    final isActive = code['is_active'] == true;
    final isExpired = _isCodeExpired(code);
    final codeType = (code['code_type'] ?? '').toString();
    final amount = code['amount'] as int? ?? 0;
    final maxUses = code['max_uses'] as int?;
    final validUntil = code['valid_until'] as String?;
    final maxUsesPerUser = code['max_uses_per_user'] as int? ?? 1;
    final description = (code['description'] ?? '').toString().trim();

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        (code['code'] ?? '').toString(),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2,
                        ),
                      ),
                      _buildStatusBadge(
                        label: isActive
                            ? t('adminPromoCodesStatusEnabled')
                            : t('adminPromoCodesStatusDisabled'),
                        icon: isActive
                            ? Icons.check_circle
                            : Icons.pause_circle,
                        backgroundColor: isActive
                            ? Colors.green.shade50
                            : Colors.red.shade50,
                        foregroundColor: isActive
                            ? Colors.green.shade700
                            : Colors.red.shade700,
                      ),
                      if (isExpired)
                        _buildStatusBadge(
                          label: t('adminPromoCodesStatusExpired'),
                          icon: Icons.schedule,
                          backgroundColor: Colors.orange.shade50,
                          foregroundColor: Colors.orange.shade800,
                        ),
                    ],
                  ),
                ),
                PopupMenuButton(
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      onTap: () => _loadCodeForEditing(code),
                      child: Text(t('generalEdit')),
                    ),
                    PopupMenuItem(
                      onTap: () => _toggleCodeStatus(
                        (code['id'] ?? '').toString(),
                        !isActive,
                      ),
                      child: Text(
                        isActive
                            ? t('adminPromoCodesActionDisable')
                            : t('adminPromoCodesActionEnable'),
                      ),
                    ),
                    PopupMenuItem(
                      onTap: () =>
                          _showCodeStats((code['id'] ?? '').toString()),
                      child: Text(t('adminPromoCodesMenuViewStats')),
                    ),
                    PopupMenuItem(
                      onTap: () => _deletePromoCode(
                        (code['id'] ?? '').toString(),
                        (code['code'] ?? '').toString(),
                      ),
                      child: Text(
                        t('generalDelete'),
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                border: Border.all(color: Colors.green.shade300),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _localizedDiscountDisplay(codeType, amount),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.green.shade700,
                ),
              ),
            ),
            if (description.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(description, style: const TextStyle(color: Colors.grey)),
            ],
            const Divider(height: 24),
            Row(
              children: [
                Expanded(
                  child: _buildInfoChip(
                    icon: Icons.people_outline,
                    label: _localizedTiersLabel(code['applicable_tiers']),
                    tooltip: t('adminPromoCodesInfoApplicableTiers'),
                  ),
                ),
                if (validUntil != null)
                  Expanded(
                    child: _buildInfoChip(
                      icon: Icons.schedule,
                      label: _formatDate(validUntil),
                      tooltip: t('adminPromoCodesInfoExpires'),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _buildInfoChip(
                    icon: Icons.check_circle_outline,
                    label: maxUses == null
                        ? t('adminPromoCodesUsesUnlimited')
                        : t(
                            'adminPromoCodesUsesCount',
                            params: {'count': maxUses.toString()},
                          ),
                    tooltip: t('adminPromoCodesInfoMaxUses'),
                  ),
                ),
                Expanded(
                  child: _buildInfoChip(
                    icon: Icons.repeat,
                    label: maxUsesPerUser.toString(),
                    tooltip: t('adminPromoCodesInfoUsesPerUser'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoChip({
    required IconData icon,
    required String label,
    required String tooltip,
  }) {
    return Tooltip(
      message: tooltip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.grey.shade600),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge({
    required String label,
    required IconData icon,
    required Color backgroundColor,
    required Color foregroundColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: foregroundColor.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: foregroundColor),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: foregroundColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip({
    required String label,
    required _PromoCodeListFilter filter,
  }) {
    return FilterChip(
      label: Text(label),
      selected: _listFilter == filter,
      onSelected: (_) {
        setState(() {
          _listFilter = filter;
        });
      },
    );
  }

  List<Map<String, dynamic>> _filterCodes(List<Map<String, dynamic>> codes) {
    final query = _listSearchController.text.trim().toLowerCase();

    return codes
        .where((code) {
          final isActive = code['is_active'] == true;
          final isExpired = _isCodeExpired(code);

          final matchesFilter = switch (_listFilter) {
            _PromoCodeListFilter.all => true,
            _PromoCodeListFilter.enabled => isActive,
            _PromoCodeListFilter.disabled => !isActive,
            _PromoCodeListFilter.expired => isExpired,
          };

          if (!matchesFilter) {
            return false;
          }

          if (query.isEmpty) {
            return true;
          }

          final fields = [
            code['code'],
            code['description'],
            code['campaign_name'],
            code['code_type'],
            code['upgrade_tier'],
            if (code['applicable_tiers'] is List)
              (code['applicable_tiers'] as List).join(' '),
            if (code['applicable_tiers'] is String) code['applicable_tiers'],
          ];

          return fields.any(
            (field) => (field ?? '').toString().toLowerCase().contains(query),
          );
        })
        .toList(growable: false);
  }

  bool _isCodeExpired(Map<String, dynamic> code) {
    final validUntilRaw = code['valid_until'];
    if (validUntilRaw == null) return false;

    final validUntil = DateTime.tryParse(validUntilRaw.toString());
    if (validUntil == null) return false;

    return validUntil.isBefore(DateTime.now());
  }

  String _formatDate(String isoDate) {
    try {
      final parsed = DateTime.parse(isoDate).toLocal();
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final target = DateTime(parsed.year, parsed.month, parsed.day);
      final diff = target.difference(today).inDays;

      if (diff < 0) return t('adminPromoCodesDateExpired');
      if (diff == 0) return t('adminPromoCodesDateToday');
      if (diff == 1) return t('adminPromoCodesDateTomorrow');
      if (diff < 7) {
        return t('adminPromoCodesDateDays', params: {'count': diff.toString()});
      }
      if (diff < 30) {
        return t(
          'adminPromoCodesDateWeeks',
          params: {'count': (diff / 7).floor().toString()},
        );
      }
      return _formatAbsoluteDate(parsed);
    } catch (_) {
      return isoDate;
    }
  }

  Widget _buildControlsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!_promoCodesEnabled) _buildPromoCodesDisabledBanner(),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t('adminPromoCodesControlsTitle'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    t('adminPromoCodesControlsSubtitle'),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    title: Text(t('adminPromoCodesControlsEnabled')),
                    subtitle: Text(t('adminPromoCodesControlsEnabledSubtitle')),
                    value: _promoCodesEnabled,
                    onChanged: (value) {
                      setState(() => _promoCodesEnabled = value);
                      _savePromoCodesConfig();
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnalyticsTab() {
    return FutureBuilder<Map<String, dynamic>>(
      future: _analyticsFuture ?? _fetchAnalytics(),
      builder: (context, snapshot) {
        final stats =
            _cachedAnalytics ?? snapshot.data ?? const <String, dynamic>{};

        if (stats.isEmpty &&
            snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError && stats.isEmpty) {
          return Center(
            child: Text(
              t(
                'adminPromoCodesAnalyticsLoadFailed',
                params: {'error': snapshot.error.toString()},
              ),
            ),
          );
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (!_promoCodesEnabled) _buildPromoCodesDisabledBanner(),
            _buildDateRangeSelector(),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t('adminPromoCodesAnalyticsTitle'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      t('adminPromoCodesAnalyticsSubtitle'),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            _buildDrillableStatsCard(
              t('adminPromoCodesStatsTotalUses'),
              '${stats['total_uses'] ?? 0}',
              Icons.card_giftcard,
              onTap: () => _showDrillDownDialog('total_uses', stats),
            ),
            const SizedBox(height: 12),
            _buildDrillableStatsCard(
              t('adminPromoCodesStatsUniqueUsers'),
              '${stats['unique_users'] ?? 0}',
              Icons.people,
              onTap: () => _showDrillDownDialog('unique_users', stats),
            ),
            const SizedBox(height: 12),
            _buildDrillableStatsCard(
              t('adminPromoCodesStatsTotalDiscount'),
              _formatCurrency(
                ((stats['total_discount_cents'] ?? 0) as int) / 100,
              ),
              Icons.trending_down,
              onTap: () => _showDrillDownDialog('total_discount', stats),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDrillableStatsCard(
    String title,
    String value,
    IconData icon, {
    VoidCallback? onTap,
  }) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: ListTile(
          leading: Icon(icon, size: 32),
          title: Text(title),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 8),
                Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        ...children,
      ],
    );
  }

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    String? hint,
    int lines = 1,
    TextInputType keyboardType = TextInputType.text,
    ValueChanged<String>? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
        keyboardType: keyboardType,
        minLines: lines,
        maxLines: lines,
        onChanged: onChanged,
      ),
    );
  }

  Future<void> _createPromoCode() async {
    final code = _codeController.text.trim().toUpperCase();
    if (code.isEmpty) {
      _showError(t('adminPromoCodesValidationCodeRequired'));
      return;
    }

    // Check if offline
    if (adminOfflineCacheManager.shouldUseCachedData()) {
      _showError(t('adminPromoCodesOfflineCreateError'));
      return;
    }

    try {
      final supabase = Supabase.instance.client;
      int? amount;
      if (_selectedCodeType == 'discount_fixed') {
        amount = (int.tryParse(_discountPercentController.text) ?? 0) * 100;
      } else {
        amount = int.tryParse(_discountPercentController.text);
      }

      final params = <String, dynamic>{
        'p_code': code,
        'p_description': _descriptionController.text,
        'p_code_type': _selectedCodeType,
        'p_amount': amount,
        'p_applicable_tiers': _selectedTiers.isEmpty ? null : _selectedTiers,
        'p_max_uses': int.tryParse(_maxUsesController.text),
        'p_max_uses_per_user':
            int.tryParse(_maxUsesPerUserController.text) ?? 1,
      };

      if (_validUntil != null) {
        params['p_valid_until'] = _validUntil!.toIso8601String();
      }

      await supabase
          .rpc('admin_create_promo_code', params: params)
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;

      _showSuccess(t('adminPromoCodesCreateSuccess'));
      _resetForm();
      setState(() {});

      // Trigger a sync to update local cache
      unawaited(_refreshLocalCache());
    } catch (error) {
      _showError(
        t('adminPromoCodesCreateError', params: {'error': error.toString()}),
      );
    }
  }

  Future<void> _refreshLocalCache() async {
    try {
      final response = await Supabase.instance.client
          .from('promo_codes')
          .select()
          .order('is_active', ascending: false)
          .order('created_at', ascending: false)
          .timeout(const Duration(seconds: 10));

      final codes = List<Map<String, dynamic>>.from(response);
      final localDb = await AdminLocalDbService.instance;
      await localDb.savePromoCodes(codes);
      if (mounted) {
        setState(() => _cachedCodes = codes);
        // Reset future so next load uses fresh data
        _codesFuture = null;
      }
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> _fetchActiveCodes() async {
    // First, try to load from local storage for immediate display
    List<Map<String, dynamic>> cachedCodes = [];
    try {
      final localDb = await AdminLocalDbService.instance;
      cachedCodes = await localDb.loadPromoCodes();
    } catch (_) {}

    // If offline, return cached data immediately
    if (adminOfflineCacheManager.shouldUseCachedData()) {
      return cachedCodes;
    }

    // If online, try to fetch from server
    try {
      final response = await Supabase.instance.client
          .from('promo_codes')
          .select()
          .order('is_active', ascending: false)
          .order('created_at', ascending: false)
          .timeout(const Duration(seconds: 10));

      final codes = List<Map<String, dynamic>>.from(response);

      // Save to local storage for offline use
      try {
        final localDb = await AdminLocalDbService.instance;
        await localDb.savePromoCodes(codes);
      } catch (_) {}

      return codes;
    } catch (error) {
      // If server request fails, return cached data
      if (cachedCodes.isNotEmpty) {
        return cachedCodes;
      }
      throw error.toString();
    }
  }

  Future<Map<String, dynamic>> _fetchAnalytics() async {
    // First, try to load from local storage for immediate display
    Map<String, dynamic>? cachedAnalytics;
    try {
      final localDb = await AdminLocalDbService.instance;
      cachedAnalytics = await localDb.loadPromoAnalytics();
    } catch (_) {}

    // If offline, return cached data immediately
    if (adminOfflineCacheManager.shouldUseCachedData()) {
      return cachedAnalytics ??
          {'total_uses': 0, 'unique_users': 0, 'total_discount_cents': 0};
    }

    // If online, try to fetch from server
    try {
      final window = _analyticsWindowUtc();

      final baseQuery = Supabase.instance.client
          .from('promo_code_usages')
          .select('id, discount_value_cents, user_id');

      final filteredQuery = _rangePreset != 'all'
          ? baseQuery
                .gte('redeemed_at', window.startUtc.toIso8601String())
                .lte('redeemed_at', window.endUtc.toIso8601String())
          : baseQuery;

      final response = await filteredQuery
          .order('redeemed_at', ascending: false)
          .limit(10000)
          .timeout(const Duration(seconds: 10));

      final list = List<Map<String, dynamic>>.from(response);
      final uniqueUsers = <String>{};
      var totalDiscount = 0;

      for (final item in list) {
        final userId = (item['user_id'] ?? '').toString();
        if (userId.isNotEmpty) {
          uniqueUsers.add(userId);
        }
        totalDiscount += (item['discount_value_cents'] ?? 0) as int;
      }

      final analytics = {
        'total_uses': list.length,
        'unique_users': uniqueUsers.length,
        'total_discount_cents': totalDiscount,
        'last_updated': DateTime.now().toIso8601String(),
      };

      // Save to local storage for offline use
      try {
        final localDb = await AdminLocalDbService.instance;
        await localDb.savePromoAnalytics(analytics);
      } catch (_) {}

      return analytics;
    } catch (error) {
      // If server request fails, return cached data
      if (cachedAnalytics != null) {
        return cachedAnalytics;
      }
      throw error.toString();
    }
  }

  Map<String, dynamic> _drillDownDateParams() {
    final window = _analyticsWindowUtc();
    if (_rangePreset == 'all') return {};
    return {
      'p_start_date': window.startUtc.toIso8601String(),
      'p_end_date': window.endUtc.toIso8601String(),
    };
  }

  Future<List<Map<String, dynamic>>> _loadAndCachePromoUsageByUser() async {
    try {
      final result = await Supabase.instance.client
          .rpc('admin_get_promo_usage_by_user', params: _drillDownDateParams())
          .timeout(const Duration(seconds: 15));
      final rows = List<Map<String, dynamic>>.from(result as List);
      try {
        final localDb = await AdminLocalDbService.instance;
        await localDb.saveSectionData('promo_usage_by_user', rows);
      } catch (_) {}
      return rows;
    } catch (_) {
      // Return cached data on error
      try {
        final localDb = await AdminLocalDbService.instance;
        return await localDb.loadSectionData('promo_usage_by_user');
      } catch (_) {
        return const [];
      }
    }
  }

  Future<List<Map<String, dynamic>>> _loadAndCachePromoUsageByCode() async {
    try {
      final result = await Supabase.instance.client
          .rpc('admin_get_promo_usage_by_code', params: _drillDownDateParams())
          .timeout(const Duration(seconds: 15));
      final rows = List<Map<String, dynamic>>.from(result as List);
      try {
        final localDb = await AdminLocalDbService.instance;
        await localDb.saveSectionData('promo_usage_by_code', rows);
      } catch (_) {}
      return rows;
    } catch (_) {
      try {
        final localDb = await AdminLocalDbService.instance;
        return await localDb.loadSectionData('promo_usage_by_code');
      } catch (_) {
        return const [];
      }
    }
  }

  Future<List<Map<String, dynamic>>> _loadAndCachePromoDiscountByDate() async {
    try {
      final result = await Supabase.instance.client
          .rpc(
            'admin_get_promo_discount_by_date',
            params: _drillDownDateParams(),
          )
          .timeout(const Duration(seconds: 15));
      final rows = List<Map<String, dynamic>>.from(result as List);
      try {
        final localDb = await AdminLocalDbService.instance;
        await localDb.saveSectionData('promo_discount_by_date', rows);
      } catch (_) {}
      return rows;
    } catch (_) {
      try {
        final localDb = await AdminLocalDbService.instance;
        return await localDb.loadSectionData('promo_discount_by_date');
      } catch (_) {
        return const [];
      }
    }
  }

  Future<List<Map<String, dynamic>>> _loadAndCachePromoUsageUserDetails(
    dynamic userId,
  ) async {
    try {
      final result = await Supabase.instance.client
          .rpc(
            'admin_get_promo_usage_user_details',
            params: {'p_user_id': userId},
          )
          .timeout(const Duration(seconds: 15));
      final rows = List<Map<String, dynamic>>.from(result as List);
      try {
        final localDb = await AdminLocalDbService.instance;
        await localDb.saveSectionData('promo_usage_user_details:$userId', rows);
      } catch (_) {}
      return rows;
    } catch (_) {
      try {
        final localDb = await AdminLocalDbService.instance;
        return await localDb.loadSectionData(
          'promo_usage_user_details:$userId',
        );
      } catch (_) {
        return const [];
      }
    }
  }

  Future<void> _toggleCodeStatus(String codeId, bool isActive) async {
    // Check if offline
    if (adminOfflineCacheManager.shouldUseCachedData()) {
      _showError(t('adminPromoCodesOfflineToggleError'));
      return;
    }

    try {
      await Supabase.instance.client
          .rpc(
            'admin_update_promo_code',
            params: {'p_id': codeId, 'p_is_active': isActive},
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;

      _showSuccess(
        isActive
            ? t('adminPromoCodesToggleEnabledSuccess')
            : t('adminPromoCodesToggleDisabledSuccess'),
      );
      setState(() {});

      // Trigger a sync to update local cache
      unawaited(_refreshLocalCache());
    } catch (error) {
      _showError(
        t('adminPromoCodesToggleError', params: {'error': error.toString()}),
      );
    }
  }

  Future<void> _deletePromoCode(String codeId, String code) async {
    // Check if offline
    if (adminOfflineCacheManager.shouldUseCachedData()) {
      _showError(t('adminPromoCodesOfflineDeleteError'));
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('adminPromoCodesDeleteTitle')),
        content: Text(t('adminPromoCodesDeleteBody', params: {'code': code})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('generalCancel')),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('generalDelete')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await Supabase.instance.client
          .from('promo_codes')
          .delete()
          .eq('id', codeId)
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;

      _showSuccess(t('adminPromoCodesDeleteSuccess'));
      setState(() {});

      // Trigger a sync to update local cache
      unawaited(_refreshLocalCache());
    } catch (error) {
      _showError(
        t('adminPromoCodesDeleteError', params: {'error': error.toString()}),
      );
    }
  }

  Future<void> _showDrillDownDialog(
    String metric,
    Map<String, dynamic> stats,
  ) async {
    final title = switch (metric) {
      'total_uses' => t('adminPromoCodesDrillDownTotalUses'),
      'unique_users' => t('adminPromoCodesDrillDownUniqueUsers'),
      'total_discount' => t('adminPromoCodesDrillDownTotalDiscount'),
      _ => metric,
    };

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 800,
          height: 600,
          child: _buildDrillDownContent(metric),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('generalClose')),
          ),
        ],
      ),
    );
  }

  Widget _buildDrillDownContent(String metric) {
    switch (metric) {
      case 'unique_users':
        return _buildUserStatsDrillDown();
      case 'total_uses':
        return _buildCodeStatsDrillDown();
      case 'total_discount':
        return _buildDiscountByDateDrillDown();
      default:
        return Center(child: Text(t('adminUnknown')));
    }
  }

  Widget _buildUserStatsDrillDown() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _loadAndCachePromoUsageByUser(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(
            child: Text(
              t(
                'adminPromoCodesDrillDownError',
                params: {'error': '${snapshot.error}'},
              ),
            ),
          );
        }

        final users = snapshot.data ?? const [];

        if (users.isEmpty) {
          return Center(child: Text(t('adminPromoCodesEmpty')));
        }

        return ListView.builder(
          itemCount: users.length,
          itemBuilder: (context, index) {
            final user = users[index];
            return Card(
              child: ListTile(
                title: Text(user['user_name'] ?? t('adminUnknown')),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t(
                        'adminPromoCodesDrillDownLabelUses',
                        params: {'count': '${user['total_uses']}'},
                      ),
                    ),
                    Text(
                      t(
                        'adminPromoCodesDrillDownLabelSaved',
                        params: {
                          'amount': _formatCurrency(
                            (user['total_discount_cents'] ?? 0) / 100,
                          ),
                        },
                      ),
                    ),
                    Text(
                      t(
                        'adminPromoCodesDrillDownLabelUniquePromos',
                        params: {'count': '${user['unique_promos']}'},
                      ),
                    ),
                  ],
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showUserDetailsDialog(user['user_id']),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildCodeStatsDrillDown() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _loadAndCachePromoUsageByCode(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(
            child: Text(
              t(
                'adminPromoCodesDrillDownError',
                params: {'error': '${snapshot.error}'},
              ),
            ),
          );
        }

        final codes = snapshot.data ?? const [];

        if (codes.isEmpty) {
          return Center(child: Text(t('adminPromoCodesEmpty')));
        }

        return ListView.builder(
          itemCount: codes.length,
          itemBuilder: (context, index) {
            final code = codes[index];
            return Card(
              child: ListTile(
                title: Text(code['promo_code'] ?? t('adminUnknown')),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t(
                        'adminPromoCodesDrillDownLabelUses',
                        params: {'count': '${code['total_uses']}'},
                      ),
                    ),
                    Text(
                      t(
                        'adminPromoCodesDrillDownLabelUsers',
                        params: {'count': '${code['unique_users']}'},
                      ),
                    ),
                    Text(
                      t(
                        'adminPromoCodesDrillDownLabelDiscount',
                        params: {
                          'amount': _formatCurrency(
                            (code['total_discount_cents'] ?? 0) / 100,
                          ),
                        },
                      ),
                    ),
                    Text(
                      t(
                        'adminPromoCodesDrillDownLabelType',
                        params: {'type': '${code['code_type']}'},
                      ),
                    ),
                  ],
                ),
                trailing: Icon(
                  code['is_active'] == true ? Icons.check_circle : Icons.cancel,
                  color: code['is_active'] == true ? Colors.green : Colors.red,
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildDiscountByDateDrillDown() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _loadAndCachePromoDiscountByDate(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(
            child: Text(
              t(
                'adminPromoCodesDrillDownError',
                params: {'error': '${snapshot.error}'},
              ),
            ),
          );
        }

        final dates = snapshot.data ?? const [];

        if (dates.isEmpty) {
          return Center(child: Text(t('adminPromoCodesEmpty')));
        }

        return ListView.builder(
          itemCount: dates.length,
          itemBuilder: (context, index) {
            final date = dates[index];
            final dateStr = date['date'] ?? t('adminUnknown');
            return Card(
              child: ListTile(
                title: Text(dateStr),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t(
                        'adminPromoCodesDrillDownLabelDiscount',
                        params: {
                          'amount': _formatCurrency(
                            (date['total_discount_cents'] ?? 0) / 100,
                          ),
                        },
                      ),
                    ),
                    Text(
                      t(
                        'adminPromoCodesDrillDownLabelUses',
                        params: {'count': '${date['total_uses']}'},
                      ),
                    ),
                    Text(
                      t(
                        'adminPromoCodesDrillDownLabelUsers',
                        params: {'count': '${date['unique_users']}'},
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showUserDetailsDialog(dynamic userId) async {
    if (userId == null) return;

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('adminPromoCodesUserHistory')),
        content: SizedBox(
          width: 800,
          height: 600,
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _loadAndCachePromoUsageUserDetails(userId),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              if (snapshot.hasError) {
                return Center(
                  child: Text(
                    t(
                      'adminPromoCodesDrillDownError',
                      params: {'error': '${snapshot.error}'},
                    ),
                  ),
                );
              }

              final usages = snapshot.data ?? const [];

              if (usages.isEmpty) {
                return Center(child: Text(t('adminPromoCodesNoUsageFound')));
              }

              return ListView.builder(
                itemCount: usages.length,
                itemBuilder: (context, index) {
                  final usage = usages[index];
                  return Card(
                    child: ListTile(
                      title: Text(usage['promo_code'] ?? t('adminUnknown')),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t(
                              'adminPromoCodesDrillDownLabelType',
                              params: {'type': '${usage['code_type']}'},
                            ),
                          ),
                          Text(
                            t(
                              'adminPromoCodesDrillDownLabelAmount',
                              params: {'amount': '${usage['amount']}'},
                            ),
                          ),
                          Text(
                            t(
                              'adminPromoCodesDrillDownLabelRedeemed',
                              params: {
                                'date': _formatDateTime(usage['redeemed_at']),
                              },
                            ),
                          ),
                          Text(
                            t(
                              'adminPromoCodesDrillDownLabelDiscount',
                              params: {
                                'amount': _formatCurrency(
                                  (usage['discount_value_cents'] ?? 0) / 100,
                                ),
                              },
                            ),
                          ),
                          Text(
                            t(
                              'adminPromoCodesDrillDownLabelAppliedTier',
                              params: {
                                'tier':
                                    '${usage['applied_tier'] ?? t('adminUnknown')}',
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('generalClose')),
          ),
        ],
      ),
    );
  }

  Future<void> _loadPromoCodesConfig() async {
    // First, load from local storage for immediate display
    try {
      final localDb = await AdminLocalDbService.instance;
      final cachedEnabled = await localDb.loadPromoCodesConfig();
      if (mounted) {
        setState(() {
          _promoCodesEnabled = cachedEnabled;
        });
      }
    } catch (e) {
      // If local storage fails, default to true
      if (mounted) {
        setState(() {
          _promoCodesEnabled = true;
        });
      }
    }

    // Then, try to sync with server if online
    if (!adminOfflineCacheManager.shouldUseCachedData()) {
      try {
        final response = await Supabase.instance.client
            .from('app_config')
            .select('config_value')
            .eq('config_key', 'promo_codes_enabled')
            .maybeSingle()
            .timeout(const Duration(seconds: 5));

        if (response != null && mounted) {
          final enabled = response['config_value'] as bool? ?? true;
          setState(() {
            _promoCodesEnabled = enabled;
          });
          // Save to local storage
          final localDb = await AdminLocalDbService.instance;
          await localDb.savePromoCodesConfig(enabled);
        }
      } catch (_) {
        // If server request fails, we already have cached value
      }
    }
  }

  Future<void> _savePromoCodesConfig() async {
    // Save to local storage first (always succeeds)
    try {
      final localDb = await AdminLocalDbService.instance;
      await localDb.savePromoCodesConfig(_promoCodesEnabled);
    } catch (_) {}

    // If offline, show offline warning
    if (adminOfflineCacheManager.shouldUseCachedData()) {
      _showError(t('adminPromoCodesOfflineSyncWarning'));
      return;
    }

    // If online, sync with server
    try {
      await Supabase.instance.client
          .rpc(
            'admin_update_promo_codes_config',
            params: {'p_enabled': _promoCodesEnabled},
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;
      _showSuccess(t('adminPromoCodesConfigSaveSuccess'));
    } catch (error) {
      _showError(
        t(
          'adminPromoCodesConfigSaveError',
          params: {'error': error.toString()},
        ),
      );
    }
  }

  Future<void> _showCodeStats(String codeId) async {
    try {
      final response = await Supabase.instance.client.rpc(
        'admin_get_promo_usage_stats',
        params: {'p_promo_code_id': codeId},
      );

      if (!mounted || response == null) return;

      final statsList = List<Map<String, dynamic>>.from(response as List);
      if (statsList.isEmpty) return;
      final stats = statsList.first;

      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(t('adminPromoCodesStatsDialogTitle')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t(
                  'adminPromoCodesStatsDialogTotalUses',
                  params: {'count': '${stats['total_uses'] ?? 0}'},
                ),
              ),
              Text(
                t(
                  'adminPromoCodesStatsDialogUniqueUsers',
                  params: {'count': '${stats['unique_users'] ?? 0}'},
                ),
              ),
              Text(
                t(
                  'adminPromoCodesStatsDialogTotalDiscount',
                  params: {
                    'amount': _formatCurrency(
                      ((stats['total_discount_cents'] ?? 0) as int) / 100,
                    ),
                  },
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t('generalClose')),
            ),
          ],
        ),
      );
    } catch (error) {
      _showError(
        t(
          'adminPromoCodesStatsFetchError',
          params: {'error': error.toString()},
        ),
      );
    }
  }

  void _loadCodeForEditing(Map<String, dynamic> code) {
    _codeController.text = (code['code'] ?? '').toString();
    _descriptionController.text = (code['description'] ?? '').toString();
    _selectedCodeType = (code['code_type'] ?? 'discount_percentage').toString();

    final amount = code['amount'] as int? ?? 0;
    switch (_selectedCodeType) {
      case 'discount_percentage':
      case 'free_days':
        _discountPercentController.text = amount.toString();
        break;
      case 'discount_fixed':
        _discountPercentController.text = (amount / 100).toStringAsFixed(0);
        break;
      default:
        _discountPercentController.clear();
    }

    _maxUsesController.text = code['max_uses']?.toString() ?? '';
    _maxUsesPerUserController.text = (code['max_uses_per_user'] ?? 1)
        .toString();

    _selectedTiers.clear();
    final tiersRaw = code['applicable_tiers'];
    if (tiersRaw is List) {
      _selectedTiers.addAll(List<String>.from(tiersRaw));
    } else if (tiersRaw is String && tiersRaw.isNotEmpty) {
      _selectedTiers.add(tiersRaw);
    }

    _validUntil = code['valid_until'] != null
        ? DateTime.tryParse(code['valid_until'].toString())
        : null;

    setState(() {
      _isEditing = true;
      _editingCodeId = code['id']?.toString();
    });
    _safeTabController.animateTo(3);
  }

  void _resetForm() {
    _codeController.clear();
    _descriptionController.clear();
    _discountPercentController.clear();
    _maxUsesController.clear();
    _maxUsesPerUserController.text = '1';
    _selectedCodeType = 'discount_percentage';
    _selectedTiers.clear();
    _validUntil = null;
  }

  Widget _buildPromoCodesDisabledBanner() {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      margin: const EdgeInsets.only(bottom: 16),
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            t('adminPromoCodesDisabledBannerTitle'),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
        ),
      ),
    );
  }

  ({DateTime startUtc, DateTime endUtc}) _analyticsWindowUtc() {
    if (_rangePreset == '7d' ||
        _rangePreset == '30d' ||
        _rangePreset == '90d') {
      final days = int.parse(_rangePreset.replaceAll('d', ''));
      final nowLocal = DateTime.now();
      final startOfTodayLocal = DateTime(
        nowLocal.year,
        nowLocal.month,
        nowLocal.day,
      );
      final startUtc = startOfTodayLocal
          .subtract(Duration(days: days - 1))
          .toUtc();
      final endUtc = startOfTodayLocal
          .add(const Duration(days: 1))
          .subtract(const Duration(microseconds: 1))
          .toUtc();
      return (startUtc: startUtc, endUtc: endUtc);
    }

    if (_rangePreset == 'all') {
      final startUtc = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      final endUtc = DateTime.now().toUtc();
      return (startUtc: startUtc, endUtc: endUtc);
    }

    final startLocal = _customStart;
    final endLocal = _customEnd;
    if (startLocal != null && endLocal != null) {
      final startUtc = startLocal.toUtc();
      final endUtc = endLocal
          .add(const Duration(days: 1))
          .subtract(const Duration(microseconds: 1))
          .toUtc();
      return (startUtc: startUtc, endUtc: endUtc);
    }

    final nowLocal = DateTime.now();
    final startOfTodayLocal = DateTime(
      nowLocal.year,
      nowLocal.month,
      nowLocal.day,
    );
    final startUtc = startOfTodayLocal
        .subtract(const Duration(days: 29))
        .toUtc();
    final endUtc = startOfTodayLocal
        .add(const Duration(days: 1))
        .subtract(const Duration(microseconds: 1))
        .toUtc();
    return (startUtc: startUtc, endUtc: endUtc);
  }

  Widget _buildDateRangeSelector() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<String>(
              segments: [
                ButtonSegment(value: '7d', label: Text(t('adminAdsRange7d'))),
                ButtonSegment(value: '30d', label: Text(t('adminAdsRange30d'))),
                ButtonSegment(value: '90d', label: Text(t('adminAdsRange90d'))),
                ButtonSegment(value: 'all', label: Text(t('adminAdsRangeAll'))),
              ],
              selected: _rangePreset == 'custom' ? <String>{} : {_rangePreset},
              onSelectionChanged: (value) {
                if (value.isEmpty) return;
                final next = value.first;
                if (next == _rangePreset) return;
                setState(() => _rangePreset = next);
                _refreshAnalytics();
              },
            ),
            OutlinedButton.icon(
              onPressed: _pickCustomRange,
              icon: Icon(
                _rangePreset == 'custom'
                    ? Icons.event_available
                    : Icons.date_range,
                size: 18,
              ),
              label: Text(
                _rangePreset == 'custom'
                    ? t('adminAdsRangeCustomApplied')
                    : t('adminAdsRangeCustom'),
              ),
              style: _rangePreset == 'custom'
                  ? OutlinedButton.styleFrom(
                      foregroundColor: theme.colorScheme.primary,
                      side: BorderSide(color: theme.colorScheme.primary),
                    )
                  : null,
            ),
          ],
        ),
        if (_rangePreset == 'custom' &&
            _customStart != null &&
            _customEnd != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${_formatShortDateTime(_customStart!)}  →  '
                  '${_formatShortDateTime(_customEnd!)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton(
                onPressed: () {
                  setState(() {
                    _rangePreset = '30d';
                    _customStart = null;
                    _customEnd = null;
                  });
                  _refreshAnalytics();
                },
                child: Text(t('adminAdsRangeClear')),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Future<void> _pickCustomRange() async {
    final start = await _pickDateTime(_customStart ?? DateTime.now());
    if (start == null || !mounted) return;
    final end = await _pickDateTime(_customEnd ?? start);
    if (end == null || !mounted) return;
    setState(() {
      _rangePreset = 'custom';
      _customStart = start.toLocal();
      _customEnd = end.toLocal();
    });
    _refreshAnalytics();
  }

  Future<DateTime?> _pickDateTime(DateTime initialDate) async {
    final localInitial = initialDate.toLocal();
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: localInitial,
      firstDate: DateTime(2024),
      lastDate: DateTime(2035),
    );
    if (pickedDate == null || !mounted) {
      return null;
    }
    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(localInitial),
    );
    if (pickedTime == null) {
      return null;
    }
    return DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime.hour,
      pickedTime.minute,
    ).toUtc();
  }

  String _formatShortDateTime(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}/${two(dt.month)}/${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  void _refreshAnalytics() {
    setState(() {
      _cachedAnalytics = null;
      _analyticsFuture = _fetchAnalytics();
    });
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.green),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  String _localizedCodeType(String type) {
    return switch (type) {
      'discount_percentage' => t('adminPromoCodesTypeDiscountPercentage'),
      'discount_fixed' => t('adminPromoCodesTypeDiscountFixed'),
      'free_days' => t('adminPromoCodesTypeFreeDays'),
      'tier_upgrade' => t('adminPromoCodesTypeTierUpgrade'),
      _ => type,
    };
  }

  String _localizedTierLabel(String tier) {
    return switch (tier.trim().toLowerCase()) {
      'plus' => t('adminPromoCodesTierPlus'),
      'gold' => t('adminPromoCodesTierGold'),
      'platinum' => t('adminPromoCodesTierPlatinum'),
      _ => tier.toUpperCase(),
    };
  }

  String _localizedTiersLabel(dynamic tiersRaw) {
    final tiers = <String>[];
    if (tiersRaw is List) {
      tiers.addAll(tiersRaw.map((tier) => tier.toString()));
    } else if (tiersRaw is String && tiersRaw.trim().isNotEmpty) {
      tiers.addAll(
        tiersRaw
            .split(',')
            .map((tier) => tier.trim())
            .where((tier) => tier.isNotEmpty),
      );
    }

    if (tiers.isEmpty) {
      return t('adminPromoCodesInfoAllTiers');
    }

    return tiers.map(_localizedTierLabel).join(', ');
  }

  String _localizedDiscountDisplay(String codeType, int amount) {
    return switch (codeType) {
      'discount_percentage' => t(
        'adminPromoCodesBadgeDiscountPercentage',
        params: {'amount': amount.toString()},
      ),
      'discount_fixed' => t(
        'adminPromoCodesBadgeDiscountFixed',
        params: {'amount': _formatCurrency(amount / 100)},
      ),
      'free_days' => t(
        'adminPromoCodesBadgeFreeDays',
        params: {'amount': amount.toString()},
      ),
      'tier_upgrade' => t('adminPromoCodesBadgeTierUpgrade'),
      _ => codeType,
    };
  }

  String _formatAbsoluteDate(DateTime value) {
    return DateFormat.yMd(_localeCode).format(value.toLocal());
  }

  String _formatCurrency(double amount) {
    return '\$${amount.toStringAsFixed(2)}';
  }

  String _formatDateTime(dynamic dateTime) {
    if (dateTime == null) return t('adminUnknown');
    try {
      final dt = DateTime.parse(dateTime.toString());
      return DateFormat('MMM dd, yyyy - HH:mm').format(dt.toLocal());
    } catch (_) {
      return dateTime.toString();
    }
  }
}
