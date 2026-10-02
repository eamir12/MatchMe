class SubscriptionPlan {
  final String id;
  final String tierId;
  final String duration;
  final String priceDisplay;
  final String? savingsText;
  final String? revenueCatPackageIdentifier;
  final int sortOrder;

  SubscriptionPlan({
    required this.id,
    required this.tierId,
    required this.duration,
    required this.priceDisplay,
    this.savingsText,
    this.revenueCatPackageIdentifier,
    required this.sortOrder,
  });

  factory SubscriptionPlan.fromMap(Map<String, dynamic> map) {
    return SubscriptionPlan(
      id: map['id'] as String,
      tierId: map['tier_id'] as String,
      duration: map['duration'] as String,
      priceDisplay: map['price_display'] as String,
      savingsText: map['savings_text'] as String?,
      revenueCatPackageIdentifier:
          map['revenue_cat_package_identifier'] as String?,
      sortOrder: map['sort_order'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'tier_id': tierId,
      'duration': duration,
      'price_display': priceDisplay,
      'savings_text': savingsText,
      'revenue_cat_package_identifier': revenueCatPackageIdentifier,
      'sort_order': sortOrder,
    };
  }
}
