import 'package:flutter/foundation.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/offline_cache_manager.dart';
import 'package:matchme/services/offline_image_cache.dart';
import 'package:matchme/services/storage_helper.dart';

/// Hydrates the local snapshot the Home screen streams from (profile,
/// matches, chats, intents/interests, events) into the OS page cache as soon
/// as the Hive boxes are open, so the first Home render after a warm relaunch
/// faults in already-read pages instead of cold-reading disk.
///
/// Also prefetches the Home avatars (Recent Matches + Recent Chats, capped)
/// into the encrypted OfflineImageCache shortly after the first frame, so
/// avatar bytes are local on this and every later launch — SignedImage
/// paints them with no signed-URL resolution and no network.
///
/// Purely best-effort: never throws, never blocks the UI or bootstrap. The
/// Riverpod providers remain the in-memory source of truth for the UI — this
/// only makes their first disk read instant. Re-runs when the signed-in user
/// changes (account switch on the same device).
class StartupCacheWarmer {
  StartupCacheWarmer._();

  static String? _warmedForUserId;

  /// Upper bound on distinct avatar sources warmed — roughly what fits above
  /// the fold on Home. Keeps the post-frame burst small on metered networks.
  static const int _maxAvatarSources = 20;

  /// Warms the shared home caches once per user per process.
  static Future<void> warmHomeCaches(String userId) async {
    if (userId.trim().isEmpty || _warmedForUserId == userId) return;
    _warmedForUserId = userId;
    final sw = Stopwatch()..start();
    try {
      // Open the encrypted image-byte box early so SignedImage's first read
      // doesn't pay box-open latency during the first Home frame.
      await OfflineImageCache.instance.warmup();
      final boxOpenMs = sw.elapsedMilliseconds;
      final localDb = await LocalDbService.instance;
      // Priority order matches the Home render path: profile header first,
      // then the two list streams, then reference options, then events.
      await localDb.getLocalProfile(userId);
      final matches = await offlineCacheManager.getCachedRecentMatches(userId);
      final chats = await offlineCacheManager.getCachedRecentChats(userId);
      await localDb.getCachedAppIntents();
      await localDb.getCachedAppInterests();
      await localDb.getCachedUserEvents(userId);
      debugPrint(
        '[CACHE_WARM] Home caches warmed for $userId in ${sw.elapsedMilliseconds}ms '
        '(box-open ${boxOpenMs}ms, local reads ${sw.elapsedMilliseconds - boxOpenMs}ms)',
      );
      await _warmVisibleAvatars(localDb, userId, matches, chats, sw);
    } catch (e) {
      debugPrint('[CACHE_WARM] Warm failed (non-fatal): $e');
    }
  }

  /// Fetches the first photo of each Home list row into the encrypted
  /// OfflineImageCache. Uses the same shared, in-flight-deduped byte fetch
  /// as SignedImage, so the warm never doubles a widget's own download.
  ///
  /// Delayed briefly so it never competes with the first home paint itself;
  /// by the time MatchMeApp rebuilds a second later (auth routing, profile
  /// emit), avatars are already memory-resident.
  static Future<void> _warmVisibleAvatars(
    LocalDbService localDb,
    String userId,
    List<Map<String, dynamic>> matches,
    List<Map<String, dynamic>> chats,
    Stopwatch sw,
  ) async {
    try {
      // Check BEFORE the delay: a transient setSupabaseAvailability(false)
      // (GlobalHomeSyncManager fireImmediately on wake) can land during the
      // wait and would otherwise skip the warm even though the app is online.
      if (offlineCacheManager.shouldUseCachedData()) return;
      final collectStartMs = sw.elapsedMilliseconds;
      await Future.delayed(const Duration(milliseconds: 300));
      if (offlineCacheManager.shouldUseCachedData()) return;

      final sources = <String>{};
      for (final m in matches) {
        if (sources.length >= _maxAvatarSources) break;
        final u1 = (m['user1_id'] ?? '').toString().trim();
        final u2 = (m['user2_id'] ?? '').toString().trim();
        final otherId = u1 == userId ? u2 : (u2 == userId ? u1 : '');
        if (otherId.isEmpty) continue;
        try {
          final profile = await localDb.getLocalProfile(otherId);
          final photos = profile?['photos'];
          if (photos is List && photos.isNotEmpty) {
            final source = photos.first.toString().trim();
            if (source.isNotEmpty) sources.add(source);
          }
        } catch (_) {}
      }
      for (final c in chats) {
        if (sources.length >= _maxAvatarSources) break;
        final photos = c['other_user_photos'];
        if (photos is List && photos.isNotEmpty) {
          final source = photos.first.toString().trim();
          if (source.isNotEmpty) sources.add(source);
        }
      }
      if (sources.isEmpty) return;
      final fetchStartMs = sw.elapsedMilliseconds;
      // Downloads each avatar once (deduped against in-flight widget
      // fetches) and persists the bytes into OfflineImageCache — the layer
      // SignedImage paints from, on every platform.
      await StorageHelper.prefetchImageSources(sources);
      debugPrint(
        '[CACHE_WARM] Warmed ${sources.length} home avatars in ${sw.elapsedMilliseconds}ms '
        '(collect ${fetchStartMs - collectStartMs}ms incl. 300ms delay, '
        'fetch ${sw.elapsedMilliseconds - fetchStartMs}ms)',
      );
    } catch (e) {
      debugPrint('[CACHE_WARM] Avatar warm failed (non-fatal): $e');
    }
  }
}
