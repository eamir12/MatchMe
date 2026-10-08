// lib/utils/offline_utils.dart
// Utility functions for offline UI and user interactions

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/approval_required_fields.dart';
import 'package:matchme/services/connectivity_restore_coordinator.dart';
import 'package:matchme/services/offline_cache_manager.dart';

/// True while the Flutter UI is in the foreground (resumed or briefly inactive).
/// Screen-off and backgrounding move to [AppLifecycleState.paused]/[AppLifecycleState.hidden].
bool isAppUiInForeground() {
  final state = WidgetsBinding.instance.lifecycleState;
  if (state == null) return true;
  return state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;
}

/// Check if an error is expected when offline (network-related)
bool isExpectedOfflineFailure(Object error) {
  final errorString = error.toString().toLowerCase();
  return errorString.contains('network') ||
      errorString.contains('connection') ||
      errorString.contains('timeout') ||
      errorString.contains('unreachable') ||
      errorString.contains('socket') ||
      errorString.contains('failed host lookup') ||
      errorString.contains('no address associated') ||
      errorString.contains('websocket') ||
      errorString.contains('code: 1002') ||
      errorString.contains('code: 1006');
}

/// True when the request reached Supabase but was rejected for auth,
/// rate-limit, or RLS reasons — e.g. a dead/rotated refresh token
/// (`refresh_token_already_used`), an expired JWT, HTTP 429
/// (`over_request_rate_limit`), or PostgREST 42501 (`permission denied`).
///
/// These are NOT transport failures, so [isExpectedOfflineFailure] misses
/// them — but retrying them hot just DDoSes our own backend into a 429
/// death spiral (see release incident: L10N sync loop hammering `users`
/// with a dead session). Callers should treat these as "back off and use
/// cache", never as "retry immediately".
bool isAuthRateLimitFailure(Object error) {
  final s = error.toString().toLowerCase();
  return s.contains('refresh_token_already_used') ||
      s.contains('refresh_token_not_found') ||
      s.contains('invalid refresh token') ||
      s.contains('already used') ||
      s.contains('over_request_rate_limit') ||
      s.contains('request rate limit') ||
      s.contains('rate limit reached') ||
      s.contains('statuscode: 429') ||
      s.contains('status code: 429') ||
      s.contains('code: 429') ||
      s.contains(', code: 429') ||
      s.contains('code: 42501') ||
      s.contains('42501') ||
      s.contains('permission denied') ||
      s.contains('unauthorized') ||
      s.contains('invalid jwt') ||
      s.contains('jwt expired') ||
      s.contains('token is expired') ||
      s.contains('authsessionmissing') ||
      s.contains('auth session missing') ||
      s.contains('statuscode: 401') ||
      s.contains('statuscode: 403');
}

/// Apply the app-wide offline transition for a network/realtime failure.
///
/// Realtime close callbacks can arrive before Connectivity has emitted its
/// offline state. Marking Supabase unavailable here prevents the short race
/// where REST providers still attempt requests and print SocketException logs.
bool handleExpectedSupabaseOfflineFailure(Object? error) {
  if (error == null || !isExpectedOfflineFailure(error)) return false;
  if (!OfflineCacheManager.instance.isSupabaseAvailable) return true;
  OfflineCacheManager.instance.setSupabaseAvailability(false);
  return true;
}

/// Register a callback to run when Supabase connectivity is restored (debounced).
/// Returns a function that can be called to unregister the callback.
void Function() onSupabaseResume(VoidCallback callback) {
  return ConnectivityRestoreCoordinator.instance.addListener(callback);
}

/// Called by OfflineCacheManager when Supabase becomes available again.
void notifySupabaseResumed() {
  ConnectivityRestoreCoordinator.instance.scheduleRestore(
    reason: 'supabase-available',
  );
}

/// Check if Supabase calls should be skipped (when offline)
bool shouldSkipSupabaseCalls() {
  return !OfflineCacheManager.instance.isSupabaseAvailable;
}

