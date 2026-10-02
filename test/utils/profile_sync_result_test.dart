import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/utils/profile_sync_result.dart';

void main() {
  test('stale state is shown only when a cached profile exists', () {
    const cachedFailure = ProfileSyncResult(
      status: ProfileSyncStatus.failed,
      cacheAvailable: true,
    );
    const uncachedFailure = ProfileSyncResult(
      status: ProfileSyncStatus.failed,
      cacheAvailable: false,
    );

    expect(const ProfileSyncState(result: cachedFailure).showStale, isTrue);
    expect(const ProfileSyncState(result: uncachedFailure).showStale, isFalse);
  });

  test('successful and locally superseded syncs do not show stale state', () {
    const synced = ProfileSyncResult(
      status: ProfileSyncStatus.synced,
      cacheAvailable: true,
      cacheUpdated: true,
    );
    const superseded = ProfileSyncResult(
      status: ProfileSyncStatus.supersededByLocalSave,
      cacheAvailable: true,
    );

    expect(synced.isSuccess, isTrue);
    expect(superseded.isSuccess, isTrue);
    expect(const ProfileSyncState(result: synced).showStale, isFalse);
    expect(const ProfileSyncState(result: superseded).showStale, isFalse);
  });

  test('offline and not-found results require a refresh', () {
    const offline = ProfileSyncResult(status: ProfileSyncStatus.offline);
    const notFound = ProfileSyncResult(status: ProfileSyncStatus.notFound);

    expect(offline.requiresRefresh, isTrue);
    expect(notFound.requiresRefresh, isTrue);
  });

  test('startup gate keeps loading while the sync is still pending', () {
    expect(
      resolveNoProfileStartupDecision(
        isSupabaseAvailable: true,
        lastResult: null,
        elapsed: const Duration(seconds: 3),
      ),
      NoProfileStartupDecision.keepLoading,
    );
  });

  test('startup gate exits the splash on a terminal sync failure', () {
    for (final status in [
      ProfileSyncStatus.failed,
      ProfileSyncStatus.notFound,
      ProfileSyncStatus.unauthenticated,
      ProfileSyncStatus.invalidUser,
      ProfileSyncStatus.offline,
    ]) {
      expect(
        resolveNoProfileStartupDecision(
          isSupabaseAvailable: true,
          lastResult: ProfileSyncResult(status: status),
          elapsed: const Duration(milliseconds: 200),
        ),
        NoProfileStartupDecision.enterApp,
        reason: '$status must not keep the user on the splash',
      );
    }
  });

  test('startup gate exits the splash when offline', () {
    expect(
      resolveNoProfileStartupDecision(
        isSupabaseAvailable: false,
        lastResult: null,
        elapsed: Duration.zero,
      ),
      NoProfileStartupDecision.enterApp,
    );
  });

  test('startup gate exits the splash when the sync never settles', () {
    expect(
      resolveNoProfileStartupDecision(
        isSupabaseAvailable: true,
        lastResult: const ProfileSyncResult(
          status: ProfileSyncStatus.synced,
          cacheAvailable: true,
        ),
        elapsed: const Duration(seconds: 8),
      ),
      NoProfileStartupDecision.enterApp,
    );
  });

  test('startup gate keeps waiting for a successful in-flight sync', () {
    expect(
      resolveNoProfileStartupDecision(
        isSupabaseAvailable: true,
        lastResult: const ProfileSyncResult(
          status: ProfileSyncStatus.synced,
          cacheAvailable: true,
        ),
        elapsed: const Duration(seconds: 2),
      ),
      NoProfileStartupDecision.keepLoading,
    );
  });
}
