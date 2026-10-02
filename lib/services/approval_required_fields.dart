// lib/services/approval_required_fields.dart
// Defines which profile and account fields require Supabase admin approval
// and cannot be edited when offline or when Supabase is unavailable.

/// Fields that require Supabase approval and cannot be edited offline
class ApprovalRequiredFields {
  /// Profile bio requires Gemini AI moderation and duplicate checking via edge function
  static const String bio = 'bio';

  /// Primary profile photo requires face detection validation and may need admin review
  static const String primaryPhotoUrl = 'primary_photo_url';

  /// Profile edit request fields that go through admin approval process
  static const List<String> profileEditRequestFields = [
    'name',
    'date_of_birth',
    'gender',
  ];

  /// All fields that require approval (for easy checking)
  static const Set<String> allApprovalRequiredFields = {
    bio,
    primaryPhotoUrl,
    ...profileEditRequestFields,
  };

  /// Check if a field requires Supabase approval
  static bool requiresApproval(String fieldName) {
    return allApprovalRequiredFields.contains(fieldName);
  }

  /// Get all approval-required fields as a list
  static List<String> getAllFields() {
    return allApprovalRequiredFields.toList();
  }

  /// Get a user-friendly translation key for why a field can't be edited offline
  static String getBlockedReasonTranslationKey(String fieldName) {
    switch (fieldName) {
      case bio:
        return 'approvalRequiredBioOfflineReason';
      case primaryPhotoUrl:
        return 'approvalRequiredPhotoOfflineReason';
      case 'name':
      case 'date_of_birth':
      case 'gender':
        return 'approvalRequiredEditRequestOfflineReason';
      default:
        return 'approvalRequiredGenericOfflineReason';
    }
  }

  /// Get reason why this field needs approval
  static String getApprovalRequiredReason(String fieldName) {
    switch (fieldName) {
      case bio:
        return 'BIO_MODERATION_REQUIRED'; // Gemini AI + duplicate check
      case primaryPhotoUrl:
        return 'PHOTO_VALIDATION_REQUIRED'; // Face detection + admin review
      case 'name':
      case 'date_of_birth':
      case 'gender':
        return 'ADMIN_REVIEW_REQUIRED'; // profile_edit_requests
      default:
        return 'APPROVAL_REQUIRED';
    }
  }
}
