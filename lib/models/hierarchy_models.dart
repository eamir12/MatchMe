// lib/models/hierarchy_models.dart
// Lightweight models for intents and interest categories.
// MODIFIED: InterestCategory now includes 'isSocial' (metadata removed)

class IntentOptionModel {
  final String intentKey;
  final String displayNameKey;
  final List<String> subIntentKeys;
  final int sortOrder;

  IntentOptionModel({
    required this.intentKey,
    required this.displayNameKey,
    required this.subIntentKeys,
    required this.sortOrder,
  });

  factory IntentOptionModel.fromMap(Map<String, dynamic> m) {
    return IntentOptionModel(
      intentKey: (m['intent_key'] ?? '').toString(),
      displayNameKey: (m['display_name_key'] ?? '').toString(),
      subIntentKeys:
          (m['sub_intent_keys'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      sortOrder: (m['sort_order'] is int)
          ? m['sort_order'] as int
          : int.tryParse((m['sort_order'] ?? '').toString()) ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'intent_key': intentKey,
      'display_name_key': displayNameKey,
      'sub_intent_keys': subIntentKeys,
      'sort_order': sortOrder,
    };
  }
}

class InterestItem {
  final String interestKey;
  final String interestDisplayKey;
  final int interestSortOrder;

  InterestItem({
    required this.interestKey,
    required this.interestDisplayKey,
    required this.interestSortOrder,
  });

  factory InterestItem.fromMap(Map<String, dynamic> m) {
    return InterestItem(
      interestKey: (m['interest_key'] ?? '').toString(),
      interestDisplayKey: (m['interest_display_key'] ?? '').toString(),
      interestSortOrder: (m['interest_sort_order'] is int)
          ? m['interest_sort_order'] as int
          : int.tryParse((m['interest_sort_order'] ?? '').toString()) ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'interest_key': interestKey,
      'interest_display_key': interestDisplayKey,
      'interest_sort_order': interestSortOrder,
    };
  }
}

class InterestCategory {
  final String categoryKey;
  final String categoryDisplayKey;
  final int categorySortOrder;
  final List<InterestItem> items;
  final bool isSocial; // <-- ADDED

  InterestCategory({
    required this.categoryKey,
    required this.categoryDisplayKey,
    required this.categorySortOrder,
    required this.items,
    required this.isSocial, // <-- ADDED
  });

  factory InterestCategory.fromMap(Map<String, dynamic> m) {
    return InterestCategory(
      categoryKey: (m['category_key'] ?? '').toString(),
      categoryDisplayKey: (m['category_display_key'] ?? '').toString(),
      categorySortOrder: (m['category_sort_order'] is int)
          ? m['category_sort_order'] as int
          : int.tryParse((m['category_sort_order'] ?? '').toString()) ?? 0,
      items:
          (m['items'] as List<dynamic>?)
              ?.map((i) => InterestItem.fromMap(i as Map<String, dynamic>))
              .toList() ??
          [],
      isSocial: false, // No metadata, default to false
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'category_key': categoryKey,
      'category_display_key': categoryDisplayKey,
      'category_sort_order': categorySortOrder,
      'items': items.map((i) => i.toMap()).toList(),
      'is_social': isSocial, // <-- ADDED (optional, but good practice)
    };
  }
}

class HierarchicalOptions {
  final List<IntentOptionModel> intents;
  final List<InterestCategory> interestCategories;

  HierarchicalOptions({
    required this.intents,
    required this.interestCategories,
  });

  factory HierarchicalOptions.fromMap(Map<String, dynamic> m) {
    final intentsRaw = m['intents'] as List<dynamic>? ?? [];
    final catsRaw = m['interests'] as List<dynamic>? ?? [];
    return HierarchicalOptions(
      intents: intentsRaw
          .map((i) => IntentOptionModel.fromMap(i as Map<String, dynamic>))
          .toList(),
      interestCategories: catsRaw
          .map((c) => InterestCategory.fromMap(c as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'intents': intents.map((i) => i.toMap()).toList(),
      'interests': interestCategories.map((c) => c.toMap()).toList(),
    };
  }
}
