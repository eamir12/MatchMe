// lib/widgets/admin_offline_indicator.dart
// Visual indicator for offline state in admin app

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme_admin/services/admin_offline_cache_manager.dart';
import 'package:matchme_admin/widgets/safe_text.dart';

/// Stream provider that mirrors Supabase availability — reactive so the
/// indicator automatically hides when connectivity is restored.
final adminConnectivityProvider = StreamProvider<bool>((ref) {
  return adminOfflineCacheManager.availabilityStream;
});

/// Widget that displays when the admin app is in offline mode
class AdminOfflineIndicator extends ConsumerWidget {
  final double height;
  final String Function(String key, {Map<String, String>? params, String? pluralParam})? t;

  const AdminOfflineIndicator({super.key, this.height = 48, this.t});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectivity = ref.watch(adminConnectivityProvider);
    // Use the stream value if available, otherwise fall back to the current
    // synchronous state (broadcast streams don't replay past emissions).
    final isOnline = connectivity.hasValue
        ? connectivity.value!
        : adminOfflineCacheManager.isSupabaseAvailable;
    final tr = t ?? ((String key, {Map<String, String>? params, String? pluralParam}) => key);

    if (isOnline) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final backgroundColor = theme.colorScheme.errorContainer;
    final foregroundColor = theme.colorScheme.onErrorContainer;

    return Container(
      height: height,
      width: double.infinity,
      decoration: BoxDecoration(
        color: backgroundColor,
        border: Border(
          bottom: BorderSide(
            color: foregroundColor.withValues(alpha: 0.25),
            width: 1,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Icon(Icons.cloud_off, size: 18, color: foregroundColor),
          const SizedBox(width: 8),
          Expanded(
            child: SafeText(
              tr('offlineIndicatorTitle'),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: foregroundColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Dialog shown when user tries to perform an action that requires internet
void showOfflineFeatureDialog(
  BuildContext context, {
  required String title,
  required String message,
  String Function(String key, {Map<String, String>? params, String? pluralParam})? t,
}) {
  final tr = t ?? ((String key, {Map<String, String>? params, String? pluralParam}) => key);
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('generalOk')),
        ),
      ],
    ),
  );
}

/// Mixin for stateful widgets that need offline handling
mixin OfflineAwareStateMixin<T extends StatefulWidget> on State<T> {
  bool get isOffline => adminOfflineCacheManager.shouldUseCachedData();

  String t(String key, {Map<String, String>? params, String? pluralParam}) => key;

  void checkOfflineBeforeAction(VoidCallback action, {String? featureName}) {
    if (isOffline) {
      final titleKey = 'offlineFeatureUnavailable';
      final msgKey = 'offlineFeatureRequiresConnection';
      showOfflineFeatureDialog(
        context,
        title: t(titleKey),
        message: t(msgKey),
        t: t,
      );
      return;
    }
    action();
  }
}
