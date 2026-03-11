import 'package:matchme/models/subscription_plan.dart';

class SubscriptionTier {
  final String id;
  final String revenueCatPackageIdentifier;
  final String titleKey;
  final String? subtitleKey;
  final String featuresKey;
  final String? badgeKey;
  final int sortOrder;
  final bool isActive;
  final List<SubscriptionPlan> plans;

  SubscriptionTier({
    required this.id,
    required this.revenueCatPackageIdentifier,
    required this.titleKey,
    this.subtitleKey,
    required this.featuresKey,
    this.badgeKey,
    required this.sortOrder,
    required this.isActive,
    this.plans = const [],
  });

  factory SubscriptionTier.fromMap(Map<String, dynamic> map) {
    var plansList = <SubscriptionPlan>[];
    if (map['subscription_plans'] != null) {
      plansList = (map['subscription_plans'] as List)
          .map((p) => SubscriptionPlan.fromMap(p))
          .toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    }

    return SubscriptionTier(
      id: map['id'] as String,
      revenueCatPackageIdentifier: map['revenue_cat_package_identifier'] as String,
      titleKey: map['title_key'] as String,
      subtitleKey: map['subtitle_key'] as String?,
      featuresKey: map['features_key'] as String,
      badgeKey: map['badge_key'] as String?,
      sortOrder: map['sort_order'] as int? ?? 0,
      isActive: map['is_active'] as bool? ?? true,
      plans: plansList,
    );
  }

  // Fallback data for offline/initial state
  static List<SubscriptionTier> get fallbacks => [
        SubscriptionTier(
          id: 'plus',
          revenueCatPackageIdentifier: 'matchme_plus_monthly',
          titleKey: 'tierPlusTitle',
          subtitleKey: 'tierPlusSubtitle',
          featuresKey: 'tierPlusFeatures',
          sortOrder: 10,
          isActive: true,
          plans: [
            SubscriptionPlan(id: 'plus_daily', tierId: 'plus', duration: 'day', priceDisplay: '\$1.99', sortOrder: 10),
            SubscriptionPlan(id: 'plus_weekly', tierId: 'plus', duration: 'week', priceDisplay: '\$7.99', savingsText: 'paywallSavePercent:40', sortOrder: 20),
            SubscriptionPlan(id: 'plus_monthly', tierId: 'plus', duration: 'month', priceDisplay: '\$19.99', savingsText: 'paywallSavePercent:70', sortOrder: 30),
            SubscriptionPlan(id: 'plus_annual', tierId: 'plus', duration: 'year', priceDisplay: '\$99.99', savingsText: 'paywallSavePercent:85', sortOrder: 40),
          ],
        ),
        SubscriptionTier(
          id: 'gold',
          revenueCatPackageIdentifier: 'matchme_gold_monthly',
          titleKey: 'tierGoldTitle',
          subtitleKey: 'tierGoldSubtitle',
          featuresKey: 'tierGoldFeatures',
          badgeKey: 'tierBadgeBestValue',
          sortOrder: 20,
          isActive: true,
          plans: [
            SubscriptionPlan(id: 'gold_daily', tierId: 'gold', duration: 'day', priceDisplay: '\$2.99', sortOrder: 10),
            SubscriptionPlan(id: 'gold_weekly', tierId: 'gold', duration: 'week', priceDisplay: '\$12.99', savingsText: 'paywallSavePercent:35', sortOrder: 20),
            SubscriptionPlan(id: 'gold_monthly', tierId: 'gold', duration: 'month', priceDisplay: '\$29.99', savingsText: 'paywallSavePercent:65', sortOrder: 30),
            SubscriptionPlan(id: 'gold_annual', tierId: 'gold', duration: 'year', priceDisplay: '\$149.99', savingsText: 'paywallSavePercent:85', sortOrder: 40),
          ],
        ),
        SubscriptionTier(
          id: 'platinum',
          revenueCatPackageIdentifier: 'matchme_platinum_monthly',
          titleKey: 'tierPlatinumTitle',
          subtitleKey: 'tierPlatinumSubtitle',
          featuresKey: 'tierPlatinumFeatures',
          badgeKey: 'tierBadgePopular',
          sortOrder: 30,
          isActive: true,
          plans: [
            SubscriptionPlan(id: 'platinum_daily', tierId: 'platinum', duration: 'day', priceDisplay: '\$4.99', sortOrder: 10),
            SubscriptionPlan(id: 'platinum_weekly', tierId: 'platinum', duration: 'week', priceDisplay: '\$19.99', savingsText: 'paywallSavePercent:40', sortOrder: 20),
            SubscriptionPlan(id: 'platinum_monthly', tierId: 'platinum', duration: 'month', priceDisplay: '\$49.99', savingsText: 'paywallSavePercent:65', sortOrder: 30),
            SubscriptionPlan(id: 'platinum_annual', tierId: 'platinum', duration: 'year', priceDisplay: '\$249.99', savingsText: 'paywallSavePercent:85', sortOrder: 40),
          ],
        ),
      ];
}
