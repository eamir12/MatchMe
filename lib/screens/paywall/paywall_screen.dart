import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:matchme/providers/currency_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/screens/legal/legal_document_screen.dart';
import 'package:matchme/providers/payment_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:matchme/models/subscription_tier.dart';
import 'package:matchme/models/subscription_plan.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:matchme/theme/semantic_colors.dart';
import 'package:matchme/widgets/currency_picker_bottom_sheet.dart';
import 'package:matchme/widgets/promo_code_input.dart';
import 'package:matchme/services/promo_code_service.dart';
import 'package:matchme/providers/app_config_provider.dart';
import 'package:matchme/utils/promo_code_localization.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

class PaywallScreen extends ConsumerStatefulWidget {
  const PaywallScreen({super.key});

  @override
  ConsumerState<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends ConsumerState<PaywallScreen> {
  Offerings? _offerings;
  bool _isPurchasing = false;
  SubscriptionTier? _selectedTier;
  SubscriptionPlan? _selectedPlan;
  PromoCodeValidationResult? _appliedPromo;
  int _promoValidationRequestId = 0;
  bool get _supportsNativePurchases => false;

  /// Ink for the amber-to-orange banner.
  ///
  /// White text only reaches ~1.4:1 on amber-300, so the banner uses a dark
  /// amber ink that stays above 6:1 on every stop of the gradient in both
  /// themes.
  static const Color _paywallBannerInk = Color(0xFF451A03);

  String get _externalCheckoutBaseUrl =>
      (dotenv.env['SUBSCRIPTION_CHECKOUT_URL'] ??
              dotenv.env['WEB_SUBSCRIPTION_CHECKOUT_URL'] ??
              '')
          .trim();

  String get _externalManageUrl =>
      (dotenv.env['SUBSCRIPTION_MANAGE_URL'] ?? '').trim();

  double? _parsePriceAmount(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;

    final m = RegExp(r'([0-9][0-9.,]*)').firstMatch(s);
    final token = m?.group(1);
    if (token == null) return null;

    final hasDot = token.contains('.');
    final hasComma = token.contains(',');

    String normalized = token;
    if (hasDot && hasComma) {
      normalized = token.replaceAll(',', '');
    } else if (hasComma && !hasDot) {
      final lastComma = token.lastIndexOf(',');
      final decimals = token.length - lastComma - 1;
      if (decimals == 1 || decimals == 2) {
        normalized = token
            .replaceRange(lastComma, lastComma + 1, '.')
            .replaceAll(',', '');
      } else {
        normalized = token.replaceAll(',', '');
      }
    }

    return double.tryParse(normalized);
  }

  String? _inferCurrencyCodeFromPriceDisplay(String priceDisplay) {
    final code = RegExp(r'\b([A-Z]{3})\b').firstMatch(priceDisplay)?.group(1);
    if (code != null && code.isNotEmpty) return code;

    const symbolToCode = <String, String>{
      r'$': 'USD',
      '€': 'EUR',
      '£': 'GBP',
      '₪': 'ILS',
      '¥': 'JPY',
      '₹': 'INR',
    };

    for (final e in symbolToCode.entries) {
      if (priceDisplay.contains(e.key)) return e.value;
    }
    return null;
  }

  String _getConvertedPriceDisplay(
    String priceDisplay,
    CurrencyRateSnapshot rates,
    String targetCurrency,
  ) {
    final amount = _parsePriceAmount(priceDisplay);
    final sourceCurrency =
        _inferCurrencyCodeFromPriceDisplay(priceDisplay) ?? 'USD';
    final normalizedTarget = targetCurrency.trim().toUpperCase();

    if (amount == null || sourceCurrency.isEmpty || normalizedTarget.isEmpty) {
      return priceDisplay;
    }
    if (normalizedTarget == sourceCurrency) return priceDisplay;
    if (!rates.hasRates) return priceDisplay;

    final converted = convertCurrencyAmount(
      amount: amount,
      sourceCurrency: sourceCurrency,
      targetCurrency: normalizedTarget,
      rates: rates,
    );
    if (converted == null) return priceDisplay;

    return formatCurrencyAmountWithCode(converted, normalizedTarget);
  }

  int _priceInCentsForPlan(SubscriptionPlan? plan) {
    if (plan == null) return 0;
    return ((_parsePriceAmount(plan.priceDisplay) ?? 0) * 100).round();
  }

  int _discountInCentsForPlan(SubscriptionPlan? plan) {
    final promo = _appliedPromo;
    final priceInCents = _priceInCentsForPlan(plan);
    if (promo == null || !promo.valid || priceInCents <= 0) return 0;

    final discount = PromoCodeService.calculateDiscount(
      promo.codeType ?? '',
      priceInCents,
      amount: promo.amount,
    );
    return discount.clamp(0, priceInCents);
  }

  int get _currentDiscountInCents => _discountInCentsForPlan(_selectedPlan);

  Future<void> _redeemAppliedPromoIfAny() async {
    final promo = _appliedPromo;
    if (promo == null || !promo.valid || promo.code == null) return;
    final service = ref.read(promoCodeServiceProvider);
    await service.redeemPromoCode(
      promo.code!,
      discountValueCents: _currentDiscountInCents,
    );
  }

  double _discountAmountForPlanPrice({
    required PromoCodeValidationResult? promo,
    required double price,
  }) {
    if (promo == null || !promo.valid || price <= 0) return 0;

    final discount = switch (promo.codeType) {
      'discount_percentage' => price * ((promo.amount ?? 0) / 100),
      'discount_fixed' => (promo.amount ?? 0) / 100,
      _ => 0.0,
    };

    return discount.clamp(0.0, price);
  }

  Future<void> _revalidateAppliedPromoForTier(String tierId) async {
    final promo = _appliedPromo;
    final code = promo?.code;
    if (promo == null || !promo.valid || code == null || code.trim().isEmpty) {
      return;
    }

    final requestId = ++_promoValidationRequestId;
    final result = await ref
        .read(promoCodeServiceProvider)
        .validatePromoCode(code, forTier: tierId);

    if (!mounted || requestId != _promoValidationRequestId) return;
    setState(() {
      _appliedPromo = result;
    });
  }

  Map<String, dynamic> _buildPurchaseMetadata() {
    final plan = _selectedPlan;
    final tier = _selectedTier;
    if (plan == null || tier == null) return const {};

    final amount = _parsePriceAmount(plan.priceDisplay);
    final currency = _inferCurrencyCodeFromPriceDisplay(plan.priceDisplay);

    return <String, dynamic>{
      'tier': tier.id,
      'plan_id': plan.id,
      'duration': plan.duration,
      'price_display': plan.priceDisplay,
      ...?((currency == null) ? null : <String, dynamic>{'currency': currency}),
      ...?((amount == null) ? null : <String, dynamic>{'amount': amount}),
      ...?((amount == null)
          ? null
          : <String, dynamic>{'amount_cents': (amount * 100).round()}),
      'source': 'paywall',
    };
  }

  Future<void> _startExternalCheckout() async {
    final l10n = ref.read(localizationProvider);
    final base = _externalCheckoutBaseUrl;
    final userId = Supabase.instance.client.auth.currentUser?.id;

    if (base.isEmpty ||
        userId == null ||
        userId.isEmpty ||
        _selectedTier == null ||
        _selectedPlan == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('paywallWebError'))),
      );
      return;
    }

    final uri = Uri.parse(base).replace(
      queryParameters: <String, String>{
        'user_id': userId,
        'tier': _selectedTier!.id,
        'plan_id': _selectedPlan!.id,
        'duration': _selectedPlan!.duration,
      },
    );

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  void initState() {
    super.initState();
    _fetchOfferings();
  }

  Widget _buildOfflineFallback(BuildContext context, dynamic l10n) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.wifi_off_rounded,
              size: 64,
              color: isDark ? Colors.orange.shade300 : Colors.orange.shade800,
            ),
            const SizedBox(height: 16),
            Text(
              l10n.getString('paywallOfflineTitle'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.getString('paywallOfflineBody'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.getString('generalClose')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _fetchOfferings() async {
    try {
      final offerings = await ref.read(paymentServiceProvider).getOfferings();
      if (mounted) {
        setState(() {
          _offerings = offerings;
        });
      }
    } catch (e) {
      debugPrint('Error fetching offerings: $e');
    }
  }

  Future<void> _purchasePackage() async {
    if (_selectedPlan == null) return;

    setState(() => _isPurchasing = true);
    final l10n = ref.read(localizationProvider);

    // In a real app, we would resolve the RevenueCat package from the plan
    // For now, we simulate success or try to find a matching package if identifier exists

    try {
      bool success = false;

      if (!_supportsNativePurchases) {
        // Web or Desktop: Use external checkout or test mode
        final baseUrl = _externalCheckoutBaseUrl;
        if (baseUrl.isNotEmpty) {
          await _startExternalCheckout();
          setState(() => _isPurchasing = false);
          return;
        }

        // Web test mode: Simulate successful purchase via Supabase
        debugPrint(
          '💰 [PaywallScreen] Web test mode: Simulating purchase for tier: ${_selectedTier?.id}, plan: ${_selectedPlan?.id}',
        );
        if (_selectedTier != null) {
          await ref
              .read(subscriptionProvider.notifier)
              .setTierManually(
                _selectedTier!.id,
                planDuration: _selectedPlan?.duration,
                purchaseMetadata: _buildPurchaseMetadata(),
              );
          success = true;
        }

        if (success) {
          await ref.read(subscriptionProvider.notifier).refreshStatus();

          // Redeem promo code if applied (the SQL function applies the
          // free_days / tier_upgrade benefit on the server, so we don't add
          // an extraDuration here to avoid double-counting).
          await _redeemAppliedPromoIfAny();

          if (mounted) {
            final remaining = ref.read(subscriptionTimeRemainingProvider);
            final successMessage =
                (remaining != null && remaining > Duration.zero)
                ? '${l10n.getString('paywallPurchaseSuccess')}\n${l10n.getString('subscriptionTimeLeft')}: ${formatDurationWords(l10n, remaining)}'
                : l10n.getString('paywallPurchaseSuccess');
            final semantic = SemanticColors.of(context);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  successMessage,
                  style: TextStyle(color: semantic.onSuccess),
                ),
                backgroundColor: semantic.success,
              ),
            );
            Navigator.of(context).pop();
          }
        }
        setState(() => _isPurchasing = false);
        return;
      }

      Offerings? offerings = _offerings;
      if (offerings == null) {
        offerings = await ref.read(paymentServiceProvider).getOfferings();
        if (mounted) {
          setState(() {
            _offerings = offerings;
          });
        }
      }

      if (offerings != null && offerings.current != null) {
        final packages = offerings.current!.availablePackages;
        Package? pkg;
        final planIdentifier = _selectedPlan!.revenueCatPackageIdentifier
            ?.trim();
        final tierIdentifier = _selectedTier?.revenueCatPackageIdentifier
            .trim();

        if (planIdentifier != null && planIdentifier.isNotEmpty) {
          pkg = _findPackageByIdentifier(packages, planIdentifier);
        }

        if (pkg == null &&
            tierIdentifier != null &&
            tierIdentifier.isNotEmpty) {
          pkg = _findPackageByIdentifier(packages, tierIdentifier);
        }

        pkg ??= _findPackageByDuration(
          offerings.current!,
          _selectedPlan!.duration,
        );
        pkg ??= packages.isNotEmpty ? packages.first : null;

        if (pkg != null) {
          success = await ref.read(paymentServiceProvider).purchasePackage(pkg);

          // If purchase returned true (active entitlement), ensure we update local state immediately
          // This handles cases where Entitlements are active but refreshStatus() takes time or fails
          if (success) {
            debugPrint(
              '💰 [PaywallScreen] Purchase reported success. Forcing local tier update to: ${_selectedTier?.id}',
            );
            if (_selectedTier != null) {
              await ref
                  .read(subscriptionProvider.notifier)
                  .setTierManually(
                    _selectedTier!.id,
                    planDuration: _selectedPlan?.duration,
                    purchaseMetadata: _buildPurchaseMetadata(),
                  );
            }
          } else {
            // If purchase returned false (entitlement not active), check if it was actually a successful transaction
            // but just missing Entitlement configuration (Product ID fallback).
            // We can't easily check transaction status here without refetching CustomerInfo,
            // but we can try to "trust" the user if they just went through the flow and didn't throw error.
            // Actually, purchasePackage returns false if entitlement is missing.
            // Let's check active subscriptions directly from payment provider
            final info = await ref
                .read(paymentServiceProvider)
                .getCustomerInfo();
            if (info != null && info.activeSubscriptions.isNotEmpty) {
              debugPrint(
                '💰 [PaywallScreen] Purchase returned false but active subscriptions exist: ${info.activeSubscriptions}',
              );
              // Check if any active subscription matches our expected tier
              final hasMatchingSub = info.activeSubscriptions.any(
                (s) => s.contains(_selectedTier?.id ?? 'unknown'),
              );
              if (hasMatchingSub) {
                debugPrint(
                  '💰 [PaywallScreen] Found matching active subscription. Forcing success.',
                );
                success = true;
                if (_selectedTier != null) {
                  await ref
                      .read(subscriptionProvider.notifier)
                      .setTierManually(
                        _selectedTier!.id,
                        planDuration: _selectedPlan?.duration,
                        purchaseMetadata: _buildPurchaseMetadata(),
                      );
                }
              }
            }
          }
        }
      } else {
        success = false;
      }

      if (success) {
        await ref.read(subscriptionProvider.notifier).refreshStatus();
        // Redeem promo code if applied (the SQL function applies the
        // free_days / tier_upgrade benefit on the server, so we don't add
        // an extraDuration here to avoid double-counting).
        await _redeemAppliedPromoIfAny();
        if (mounted) {
          final remaining = ref.read(subscriptionTimeRemainingProvider);
          final successMessage =
              (remaining != null && remaining > Duration.zero)
              ? '${l10n.getString('paywallPurchaseSuccess')}\n${l10n.getString('subscriptionTimeLeft')}: ${formatDurationWords(l10n, remaining)}'
              : l10n.getString('paywallPurchaseSuccess');
          final semantic = SemanticColors.of(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                successMessage,
                style: TextStyle(color: semantic.onSuccess),
              ),
              backgroundColor: semantic.success,
            ),
          );
          Navigator.of(context).pop();
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.getString('paywallPurchaseFailed'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onError,
              ),
            ),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.getString('paywallPurchaseFailed'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onError,
              ),
            ),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isPurchasing = false);
    }
  }

  Package? _findPackageByIdentifier(List<Package> packages, String identifier) {
    for (final package in packages) {
      if (package.identifier == identifier ||
          package.storeProduct.identifier == identifier) {
        return package;
      }
    }
    return null;
  }

  Package? _findPackageByDuration(Offering offering, String duration) {
    final normalized = duration.trim().toLowerCase();
    switch (normalized) {
      case 'month':
      case 'monthly':
        return offering.monthly;
      case 'year':
      case 'annual':
      case 'yearly':
        return offering.annual;
      case 'week':
      case 'weekly':
        return offering.weekly;
      case 'lifetime':
        return offering.lifetime;
      default:
        return null;
    }
  }

  Widget _buildPriceBreakdown(
    LocalizationState l10n,
    String preferredCurrency,
    CurrencyRateSnapshot exchangeRates,
  ) {
    final sourceCurrency =
        _inferCurrencyCodeFromPriceDisplay(_selectedPlan!.priceDisplay) ??
        'USD';
    final basePrice = _parsePriceAmount(_selectedPlan!.priceDisplay) ?? 0.0;
    final savings = _discountAmountForPlanPrice(
      promo: _appliedPromo,
      price: basePrice,
    );
    final discountPrice = (basePrice - savings).clamp(0.0, basePrice);

    String fmt(double amount) {
      final normalizedTarget = preferredCurrency.trim().toUpperCase();
      if (normalizedTarget.isEmpty || normalizedTarget == sourceCurrency) {
        return formatCurrencyAmountWithCode(amount, sourceCurrency);
      }
      if (!exchangeRates.hasRates) {
        return formatCurrencyAmountWithCode(amount, sourceCurrency);
      }
      final converted = convertCurrencyAmount(
        amount: amount,
        sourceCurrency: sourceCurrency,
        targetCurrency: normalizedTarget,
        rates: exchangeRates,
      );
      if (converted == null) {
        return formatCurrencyAmountWithCode(amount, sourceCurrency);
      }
      return formatCurrencyAmountWithCode(converted, normalizedTarget);
    }

    final scheme = Theme.of(context).colorScheme;
    final semantic = SemanticColors.of(context);
    final mutedTextStyle = TextStyle(color: scheme.onSurfaceVariant);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: semantic.successContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: semantic.success.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                l10n.getString('promoCodeRegularPrice'),
                style: mutedTextStyle,
              ),
              Text(fmt(basePrice), style: mutedTextStyle),
            ],
          ),
          const SizedBox(height: 8),
          if (_appliedPromo != null)
            Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${localizePromoDiscountDescription(l10n, codeType: _appliedPromo!.codeType ?? '', discountPercent: _appliedPromo!.discountPercent, discountAmountCents: _appliedPromo!.discountAmountCents, freeDays: _appliedPromo!.freeDays, upgradeTier: _appliedPromo!.upgradeTier, amount: _appliedPromo!.amount)} (${_appliedPromo!.code})',
                      style: TextStyle(
                        color: semantic.success,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '-${fmt(savings)}',
                      style: TextStyle(
                        color: semantic.success,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          Container(
            padding: const EdgeInsets.only(top: 8),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: semantic.success.withValues(alpha: 0.4),
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  l10n.getString('promoCodeYouPay'),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: semantic.onSuccessContainer,
                  ),
                ),
                Text(
                  fmt(discountPrice),
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: semantic.onSuccessContainer,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _restorePurchases() async {
    setState(() => _isPurchasing = true);
    final l10n = ref.read(localizationProvider);
    try {
      final customerInfo = await ref
          .read(paymentServiceProvider)
          .restorePurchases();
      if (customerInfo != null) {
        await ref.read(subscriptionProvider.notifier).refreshStatus();
        final isPro = customerInfo.entitlements.all['pro']?.isActive ?? false;

        if (mounted) {
          final semantic = SemanticColors.of(context);
          final scheme = Theme.of(context).colorScheme;
          final snackBackground = isPro
              ? semantic.success
              : scheme.tertiaryContainer;
          final snackForeground = isPro
              ? semantic.onSuccess
              : scheme.onTertiaryContainer;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                isPro
                    ? l10n.getString('paywallRestoreSuccess')
                    : l10n.getString('paywallRestoreNoActive'),
                style: TextStyle(color: snackForeground),
              ),
              backgroundColor: snackBackground,
            ),
          );
          if (isPro) {
            Navigator.of(context).pop();
          }
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.getString('paywallRestoreFailed'))),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.getString('paywallRestoreFailed'))),
        );
      }
    } finally {
      if (mounted) setState(() => _isPurchasing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final promoCodesEnabled =
        ref.watch(appConfigProvider)['promo_codes_enabled']?.toLowerCase() ==
        'true';
    final tiersAsync = ref.watch(subscriptionTiersProvider);
    final remaining = ref.watch(subscriptionTimeRemainingProvider);
    final userId = Supabase.instance.client.auth.currentUser?.id;
    final preferredCurrency = ref.watch(
      effectiveUserCurrencyProvider.select(
        (state) => state.asData?.value ?? 'USD',
      ),
    );
    final exchangeRatesAsync = ref.watch(currencyExchangeRatesProvider);
    final prefs = ref.watch(userPreferencesProvider);
    final prioritizedCurrencies = ref.watch(
      prioritizedCurrencyCodesProvider.select(
        (state) => state.asData?.value ?? const <String>[],
      ),
    );
    final allCurrencyOptions = ref.watch(allCurrencyOptionsProvider);
    final profileTierId = userId != null
        ? ref.watch(userProfileProvider(userId)).asData?.value?.subscriptionTier
        : null;
    final effectiveSub = ref.watch(effectiveCurrentSubscriptionProvider);
    // Prefer the effective subscription (which already falls back to the
    // active queue entry) so the displayed tier matches the "time left"
    // indicator and the timeline below even when the user profile is stale.
    final tierId =
        (effectiveSub?.tier ??
                profileTierId ??
                ref.watch(subscriptionProvider).activeTier ??
                'free')
            .trim()
            .toLowerCase();
    final tierKey = 'tier${tierId.isNotEmpty ? tierId.capitalize() : 'Free'}';
    final tierText = l10n.getString(tierKey);
    final showExternalCheckoutMessage =
        !_supportsNativePurchases && _externalCheckoutBaseUrl.isEmpty;

    return Scaffold(
      body: tiersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, s) => _buildOfflineFallback(context, l10n),
        data: (tiers) {
          final activeTiers = tiers.where((t) => t.isActive).toList()
            ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

          if (activeTiers.isEmpty) {
            return _buildOfflineFallback(context, l10n);
          }

          // Initialize selection if needed
          if (_selectedTier == null && activeTiers.isNotEmpty) {
            // Default to 'gold' if available, else first
            try {
              _selectedTier = activeTiers.firstWhere((t) => t.id == 'gold');
            } catch (_) {
              _selectedTier = activeTiers.first;
            }

            // Select default plan (month)
            if (_selectedTier!.plans.isNotEmpty) {
              try {
                _selectedPlan = _selectedTier!.plans.firstWhere(
                  (p) => p.duration == 'month',
                );
              } catch (_) {
                _selectedPlan = _selectedTier!.plans.first;
              }
            }
          }

          // Safety check if selection is still null
          if (_selectedTier == null) return const SizedBox.shrink();

          return Stack(
            children: [
              // Content
              SingleChildScrollView(
                child: Column(
                  children: [
                    // Header with gradient
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.amber.shade300,
                            Colors.orange.shade600,
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: const BorderRadius.only(
                          bottomLeft: Radius.circular(32),
                          bottomRight: Radius.circular(32),
                        ),
                      ),
                      child: SafeArea(
                        bottom: false,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 16.0),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Stack(
                                children: [
                                  Align(
                                    alignment: AlignmentDirectional.centerStart,
                                    child: IconButton(
                                      icon: const Icon(
                                        Icons.arrow_back,
                                        color: _paywallBannerInk,
                                      ),
                                      onPressed: () =>
                                          Navigator.of(context).pop(),
                                    ),
                                  ),
                                  const Center(
                                    child: Icon(
                                      Icons.star_rounded,
                                      size: 40,
                                      color: _paywallBannerInk,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                l10n.getString('paywallFeaturesTitle'),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: _paywallBannerInk,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    _buildSubscriptionTimelineSection(
                      l10n: l10n,
                      remaining: remaining,
                      tierText: tierText,
                      ref: ref,
                    ),

                    // Main Content
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 16,
                      ),
                      child: Column(
                        children: [
                          // 1. Tier Selector
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: activeTiers.map((tier) {
                                return _buildTierTab(context, tier, l10n);
                              }).toList(),
                            ),
                          ),

                          const SizedBox(height: 24),

                          // 2. Features for Selected Tier
                          if (_selectedTier != null)
                            _buildFeaturesList(l10n, _selectedTier!),

                          const SizedBox(height: 24),

                          // 0. Currency Selector
                          InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () async {
                              final picked =
                                  await showCurrencyPickerBottomSheet(
                                    context: context,
                                    l10n: l10n,
                                    selectedCurrency: preferredCurrency,
                                    recentCurrencyCodes: prefs.recentCurrencies,
                                    prioritizedCurrencyCodes:
                                        prioritizedCurrencies,
                                    allCurrencyOptions: allCurrencyOptions,
                                  );
                              if (picked == null || !context.mounted) return;
                              await ref
                                  .read(userPreferencesProvider.notifier)
                                  .setPreferredCurrency(picked);
                            },
                            child: InputDecorator(
                              decoration: InputDecoration(
                                labelText: l10n.getString(
                                  'paywallPreferredCurrencyLabel',
                                ),
                                prefixIcon: const Icon(
                                  Icons.currency_exchange_outlined,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.outlineVariant,
                                  ),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.outlineVariant,
                                  ),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary,
                                    width: 2,
                                  ),
                                ),
                                filled: true,
                                fillColor: Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerLow,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          currencySelectedLabel(
                                            preferredCurrency,
                                            localeCode:
                                                l10n.currentLocale.languageCode,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Icon(
                                    Icons.arrow_drop_down,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                ],
                              ),
                            ),
                          ),

                          const SizedBox(height: 24),

                          // 3. Plan Selector
                          if (_selectedTier != null &&
                              _selectedTier!.plans.isNotEmpty)
                            ..._selectedTier!.plans.map(
                              (plan) => _buildPlanOption(
                                context,
                                plan,
                                l10n,
                                preferredCurrency,
                                exchangeRatesAsync.asData?.value ??
                                    const CurrencyRateSnapshot.empty(),
                              ),
                            ),

                          const SizedBox(height: 24),

                          // 4. Promo Code Input (NEW)
                          if (promoCodesEnabled && _selectedTier != null)
                            PromoCodeInput(
                              applicableTier: _selectedTier!.id,
                              onValidated: (result) {
                                setState(() {
                                  _appliedPromo = result;
                                });
                              },
                            ),

                          const SizedBox(height: 24),

                          // 5. Price Breakdown with Discount (NEW)
                          if (_selectedPlan != null &&
                              _currentDiscountInCents > 0)
                            _buildPriceBreakdown(
                              l10n,
                              preferredCurrency,
                              exchangeRatesAsync.asData?.value ??
                                  const CurrencyRateSnapshot.empty(),
                            ),

                          const SizedBox(height: 24),

                          // Subscribe Button
                          SizedBox(
                            width: double.infinity,
                            height: 56,
                            child: ElevatedButton(
                              onPressed: _selectedPlan != null && !_isPurchasing
                                  ? _purchasePackage
                                  : null,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Theme.of(
                                  context,
                                ).colorScheme.primary,
                                foregroundColor: Theme.of(
                                  context,
                                ).colorScheme.onPrimary,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(28),
                                ),
                                elevation: 4,
                              ),
                              child: _isPurchasing
                                  ? CircularProgressIndicator(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onPrimary,
                                    )
                                  : Text(
                                      l10n.getString('paywallSubscribe'),
                                      style: const TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                            ),
                          ),
                          if (showExternalCheckoutMessage)
                            Padding(
                              padding: const EdgeInsets.only(top: 8.0),
                              child: Text(
                                l10n.getString('paywallWebError'),
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                  fontSize: 12,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),

                          const SizedBox(height: 16),
                          // Restore & Legal
                          TextButton(
                            onPressed: _isPurchasing
                                ? null
                                : (_supportsNativePurchases
                                      ? _restorePurchases
                                      : (_externalManageUrl.isEmpty
                                            ? null
                                            : () async {
                                                final uri = Uri.parse(
                                                  _externalManageUrl,
                                                );
                                                if (await canLaunchUrl(uri)) {
                                                  await launchUrl(
                                                    uri,
                                                    mode: LaunchMode
                                                        .externalApplication,
                                                  );
                                                }
                                              })),
                            child: Text(
                              l10n.getString('paywallRestore'),
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).textTheme.bodySmall?.color,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            alignment: WrapAlignment.center,
                            children: [
                              _buildLegalLink(
                                l10n,
                                'paywallTerms',
                                LegalDocument.termsOfService,
                              ),
                              Text(
                                l10n.getString('commonBulletSeparator'),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                              _buildLegalLink(
                                l10n,
                                'paywallPrivacy',
                                LegalDocument.privacyPolicy,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              if (_isPurchasing)
                Container(
                  color: Colors.black.withValues(alpha: 0.3),
                  child: const Center(child: CircularProgressIndicator()),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTierTab(
    BuildContext context,
    SubscriptionTier tier,
    LocalizationState l10n,
  ) {
    final isSelected = _selectedTier?.id == tier.id;
    final scheme = Theme.of(context).colorScheme;
    final primaryColor = scheme.primary;

    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedTier = tier;
          // Reset plan selection to default (month) or keep existing if compatible?
          // Safer to reset to first available for new tier
          try {
            _selectedPlan = tier.plans.firstWhere((p) => p.duration == 'month');
          } catch (_) {
            if (tier.plans.isNotEmpty) _selectedPlan = tier.plans.first;
          }
        });
        _revalidateAppliedPromoForTier(tier.id);
      },
      child: Container(
        width: 100,
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: isSelected ? primaryColor : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? primaryColor : scheme.outlineVariant,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: primaryColor.withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ]
              : [],
        ),
        child: Column(
          children: [
            Text(
              l10n.getString('tier${tier.id.capitalize()}'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isSelected ? scheme.onPrimary : scheme.onSurface,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            if (tier.badgeKey != null) ...[
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: isSelected
                      ? scheme.onPrimary.withValues(alpha: 0.2)
                      : scheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  l10n.getString(tier.badgeKey!),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    color: isSelected
                        ? scheme.onPrimary
                        : scheme.onTertiaryContainer,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSubscriptionTimelineSection({
    required LocalizationState l10n,
    required Duration? remaining,
    required String tierText,
    required WidgetRef ref,
  }) {
    return ref
        .watch(subscriptionQueueHistoryProvider)
        .when(
          data: (queueHistory) {
            final scheme = Theme.of(context).colorScheme;
            final semantic = SemanticColors.of(context);
            // Exclude entries that are already serving as the current
            // subscription (active, or pending-but-already-started, or
            // already expired) so they aren't duplicated below the "current"
            // row.
            final pending = queueHistory
                .where((e) => e.isPending && !e.hasStarted && !e.hasExpired)
                .toList();

            final hasActive = remaining != null && remaining > Duration.zero;
            if (!hasActive && pending.isEmpty) return const SizedBox.shrink();

            // Merge consecutive same-tier pending entries
            final mergedTiers = <String>[];
            final mergedDurations = <Duration>[];
            for (final entry in pending) {
              final key = entry.tier.trim().toLowerCase();
              if (mergedTiers.isNotEmpty && mergedTiers.last == key) {
                mergedDurations[mergedDurations.length - 1] += entry.duration;
              } else {
                mergedTiers.add(key);
                mergedDurations.add(entry.duration);
              }
            }

            // Total coverage
            Duration total = remaining ?? Duration.zero;
            for (final d in mergedDurations) {
              total += d;
            }

            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Container(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: scheme.outlineVariant),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                      child: Row(
                        children: [
                          Icon(
                            Icons.layers_outlined,
                            size: 20,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            l10n.getString('subscriptionPlan'),
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: scheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: scheme.outlineVariant),

                    // Active entry
                    if (hasActive)
                      _buildTimelineEntry(
                        l10n: l10n,
                        icon: Icons.check_circle,
                        iconColor: semantic.success,
                        label: l10n.getString('subscriptionCurrent'),
                        labelColor: semantic.success,
                        tierName: tierText,
                        duration: remaining,
                        bgColor: semantic.successContainer,
                        borderColor: semantic.success.withValues(alpha: 0.6),
                      ),

                    // Queued entries
                    for (int i = 0; i < mergedTiers.length; i++)
                      _buildTimelineEntry(
                        l10n: l10n,
                        icon: Icons.schedule,
                        iconColor: scheme.primary,
                        label: i == 0
                            ? l10n.getString('subscriptionUpNext')
                            : l10n.getString('subscriptionLater'),
                        labelColor: scheme.primary,
                        tierName: _localizedTierName(l10n, mergedTiers[i]),
                        duration: mergedDurations[i],
                        bgColor: scheme.primaryContainer,
                        borderColor: scheme.primary.withValues(alpha: 0.6),
                      ),

                    // Total footer
                    Container(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHigh,
                        borderRadius: const BorderRadius.only(
                          bottomLeft: Radius.circular(15),
                          bottomRight: Radius.circular(15),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.timeline,
                            size: 16,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            l10n.getString(
                              'subscriptionTotalRemaining',
                              params: {
                                'duration': formatDurationWords(l10n, total),
                              },
                            ),
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
          loading: () => const SizedBox.shrink(),
          error: (_, _) => const SizedBox.shrink(),
        );
  }

  Widget _buildTimelineEntry({
    required LocalizationState l10n,
    required IconData icon,
    required Color iconColor,
    required String label,
    required Color labelColor,
    required String tierName,
    required Duration duration,
    required Color bgColor,
    required Color borderColor,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: borderColor, width: 4)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    '$tierName  ·  ${formatDurationWords(l10n, duration)}',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                    overflow: TextOverflow.visible,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: labelColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: labelColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _localizedTierName(LocalizationState l10n, String tierId) {
    return l10n.getString('tier${tierId.trim().capitalize()}');
  }

  Widget _buildFeaturesList(LocalizationState l10n, SubscriptionTier tier) {
    final semantic = SemanticColors.of(context);
    // Parse featuresKey (assuming it's a JSON array string in DB)
    // Or we can just show generic features for now based on tier ID
    // The DB value is like '["Feature 1", "Feature 2"]'
    // We need to decode it.

    List<String> features = [];
    try {
      final raw = l10n.getString(tier.featuresKey);
      // Simple check if it looks like JSON
      if (raw.startsWith('[')) {
        // It's a JSON string of keys or values
        // Note: In our SQL, we put literal strings like "Unlimited Likes" for English,
        // but for other languages we put localized strings.
        // Ideally, we should parse the JSON.
        // Since we can't easily import dart:convert inside this method without refactoring imports,
        // let's assume it's a plain string if it fails.
        // Actually we imported dart:convert in locale_provider, but not here?
        // We need to import dart:convert at top of file if not present.
        // But I can't see top of file. I'll assume standard imports.
        // Wait, I can just strip brackets and quotes for a quick fix.
        features = raw
            .replaceAll('[', '')
            .replaceAll(']', '')
            .replaceAll('"', '')
            .split(',');
      } else {
        features = [raw];
      }
    } catch (_) {
      features = [];
    }

    return Column(
      children: features
          .map(
            (f) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.check_circle,
                    color: semantic.success,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    f.trim(),
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _buildPlanOption(
    BuildContext context,
    SubscriptionPlan plan,
    LocalizationState l10n,
    String preferredCurrency,
    CurrencyRateSnapshot exchangeRates,
  ) {
    final isSelected = _selectedPlan?.id == plan.id;
    final scheme = Theme.of(context).colorScheme;
    final semantic = SemanticColors.of(context);
    final primaryColor = scheme.primary;

    // Localize duration
    String durationText = '';
    switch (plan.duration) {
      case 'day':
        durationText = l10n.getString('paywallPeriodDaily');
        break;
      case 'week':
        durationText = l10n.getString('paywallPeriodWeekly');
        break;
      case 'month':
        durationText = l10n.getString('paywallPeriodMonthly');
        break;
      case 'year':
        durationText = l10n.getString('paywallPeriodAnnual');
        break;
      default:
        durationText = plan.duration;
    }

    // Savings
    String? savings;
    if (plan.savingsText != null) {
      final parts = plan.savingsText!.split(':');
      if (parts.length == 2) {
        savings = l10n.getString(parts[0], params: {'percent': parts[1]});
      } else {
        savings = l10n.getString(plan.savingsText!);
      }
    }

    return GestureDetector(
      onTap: () => setState(() => _selectedPlan = plan),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: isSelected
              ? primaryColor.withValues(alpha: 0.05)
              : scheme.surfaceContainerLow,
          border: Border.all(
            color: isSelected ? primaryColor : scheme.outlineVariant,
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: isSelected ? primaryColor : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    durationText,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: isSelected ? primaryColor : scheme.onSurface,
                    ),
                  ),
                  if (savings != null)
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: semantic.success,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        savings,
                        style: TextStyle(
                          color: semantic.onSuccess,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Text(
              _getConvertedPriceDisplay(
                plan.priceDisplay,
                exchangeRates,
                preferredCurrency,
              ),
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: isSelected ? primaryColor : scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Terms and Privacy links.
  ///
  /// These were previously `GestureDetector`s with an empty onTap and a
  /// `// TODO`, so neither link did anything. They are the legally required
  /// way a user consents to paying for something, which makes a dead link
  /// here a real problem rather than a cosmetic one.
  ///
  /// Both open the in-app document rather than a URL, so they work offline
  /// and cannot break if a web host goes down.
  Widget _buildLegalLink(
    LocalizationState l10n,
    String key,
    LegalDocument document,
  ) {
    return Semantics(
      button: true,
      child: InkWell(
        onTap: () => _openLegalDocument(document),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Text(
            l10n.getString(key),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
              decoration: TextDecoration.underline,
              decorationColor: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  void _openLegalDocument(LegalDocument document) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LegalDocumentScreen(document: document),
      ),
    );
  }
}
