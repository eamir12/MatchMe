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
      plansList =
          (map['subscription_plans'] as List)
              .map((p) => SubscriptionPlan.fromMap(p))
              .toList()
            ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    }

    return SubscriptionTier(
      id: map['id'] as String,
      revenueCatPackageIdentifier:
          map['revenue_cat_package_identifier'] as String,
      titleKey: map['title_key'] as String,
      subtitleKey: map['subtitle_key'] as String?,
      featuresKey: map['features_key'] as String,
      badgeKey: map['badge_key'] as String?,
      sortOrder: map['sort_order'] as int? ?? 0,
      isActive: map['is_active'] as bool? ?? true,
      plans: plansList,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'revenue_cat_package_identifier': revenueCatPackageIdentifier,
      'title_key': titleKey,
      'subtitle_key': subtitleKey,
      'features_key': featuresKey,
      'badge_key': badgeKey,
      'sort_order': sortOrder,
      'is_active': isActive,
      'subscription_plans': plans.map((p) => p.toMap()).toList(),
    };
  }

  static List<SubscriptionTier> get fallbacks => const [];
}
