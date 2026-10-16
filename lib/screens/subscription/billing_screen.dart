import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/subscription_queue_entry.dart';
import 'package:matchme/providers/currency_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/payment_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/screens/paywall/paywall_screen.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/widgets/safe_text.dart';

class BillingScreen extends ConsumerStatefulWidget {
  const BillingScreen({super.key});

  @override
  ConsumerState<BillingScreen> createState() => _BillingScreenState();
}

class _BillingScreenState extends ConsumerState<BillingScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final userId = Supabase.instance.client.auth.currentUser?.id;

    if (userId == null || userId.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: ShrinkText(l10n.getString('billingTitle'))),
        body: Center(child: Text(l10n.getString('generalError'))),
      );
    }

    final profileAsync = ref.watch(userProfileProvider(userId));
    final historyAsync = ref.watch(subscriptionQueueHistoryProvider);
    final remaining = ref.watch(subscriptionTimeRemainingProvider);
    final profile = profileAsync.asData?.value;

    if (profileAsync.isLoading && profile == null) {
      return Scaffold(
        appBar: AppBar(title: ShrinkText(l10n.getString('billingTitle'))),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (profileAsync.hasError || profile == null) {
      return Scaffold(
        appBar: AppBar(title: ShrinkText(l10n.getString('billingTitle'))),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              l10n.getString('generalError'),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final history =
        historyAsync.asData?.value ?? const <SubscriptionQueueEntry>[];
    final methods = _collectPaymentMethods(history, l10n);
    final activeTier = profile.subscriptionTier.trim().toLowerCase();
    final hasActivePlan =
        activeTier.isNotEmpty &&
        activeTier != 'free' &&
        profile.subscriptionExpiresAt != null &&
        profile.subscriptionExpiresAt!.toUtc().isAfter(DateTime.now().toUtc());
    final uniqueProviders = history
        .map((entry) => _providerLabel(entry.paymentProvider, l10n))
        .where((provider) => provider.isNotEmpty)
        .toSet()
        .length;

    final activeEntries = history.where(_isActiveEntry).toList();
    final scheduledEntries = history.where(_isScheduledEntry).toList();
    final completedEntries = history.where(_isCompletedEntry).toList();

    return Scaffold(
      appBar: AppBar(title: ShrinkText(l10n.getString('billingTitle'))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.getString('billingCurrentPlan'),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _InfoChip(
                        icon: Icons.workspace_premium_outlined,
                        label: _tierLabel(
                          l10n,
                          hasActivePlan ? activeTier : 'free',
                        ),
                      ),
                      _InfoChip(
                        icon: hasActivePlan
                            ? Icons.check_circle_outline
                            : Icons.history,
                        label: l10n.getString(
                          hasActivePlan
                              ? 'billingActive'
                              : 'billingNoActivePlan',
                        ),
                      ),
                      _InfoChip(
                        icon: Icons.receipt_long_outlined,
                        label: l10n.getString(
                          'billingTotalTransactions',
                          params: {'count': history.length.toString()},
                        ),
                      ),
                      _InfoChip(
                        icon: Icons.account_balance_wallet_outlined,
                        label: l10n.getString(
                          'billingMethodsUsed',
                          params: {'count': methods.length.toString()},
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _DetailRow(
                    label: l10n.getString('billingPlanStatus'),
                    value: l10n.getString(
                      hasActivePlan ? 'billingActive' : 'billingNoActivePlan',
                    ),
                  ),
                  if (profile.subscriptionExpiresAt != null)
                    _DetailRow(
                      label: l10n.getString('billingExpiresOn'),
                      value: _formatDateTime(
                        context,
                        ref,
                        l10n,
                        profile.subscriptionExpiresAt!,
                      ),
                    ),
                  if (remaining != null && remaining > Duration.zero)
                    _DetailRow(
                      label: l10n.getString('billingTimeLeft'),
                      value: formatDurationWords(l10n, remaining),
                    ),
                  if (history.isNotEmpty)
                    _DetailRow(
                      label: l10n.getString('billingProvidersUsed'),
                      value: uniqueProviders.toString(),
                    ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const PaywallScreen(),
                          ),
                        );
                      },
                      icon: const Icon(Icons.tune),
                      label: Text(l10n.getString('billingManagePlan')),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.getString('billingPaymentMethods'),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (historyAsync.isLoading)
                    const LinearProgressIndicator()
                  else if (methods.isEmpty)
                    Text(l10n.getString('billingPaymentMethodsEmpty'))
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: methods
                          .map(
                            (method) => _InfoChip(
                              icon: Icons.credit_card_outlined,
                              label: method,
                            ),
                          )
                          .toList(),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _SectionCard(
              padding: EdgeInsets.zero,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      l10n.getString('billingHistory'),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  TabBar(
                    controller: _tabController,
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    labelColor: Theme.of(context).colorScheme.primary,
                    unselectedLabelColor: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant,
                    indicatorColor: Theme.of(context).colorScheme.primary,
                    tabs: [
                      Tab(
                        child: _TabLabel(
                          label: l10n.getString('billingTabActive'),
                          count: activeEntries.length,
                        ),
                      ),
                      Tab(
                        child: _TabLabel(
                          label: l10n.getString('billingTabScheduled'),
                          count: scheduledEntries.length,
                        ),
                      ),
                      Tab(
                        child: _TabLabel(
                          label: l10n.getString('billingTabCompleted'),
                          count: completedEntries.length,
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 1),
                  AnimatedBuilder(
                    animation: _tabController,
                    builder: (context, _) {
                      final tabEntries = [
                        activeEntries,
                        scheduledEntries,
                        completedEntries,
                      ];
                      final tabEmptyMessages = [
                        l10n.getString('billingEmptyActive'),
                        l10n.getString('billingEmptyScheduled'),
                        l10n.getString('billingEmptyCompleted'),
                      ];
                      final selectedIndex = _tabController.index;
                      return _BillingHistoryList(
                        entries: tabEntries[selectedIndex],
                        l10n: l10n,
                        ref: ref,
                        isLoading: historyAsync.isLoading,
                        hasError: historyAsync.hasError,
                        emptyMessage: tabEmptyMessages[selectedIndex],
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

bool _isActiveEntry(SubscriptionQueueEntry entry) {
  if (entry.isCancelled) return false;
  if (entry.isActive) return !entry.hasExpired;
  if (entry.isPending) return entry.hasStarted && !entry.hasExpired;
  return false;
}

bool _isScheduledEntry(SubscriptionQueueEntry entry) {
  if (entry.isCancelled) return false;
  if (entry.isCompleted) return false;
  if (entry.isPending) return !entry.hasStarted;
  return false;
}

bool _isCompletedEntry(SubscriptionQueueEntry entry) {
  if (entry.isCancelled) return true;
  if (entry.isCompleted) return true;
  return entry.hasExpired;
}

bool _isPromoEntry(SubscriptionQueueEntry entry) {
  final provider = (entry.paymentProvider ?? '').trim().toLowerCase();
  if (provider == 'promo_code') return true;
  final source = _metadataString(entry.purchaseMetadata, const [
    'source',
    'origin',
  ])?.toLowerCase();
  return source == 'promo_code';
}

class _TabLabel extends StatelessWidget {
  const _TabLabel({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text(label, overflow: TextOverflow.visible)),
          if (count > 0) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                count > 99 ? '99+' : count.toString(),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _BillingHistoryList extends StatelessWidget {
  const _BillingHistoryList({
    required this.entries,
    required this.l10n,
    required this.ref,
    required this.isLoading,
    required this.hasError,
    required this.emptyMessage,
  });

  final List<SubscriptionQueueEntry> entries;
  final LocalizationState l10n;
  final WidgetRef ref;
  final bool isLoading;
  final bool hasError;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (hasError) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: Text(l10n.getString('generalError'))),
      );
    }
    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            emptyMessage,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        children: [
          for (int i = 0; i < entries.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            _BillingEntryCard(
              entry: entries[i],
              l10n: l10n,
              ref: ref,
              isPromo: _isPromoEntry(entries[i]),
            ),
          ],
        ],
      ),
    );
  }
}

class _BillingEntryCard extends StatelessWidget {
  const _BillingEntryCard({
    required this.entry,
    required this.l10n,
    required this.ref,
    this.isPromo = false,
  });

  final SubscriptionQueueEntry entry;
  final LocalizationState l10n;
  final WidgetRef ref;
  final bool isPromo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final amountLabel = _amountLabel(entry, l10n);
    final paymentMethod = _paymentMethodLabel(entry, l10n);
    final providerLabel = _providerLabel(entry.paymentProvider, l10n);
    final promoCode = _metadataString(entry.purchaseMetadata, const [
      'promo_code',
      'promoCode',
    ]);
    final transactionId = entry.transactionId?.trim() ?? '';
    final status = _statusDisplay(entry, l10n);

    final effectiveAmountLabel = isPromo
        ? l10n.getString('billingFree')
        : amountLabel;

    return Material(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(16),
      child: ExpansionTile(
        collapsedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        title: Row(
          children: [
            Flexible(
              child: Text(
                _tierLabel(l10n, entry.tier),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                overflow: TextOverflow.visible,
              ),
            ),
            if (isPromo) ...[
              const SizedBox(width: 8),
              _PromoBadge(label: l10n.getString('billingPromoBadge')),
            ],
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(_formatDateTime(context, ref, l10n, entry.createdAt)),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _StatusBadge(status: status),
            if (effectiveAmountLabel != null) ...[
              const SizedBox(height: 2),
              Text(
                effectiveAmountLabel,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: isPromo ? Colors.green.shade700 : null,
                ),
              ),
            ],
          ],
        ),
        children: [
          if (effectiveAmountLabel != null)
            _DetailRow(
              label: l10n.getString('billingAmount'),
              value: effectiveAmountLabel,
            ),
          _DetailRow(
            label: l10n.getString('billingProvider'),
            value: providerLabel.isEmpty
                ? l10n.getString('billingUnknownProvider')
                : providerLabel,
          ),
          _DetailRow(
            label: l10n.getString('billingPaymentMethod'),
            value: paymentMethod,
          ),
          _DetailRow(
            label: l10n.getString('billingPurchasedOn'),
            value: _formatDateTime(context, ref, l10n, entry.createdAt),
          ),
          _DetailRow(
            label: l10n.getString('billingStartsOn'),
            value: _formatDateTime(context, ref, l10n, entry.startsAt),
          ),
          _DetailRow(
            label: l10n.getString('billingExpiresOn'),
            value: _formatDateTime(context, ref, l10n, entry.expiresAt),
          ),
          if (entry.activatedAt != null)
            _DetailRow(
              label: l10n.getString('billingActivatedOn'),
              value: _formatDateTime(context, ref, l10n, entry.activatedAt!),
            ),
          if (entry.cancelledAt != null)
            _DetailRow(
              label: l10n.getString('billingCancelledOn'),
              value: _formatDateTime(context, ref, l10n, entry.cancelledAt!),
            ),
          if ((entry.cancellationReason ?? '').trim().isNotEmpty)
            _DetailRow(
              label: l10n.getString('billingCancellationReason'),
              value: entry.cancellationReason!.trim(),
            ),
          if (promoCode != null && !isPromo)
            _DetailRow(
              label: l10n.getString('billingPromoCode'),
              value: promoCode,
            ),
          if (transactionId.isNotEmpty)
            _DetailRow(
              label: l10n.getString('billingTransactionId'),
              value: transactionId,
            ),
        ],
      ),
    );
  }
}

class _PromoBadge extends StatelessWidget {
  const _PromoBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.green.shade200),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.local_offer_outlined,
            size: 12,
            color: Colors.green.shade700,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Colors.green.shade700,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: theme.shadowColor.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Flexible(child: Text(label, overflow: TextOverflow.visible)),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(flex: 6, child: Text(value, textAlign: TextAlign.end)),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final _BillingStatusStyle status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: status.background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          color: status.foreground,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _BillingStatusStyle {
  const _BillingStatusStyle({
    required this.label,
    required this.background,
    required this.foreground,
  });

  final String label;
  final Color background;
  final Color foreground;
}

_BillingStatusStyle _statusDisplay(
  SubscriptionQueueEntry entry,
  LocalizationState l10n,
) {
  if (entry.isCancelled) {
    return _BillingStatusStyle(
      label: l10n.getString('billingCancelled'),
      background: Colors.red.shade50,
      foreground: Colors.red.shade700,
    );
  }

  if (entry.isActive) {
    return _BillingStatusStyle(
      label: l10n.getString('billingActive'),
      background: Colors.green.shade50,
      foreground: Colors.green.shade700,
    );
  }

  if (entry.isPending && !entry.hasStarted) {
    return _BillingStatusStyle(
      label: l10n.getString('billingScheduled'),
      background: Colors.blue.shade50,
      foreground: Colors.blue.shade700,
    );
  }

  return _BillingStatusStyle(
    label: l10n.getString('billingCompleted'),
    background: Colors.grey.shade200,
    foreground: Colors.grey.shade800,
  );
}

List<String> _collectPaymentMethods(
  List<SubscriptionQueueEntry> entries,
  LocalizationState l10n,
) {
  final methods = <String>{};
  for (final entry in entries) {
    final method = _paymentMethodLabel(entry, l10n);
    if (method.isNotEmpty) {
      methods.add(method);
    }
  }
  return methods.toList()..sort();
}

String _paymentMethodLabel(
  SubscriptionQueueEntry entry,
  LocalizationState? l10n,
) {
  final metadata = entry.purchaseMetadata;
  final explicitLabel = _metadataString(metadata, const [
    'payment_method_label',
    'payment_method',
    'paymentMethod',
    'wallet',
  ]);
  if (explicitLabel != null && explicitLabel.trim().isNotEmpty) {
    return _humanizeToken(explicitLabel);
  }

  final brand = _metadataString(metadata, const ['card_brand', 'brand']);
  final last4 = _metadataString(metadata, const ['card_last4', 'last4']);
  if (brand != null && last4 != null && last4.isNotEmpty) {
    return '${_humanizeToken(brand)} •••• $last4';
  }

  final provider = _providerLabel(entry.paymentProvider, l10n);
  if (provider.isNotEmpty) {
    return provider;
  }

  return l10n?.getString('billingUnknownMethod') ?? '';
}

String _providerLabel(String? provider, LocalizationState? l10n) {
  final normalized = (provider ?? '').trim().toLowerCase();
  switch (normalized) {
    case 'revenuecat':
      return 'RevenueCat';
    case 'stripe':
      return 'Stripe';
    case 'manual':
      return l10n?.getString('billingPaymentMethodManual') ?? 'Manual';
    case 'promo_code':
      return l10n?.getString('billingPaymentMethodPromoCode') ??
          _humanizeToken(normalized);
    default:
      return _humanizeToken(normalized);
  }
}

String? _amountLabel(SubscriptionQueueEntry entry, LocalizationState l10n) {
  final metadata = entry.purchaseMetadata;
  final locale = l10n.currentLocale.toLanguageTag();

  final displayAmountCents = _metadataInt(metadata, const [
    'display_amount_cents',
    'displayAmountCents',
  ]);
  final displayCurrency = _metadataString(metadata, const [
    'display_currency',
    'displayCurrency',
  ]);
  if (displayAmountCents != null && displayCurrency != null) {
    return formatCurrencyAmountWithCode(
      displayAmountCents / 100,
      displayCurrency,
      locale: locale,
    );
  }

  final amountCents = _metadataInt(metadata, const [
    'amount_cents',
    'amountCents',
  ]);
  final currency = _metadataString(metadata, const ['currency']);
  if (amountCents != null && currency != null) {
    return formatCurrencyAmountWithCode(
      amountCents / 100,
      currency,
      locale: locale,
    );
  }

  final displayAmount = _metadataDouble(metadata, const [
    'display_amount',
    'displayAmount',
  ]);
  if (displayAmount != null && displayCurrency != null) {
    return formatCurrencyAmountWithCode(
      displayAmount,
      displayCurrency,
      locale: locale,
    );
  }

  final amount = _metadataDouble(metadata, const ['amount']);
  if (amount != null && currency != null) {
    return formatCurrencyAmountWithCode(amount, currency, locale: locale);
  }

  return null;
}

String _tierLabel(LocalizationState l10n, String tier) {
  switch (tier.trim().toLowerCase()) {
    case 'plus':
      return l10n.getString('tierPlus');
    case 'gold':
      return l10n.getString('tierGold');
    case 'platinum':
      return l10n.getString('tierPlatinum');
    default:
      return l10n.getString('tierFree');
  }
}

String _formatDateTime(
  BuildContext context,
  WidgetRef ref,
  LocalizationState l10n,
  DateTime dateTime,
) {
  final local = dateTime.toLocal();
  return formatDateAndTimeOfDateTimeWithPrefs(context, ref, l10n, local);
}

String _humanizeToken(String raw) {
  final cleaned = raw.trim().replaceAll(RegExp(r'[_-]+'), ' ');
  if (cleaned.isEmpty) return '';
  return cleaned
      .split(RegExp(r'\s+'))
      .map((part) {
        if (part.isEmpty) return part;
        final upper = part.toUpperCase();
        if (upper.length <= 4 && upper == part) return part;
        return '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}';
      })
      .join(' ');
}

String? _metadataString(Map<String, dynamic> metadata, List<String> keys) {
  for (final key in keys) {
    final value = metadata[key];
    if (value == null) continue;
    final text = value.toString().trim();
    if (text.isNotEmpty && text.toLowerCase() != 'null') {
      return text;
    }
  }
  return null;
}

int? _metadataInt(Map<String, dynamic> metadata, List<String> keys) {
  for (final key in keys) {
    final value = metadata[key];
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
  }
  return null;
}

double? _metadataDouble(Map<String, dynamic> metadata, List<String> keys) {
  for (final key in keys) {
    final value = metadata[key];
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is num) return value.toDouble();
    if (value is String) {
      final parsed = double.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
  }
  return null;
}
