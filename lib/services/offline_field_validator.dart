import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/services/offline_cache_manager.dart';
import 'package:matchme/services/approval_required_fields.dart';
import 'package:matchme/providers/locale_provider.dart';

/// Validates whether a profile field can be edited based on offline/approval status
class OfflineFieldValidator {
  static final _instance = OfflineFieldValidator._();
  factory OfflineFieldValidator() => _instance;
  OfflineFieldValidator._();

  /// Check if a field can be edited given current connectivity state
  /// Returns: (canEdit: bool, reason: String?)
  static Future<(bool canEdit, String? reason)> canEditField(
    String fieldName, {
    required WidgetRef ref,
  }) async {
    final offlineCacheManager = OfflineCacheManager.instance;
    final localization = ref.read(localizationProvider);

    // If field doesn't require approval, it can be edited
    if (!ApprovalRequiredFields.requiresApproval(fieldName)) {
      return (true, null);
    }

    // If we have a stable connection, allow editing
    if (!offlineCacheManager.shouldUseCachedData()) {
      return (true, null);
    }

    // Field requires approval AND we're offline/unreliable connection
    final translationKey =
        ApprovalRequiredFields.getBlockedReasonTranslationKey(fieldName);
    final reason = localization.getString(translationKey);
    return (false, reason);
  }

  /// Get a user-friendly reason why a field is blocked
  static String getFieldBlockedReason(
    String fieldName,
    LocalizationState localization,
  ) {
    final translationKey =
        ApprovalRequiredFields.getBlockedReasonTranslationKey(fieldName);
    return localization.getString(translationKey);
  }

  /// Check if ANY of the provided fields require approval and we're offline
  static bool hasApprovalRequiredFieldsOffline(List<String> fieldNames) {
    if (!OfflineCacheManager.instance.shouldUseCachedData()) {
      return false; // Online, all fields allowed
    }

    // Check if any field requires approval
    return fieldNames.any(
      (field) => ApprovalRequiredFields.requiresApproval(field),
    );
  }

  /// Get all approval-required fields from a list
  static List<String> getApprovalRequiredFields(List<String> fieldNames) {
    return fieldNames
        .where((field) => ApprovalRequiredFields.requiresApproval(field))
        .toList();
  }
}
