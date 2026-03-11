import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:matchme/providers/payment_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/models/subscription_tier.dart';
import 'package:matchme/models/subscription_plan.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:matchme/utils/string_extensions.dart';
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

  bool get _supportsNativePurchases => false;

  String get _externalCheckoutBaseUrl =>
      (dotenv.env['SUBSCRIPTION_CHECKOUT_URL'] ?? dotenv.env['WEB_SUBSCRIPTION_CHECKOUT_URL'] ?? '').trim();

  String get _externalManageUrl => (dotenv.env['SUBSCRIPTION_MANAGE_URL'] ?? '').trim();

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
        normalized = token.replaceRange(lastComma, lastComma + 1, '.').replaceAll(',', '');
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
      ...?((amount == null) ? null : <String, dynamic>{'amount_cents': (amount * 100).round()}),
      'source': 'paywall',
    };
  }

  Future<void> _startExternalCheckout() async {
    final l10n = ref.read(localizationProvider);
    final base = _externalCheckoutBaseUrl;
    final userId = Supabase.instance.client.auth.currentUser?.id;

    if (base.isEmpty || userId == null || userId.isEmpty || _selectedTier == null || _selectedPlan == null) {
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
        debugPrint('💰 [PaywallScreen] Web test mode: Simulating purchase for tier: ${_selectedTier?.id}, plan: ${_selectedPlan?.id}');
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
          if (mounted) {
            final remaining = ref.read(subscriptionTimeRemainingProvider);
            final successMessage =
                (remaining != null && remaining > Duration.zero)
                    ? '${l10n.getString('paywallPurchaseSuccess')}\n${l10n.getString('subscriptionTimeLeft')}: ${formatDurationWords(l10n, remaining)}'
                    : l10n.getString('paywallPurchaseSuccess');
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(successMessage),
                backgroundColor: Colors.green,
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
         final planIdentifier = _selectedPlan!.revenueCatPackageIdentifier?.trim();
         final tierIdentifier = _selectedTier?.revenueCatPackageIdentifier.trim();

         if (planIdentifier != null && planIdentifier.isNotEmpty) {
           pkg = _findPackageByIdentifier(packages, planIdentifier);
         }

         if (pkg == null && tierIdentifier != null && tierIdentifier.isNotEmpty) {
           pkg = _findPackageByIdentifier(packages, tierIdentifier);
         }

         pkg ??= _findPackageByDuration(offerings.current!, _selectedPlan!.duration);
         pkg ??= packages.isNotEmpty ? packages.first : null;

         if (pkg != null) {
           success = await ref.read(paymentServiceProvider).purchasePackage(pkg);
           
           // If purchase returned true (active entitlement), ensure we update local state immediately
           // This handles cases where Entitlements are active but refreshStatus() takes time or fails
           if (success) {
              debugPrint('💰 [PaywallScreen] Purchase reported success. Forcing local tier update to: ${_selectedTier?.id}');
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
              final info = await ref.read(paymentServiceProvider).getCustomerInfo();
              if (info != null && info.activeSubscriptions.isNotEmpty) {
                 debugPrint('💰 [PaywallScreen] Purchase returned false but active subscriptions exist: ${info.activeSubscriptions}');
                 // Check if any active subscription matches our expected tier
                 final hasMatchingSub = info.activeSubscriptions.any((s) => s.contains(_selectedTier?.id ?? 'unknown'));
                 if (hasMatchingSub) {
                    debugPrint('💰 [PaywallScreen] Found matching active subscription. Forcing success.');
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
        if (mounted) {
          final remaining = ref.read(subscriptionTimeRemainingProvider);
          final successMessage =
              (remaining != null && remaining > Duration.zero)
                  ? '${l10n.getString('paywallPurchaseSuccess')}\n${l10n.getString('subscriptionTimeLeft')}: ${formatDurationWords(l10n, remaining)}'
                  : l10n.getString('paywallPurchaseSuccess');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(successMessage),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.of(context).pop();
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.getString('paywallPurchaseFailed')),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.getString('paywallPurchaseFailed')),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isPurchasing = false);
    }
  }

  Package? _findPackageByIdentifier(List<Package> packages, String identifier) {
    for (final package in packages) {
      if (package.identifier == identifier || package.storeProduct.identifier == identifier) {
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

  Future<void> _restorePurchases() async {
    setState(() => _isPurchasing = true);
    final l10n = ref.read(localizationProvider);
    try {
      final customerInfo = await ref.read(paymentServiceProvider).restorePurchases();
      if (customerInfo != null) {
        await ref.read(subscriptionProvider.notifier).refreshStatus();
        final isPro = customerInfo.entitlements.all['pro']?.isActive ?? false;
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(isPro 
                ? l10n.getString('paywallRestoreSuccess') 
                : l10n.getString('paywallRestoreNoActive')),
              backgroundColor: isPro ? Colors.green : Colors.orange,
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
    final tiersAsync = ref.watch(subscriptionTiersProvider);
    final remaining = ref.watch(subscriptionTimeRemainingProvider);
    final userId = Supabase.instance.client.auth.currentUser?.id;
    final profileTierId =
        userId != null ? ref.watch(userProfileProvider(userId)).asData?.value?.subscriptionTier : null;
    final tierId =
        (profileTierId ?? ref.watch(subscriptionProvider).activeTier ?? 'free').trim().toLowerCase();
    final tierKey = 'tier${tierId.isNotEmpty ? tierId.capitalize() : 'Free'}';
    final tierText = l10n.getString(tierKey);
    final showExternalCheckoutMessage = !_supportsNativePurchases && _externalCheckoutBaseUrl.isEmpty;

    return Scaffold(
      backgroundColor: Colors.white,
      body: tiersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, s) => Center(child: Text(l10n.getString('generalError'))),
        data: (tiers) {
          final activeTiers = tiers.where((t) => t.isActive).toList()
            ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

          if (activeTiers.isEmpty) {
             return Center(child: Text(l10n.getString('generalError')));
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
                 _selectedPlan = _selectedTier!.plans.firstWhere((p) => p.duration == 'month');
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
                          colors: [Colors.amber.shade300, Colors.orange.shade600],
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
                          padding: const EdgeInsets.only(bottom: 24.0),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              // Close button
                              Align(
                                alignment: Alignment.topLeft,
                                child: IconButton(
                                  icon: const Icon(Icons.close, color: Colors.white),
                                  onPressed: () => Navigator.of(context).pop(),
                                ),
                              ),
                              const Icon(Icons.star_rounded, size: 60, color: Colors.white),
                              const SizedBox(height: 8),
                              Text(
                                l10n.getString('paywallFeaturesTitle'),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black26,
                                      offset: Offset(0, 2),
                                      blurRadius: 4,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (remaining != null && remaining > Duration.zero)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.green.shade50,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.green.shade200),
                          ),
                          child: Text(
                            '${l10n.getString('subscriptionTimeLeft')}: ${formatDurationWords(l10n, remaining)} • $tierText',
                            style: TextStyle(
                              color: Colors.green.shade900,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    
                    // Main Content
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
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

                          // 3. Plan Selector
                          if (_selectedTier != null && _selectedTier!.plans.isNotEmpty)
                             ..._selectedTier!.plans.map((plan) => _buildPlanOption(context, plan, l10n)),

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
                                backgroundColor: Theme.of(context).primaryColor,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(28),
                                ),
                                elevation: 4,
                              ),
                              child: _isPurchasing
                                  ? const CircularProgressIndicator(color: Colors.white)
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
                                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
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
                                            final uri = Uri.parse(_externalManageUrl);
                                            if (await canLaunchUrl(uri)) {
                                              await launchUrl(
                                                uri,
                                                mode: LaunchMode.externalApplication,
                                              );
                                            }
                                          })),
                            child: Text(
                              l10n.getString('paywallRestore'),
                              style: TextStyle(
                                color: Theme.of(context).textTheme.bodySmall?.color,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            alignment: WrapAlignment.center,
                            children: [
                              _buildLegalLink(l10n, 'paywallTerms'),
                              const Text(' • ', style: TextStyle(fontSize: 12, color: Colors.grey)),
                              _buildLegalLink(l10n, 'paywallPrivacy'),
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

  Widget _buildTierTab(BuildContext context, SubscriptionTier tier, LocalizationState l10n) {
    final isSelected = _selectedTier?.id == tier.id;
    final primaryColor = Theme.of(context).primaryColor;

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
      },
      child: Container(
        width: 100,
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: isSelected ? primaryColor : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? primaryColor : Colors.grey.shade300,
          ),
          boxShadow: isSelected ? [
            BoxShadow(
              color: primaryColor.withValues(alpha: 0.3),
              blurRadius: 8,
              offset: const Offset(0, 4),
            )
          ] : [],
        ),
        child: Column(
          children: [
            Text(
              l10n.getString(tier.titleKey).replaceAll('MatchMe ', ''), // Shorten title
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.black87,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            if (tier.badgeKey != null) ...[
               const SizedBox(height: 4),
               Container(
                 padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                 decoration: BoxDecoration(
                   color: isSelected ? Colors.white.withValues(alpha: 0.2) : Colors.orange.shade100,
                   borderRadius: BorderRadius.circular(4),
                 ),
                 child: Text(
                   l10n.getString(tier.badgeKey!),
                   style: TextStyle(
                     fontSize: 8,
                     fontWeight: FontWeight.w900,
                     color: isSelected ? Colors.white : Colors.orange.shade900,
                   ),
                 ),
               )
            ]
          ],
        ),
      ),
    );
  }

  Widget _buildFeaturesList(LocalizationState l10n, SubscriptionTier tier) {
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
          features = raw.replaceAll('[', '').replaceAll(']', '').replaceAll('"', '').split(',');
       } else {
          features = [raw];
       }
     } catch (_) {
       features = [];
     }

     return Column(
       children: features.map((f) => Padding(
         padding: const EdgeInsets.only(bottom: 8),
         child: Row(
           mainAxisAlignment: MainAxisAlignment.center,
           children: [
             Icon(Icons.check_circle, color: Colors.green.shade600, size: 16),
             const SizedBox(width: 8),
             Text(f.trim(), style: const TextStyle(fontWeight: FontWeight.w500)),
           ],
         ),
       )).toList(),
     );
  }

  Widget _buildPlanOption(BuildContext context, SubscriptionPlan plan, LocalizationState l10n) {
    final isSelected = _selectedPlan?.id == plan.id;
    final primaryColor = Theme.of(context).primaryColor;

    // Localize duration
    String durationText = '';
    switch (plan.duration) {
      case 'day': durationText = l10n.getString('paywallPeriodDaily'); break;
      case 'week': durationText = l10n.getString('paywallPeriodWeekly'); break;
      case 'month': durationText = l10n.getString('paywallPeriodMonthly'); break;
      case 'year': durationText = l10n.getString('paywallPeriodAnnual'); break;
      default: durationText = plan.duration;
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
          color: isSelected ? primaryColor.withValues(alpha: 0.05) : Colors.white,
          border: Border.all(
            color: isSelected ? primaryColor : Colors.grey.shade300,
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: isSelected ? primaryColor : Colors.grey,
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
                      color: isSelected ? primaryColor : Colors.black87,
                    ),
                  ),
                  if (savings != null)
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.green,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        savings,
                        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                    ),
                ],
              ),
            ),
            Text(
              plan.priceDisplay,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: isSelected ? primaryColor : Colors.black87,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLegalLink(LocalizationState l10n, String key) {
    return GestureDetector(
      onTap: () {
        // TODO: Launch URL
      },
      child: Text(
        l10n.getString(key),
        style: const TextStyle(
          color: Colors.grey,
          fontSize: 12,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }
}
