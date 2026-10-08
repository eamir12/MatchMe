enum ProfileSyncStatus {
  synced,
  offline,
  unauthenticated,
  notFound,
  supersededByLocalSave,
  failed,
  cancelled,
  invalidUser,
  skipped, // Debounced or duplicate sync request
}

class ProfileSyncResult {
  const ProfileSyncResult({
    required this.status,
    this.cacheAvailable = false,
    this.cacheUpdated = false,
    this.completedAt,
    this.error,
  });

  final ProfileSyncStatus status;
  final bool cacheAvailable;
  final bool cacheUpdated;
  final DateTime? completedAt;
  final Object? error;

  bool get isSuccess =>
      status == ProfileSyncStatus.synced ||
      status == ProfileSyncStatus.supersededByLocalSave ||
      status == ProfileSyncStatus.cancelled ||
      status == ProfileSyncStatus.skipped;

  bool get requiresRefresh =>
      status == ProfileSyncStatus.offline ||
      status == ProfileSyncStatus.notFound ||
      status == ProfileSyncStatus.failed;
}

class ProfileSyncState {
  const ProfileSyncState({this.isSyncing = false, this.result});

  final bool isSyncing;
  final ProfileSyncResult? result;

  bool get showStale =>
      result?.cacheAvailable == true && result!.requiresRefresh;
}

enum NoProfileStartupDecision { keepLoading, enterApp }

/// Decides whether the startup profile gate may stop waiting when no cached
/// profile exists. A failed/rate-limited/never-settling sync must not leave the
/// user on the splash forever: once the sync settles unsuccessfully, or once
/// [timeout] elapses, the caller should enter the app and let the Profile tab
/// surface the failure with a retry action.
NoProfileStartupDecision resolveNoProfileStartupDecision({
  required bool isSupabaseAvailable,
  required ProfileSyncResult? lastResult,
  required Duration elapsed,
  Duration timeout = const Duration(seconds: 8),
}) {
  if (!isSupabaseAvailable) return NoProfileStartupDecision.enterApp;
  if (lastResult != null && !lastResult.isSuccess) {
    return NoProfileStartupDecision.enterApp;
  }
  if (elapsed >= timeout) return NoProfileStartupDecision.enterApp;
  return NoProfileStartupDecision.keepLoading;
}