class SensitiveActionsOfflineNotice extends StatelessWidget {
  const SensitiveActionsOfflineNotice({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.secondaryContainer.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: colors.onSecondaryContainer.withValues(alpha: 0.12),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.wifi_off_rounded, color: colors.onSecondaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows a user-friendly dialog when an action cannot be performed offline
Future<void> showOfflineFeatureDialog(
  BuildContext context, {
  String? title,
  String? message,
  String? buttonText,
  WidgetRef? ref,
}) async {
  String dialogTitle = title ?? 'Feature Unavailable';
  String dialogMessage =
      message ?? 'This feature requires an internet connection.';
  String buttonLabel = buttonText ?? 'OK';

  if (ref != null) {
    final localization = ref.read(localizationProvider);
    if (title == null) {
      dialogTitle = localization.getString('offlineFeatureUnavailable');
    }
    if (message == null) {
      dialogMessage = localization.getString(
        'offlineFeatureRequiresConnection',
      );
    }
    if (buttonText == null) {
      buttonLabel = localization.getString('offlineOkButton');
    }
  }

  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      icon: const Icon(Icons.cloud_off_rounded, size: 32),
      title: dialogTitle.trim().isEmpty ? null : Text(dialogTitle),
      content: Text(dialogMessage),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(buttonLabel),
        ),
      ],
    ),
  );
}

/// Checks if a feature should use cached data and shows appropriate UI
/// Returns true if should use cached data (offline mode)
Future<bool> checkOfflineAndShowDialog(
  BuildContext context, {
  String? feature,
  bool showDialog = true,
  WidgetRef? ref,
}) async {
  final offlineCacheManager = OfflineCacheManager.instance;
  final isOffline = offlineCacheManager.shouldUseCachedData();

  if (isOffline && showDialog && context.mounted && ref != null) {
    final localization = ref.read(localizationProvider);
    final featureName = feature ?? 'This feature';
    final detailedMessage = localization.getString(
      'offlineCannotCompleteRequest',
    );
    final featureMessage = localization.getString(
      'offlineFeatureRequiresConnectionDetailed',
      params: {'feature': featureName},
    );

    await showOfflineFeatureDialog(
      context,
      title: detailedMessage,
      message: featureMessage,
      ref: ref,
    );
  }

  return isOffline;
}

/// Shows a toast-style notification about offline status
void showOfflineToast(BuildContext context, String message, {WidgetRef? ref}) {
  if (!context.mounted) return;

  String toastMessage = message;
  if (ref != null && message.isEmpty) {
    final localization = ref.read(localizationProvider);
    toastMessage = localization.getString('offlineSnackbarMessage');
  }

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Row(
        children: [
          const Icon(Icons.cloud_off_rounded, color: Colors.white, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(toastMessage)),
        ],
      ),
      backgroundColor: Colors.orange.shade700,
      duration: const Duration(seconds: 3),
    ),
  );
}

/// Shows a dialog when approval-required fields are blocked offline
/// fieldNames: List of field names that are blocked (e.g., ['bio', 'primary_photo_url'])
Future<void> showApprovalRequiredFieldsBlockedDialog(
  BuildContext context, {
  required List<String> blockedFields,
  required WidgetRef ref,
}) async {
  if (blockedFields.isEmpty) return;
  if (!context.mounted) return;

  final localization = ref.read(localizationProvider);

  // Build a list of reasons for each blocked field
  final reasons = blockedFields.map((field) {
    final key = ApprovalRequiredFields.getBlockedReasonTranslationKey(field);
    return localization.getString(key);
  }).toList();

  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      icon: const Icon(Icons.lock_rounded, size: 32, color: Colors.orange),
      title: Text(localization.getString('approvalRequiredEditBlocked')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              localization.getString('approvalRequiredGenericOfflineReason'),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            ...reasons.map(
              (reason) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.info_outline,
                      size: 18,
                      color: Colors.grey,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        reason,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(localization.getString('approvalRequiredOkButton')),
        ),
      ],
    ),
  );
}
