import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/models/subscription_tier.dart';
import 'package:matchme/models/subscription_queue_entry.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/utils/offline_utils.dart';

class SubscriptionService {
  final SupabaseClient _supabase;

  SubscriptionService(this._supabase);

  /// In-memory layer for subscription tiers (memory + Hive).
  static List<SubscriptionTier>? _tiersMemory;
  static DateTime? _tiersMemoryAt;
  static const Duration _tiersFreshFor = Duration(minutes: 30);
  static bool _tiersRefreshInFlight = false;

  /// Cache-first read with NO network: memory first, then local storage.
  Future<List<SubscriptionTier>> loadCachedTiersFast() async {
    if (_tiersMemory != null && _tiersMemory!.isNotEmpty) return _tiersMemory!;
    final cached = await _loadCachedTiers();
    if (cached.isNotEmpty) {
      _tiersMemory = cached;
      _tiersMemoryAt = DateTime.now();
    }
    return cached;
  }

  bool isTiersMemoryFresh() {
    if (_tiersMemory == null || _tiersMemory!.isEmpty) return false;
    if (_tiersMemoryAt == null) return false;
    return DateTime.now().difference(_tiersMemoryAt!) < _tiersFreshFor;
  }

  /// Background refresh: updates memory + Hive, never throws.
  /// Returns fresh list or null on failure/offline.
  Future<List<SubscriptionTier>?> refreshTiersInBackground() async {
    if (shouldSkipSupabaseCalls()) return null;
    if (_supabase.auth.currentSession == null) return null;
    if (_tiersRefreshInFlight) return null;
    _tiersRefreshInFlight = true;
    try {
      final response = await _supabase
          .from('subscription_tiers')
          .select('*, subscription_plans(*)')
          .eq('is_active', true)
          .order('sort_order', ascending: true);
      final tiers = (response as List)
          .map((data) => SubscriptionTier.fromMap(data))
          .toList();
      if (tiers.isNotEmpty) {
        _tiersMemory = tiers;
        _tiersMemoryAt = DateTime.now();
        try {
          final localDb = await LocalDbService.instance;
          await localDb.saveSubscriptionTiers(
            tiers.map((t) => t.toMap()).toList(),
          );
        } catch (_) {}
      }
      return tiers;
    } catch (_) {
      return null;
    } finally {
      _tiersRefreshInFlight = false;
    }
  }

  Future<void> _cacheQueueHistory(
    String userId,
    List<SubscriptionQueueEntry> entries,
  ) async {
    try {
      final localDb = await LocalDbService.instance;
      final maps = <Map<String, dynamic>>[];
      for (final entry in entries) {
        maps.add(entry.toMap());
      }
      await localDb.saveSubscriptionQueueHistory(userId, maps);
    } catch (e) {
      print('⚠️ Error caching subscription queue history: $e');
    }
  }

  Future<List<SubscriptionQueueEntry>> _loadCachedQueueHistory(
    String userId,
  ) async {
    try {
      final localDb = await LocalDbService.instance;
      final cached = await localDb.getSubscriptionQueueHistory(userId);
      if (cached == null || cached.isEmpty) return [];

      final history = cached
          .map((entry) => SubscriptionQueueEntry.fromMap(entry))
          .toList();
      history.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return history;
    } catch (e) {
      print('⚠️ Error loading cached subscription queue history: $e');
      return [];
    }
  }

  /// Fetches active subscription tiers from Supabase.
  /// Returns a list of [SubscriptionTier] sorted by [sortOrder].
  /// Cache-first (memory + Hive): returns cached snapshot instantly when
  /// available, refreshes from Supabase in background.
  /// When the device is offline, falls back to the most recent cached
  /// snapshot so the paywall screen can still render (otherwise the user
  /// would see a perpetual spinner followed by a "Something went wrong"
  /// error after the Supabase call times out).
  Future<List<SubscriptionTier>> fetchTiers() async {
    // 1) Memory layer — instant.
    if (_tiersMemory != null && _tiersMemory!.isNotEmpty) {
      if (!isTiersMemoryFresh() && !shouldSkipSupabaseCalls()) {
        unawaited(refreshTiersInBackground());
      }
      return _tiersMemory!;
    }
    // 2) Local-storage layer — fast, survives restarts.
    try {
      final cached = await _loadCachedTiers();
      if (cached.isNotEmpty) {
        _tiersMemory = cached;
        _tiersMemoryAt = DateTime.now();
        if (!shouldSkipSupabaseCalls()) {
          unawaited(refreshTiersInBackground());
        }
        return cached;
      }
    } catch (_) {}
    if (shouldSkipSupabaseCalls()) {
      final cached = await _loadCachedTiers();
      if (cached.isNotEmpty) return cached;
      // Truly offline + no cache: surface a friendly empty list so the
      // caller can show an offline-specific message instead of a generic
      // error.
      return [];
    }
    if (_supabase.auth.currentSession == null) {
      return [];
    }
    try {
      final response = await _supabase
          .from('subscription_tiers')
          .select('*, subscription_plans(*)')
          .eq('is_active', true)
          .order('sort_order', ascending: true);

      final tiers = (response as List)
          .map((data) => SubscriptionTier.fromMap(data))
          .toList();

      // Best-effort cache to BOTH memory and local storage.
      _tiersMemory = tiers;
      _tiersMemoryAt = DateTime.now();
      try {
        final localDb = await LocalDbService.instance;
        await localDb.saveSubscriptionTiers(
          tiers.map((t) => t.toMap()).toList(),
        );
      } catch (e) {
        print('⚠️ Error caching subscription tiers: $e');
      }

      return tiers;
    } catch (e) {
      if (!isAuthRateLimitFailure(e) &&
          !handleExpectedSupabaseOfflineFailure(e)) {
        print('⚠️ Error fetching subscription tiers: $e');
      }
      // Network or server failure: fall back to the cache so the paywall
      // can still render the most recent tier set.
      final cached = await _loadCachedTiers();
      if (cached.isNotEmpty) return cached;
      // No cache available either: return an empty list rather than
      // throwing, so the caller can render an offline message instead of
      // a perpetual error.
      return [];
    }
  }

  Future<List<SubscriptionTier>> _loadCachedTiers() async {
    try {
      final localDb = await LocalDbService.instance;
      final cached = await localDb.getSubscriptionTiers();
      if (cached == null || cached.isEmpty) return [];
      return cached.map((tier) => SubscriptionTier.fromMap(tier)).toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    } catch (e) {
      print('⚠️ Error loading cached subscription tiers: $e');
      return [];
    }
  }

  // ============================================================================
  // SUBSCRIPTION QUEUE METHODS
  // ============================================================================

  /// Fetches the subscription queue for a user.
  /// Returns pending and active queued subscriptions sorted by start time.
  Future<List<SubscriptionQueueEntry>> fetchSubscriptionQueue(
    String userId,
  ) async {
    if (shouldSkipSupabaseCalls()) return _loadCachedQueueHistory(userId);
    try {
      final response = await _supabase
          .from('user_subscription_queue')
          .select()
          .eq('user_id', userId)
          .inFilter('status', ['pending', 'active'])
          .order('starts_at', ascending: true);

      return (response as List)
          .map((data) => SubscriptionQueueEntry.fromMap(data))
          .toList();
    } catch (e) {
      if (!isAuthRateLimitFailure(e) && !isExpectedOfflineFailure(e)) {
        print('⚠️ Error fetching subscription queue: $e');
      }
      final cachedHistory = await _loadCachedQueueHistory(userId);
      final queued = cachedHistory
          .where((entry) => entry.isPending || entry.isActive)
          .toList();
      queued.sort((a, b) => a.startsAt.compareTo(b.startsAt));
      return queued;
    }
  }

  /// Adds a subscription to the queue using the database function.
  /// Automatically calculates the start time based on existing subscriptions.
  Future<SubscriptionQueueEntry?> addToQueue({
    required String userId,
    required String tier,
    required Duration duration,
    String paymentProvider = 'manual',
    String? transactionId,
    Map<String, dynamic> metadata = const {},
  }) async {
    if (shouldSkipSupabaseCalls()) return null;

    try {
      final response = await _supabase.rpc(
        'add_subscription_to_queue',
        params: {
          'p_user_id': userId,
          'p_tier': tier,
          'p_duration_seconds': duration.inSeconds,
          'p_payment_provider': paymentProvider,
          'p_transaction_id': transactionId,
          'p_metadata': metadata,
        },
      );

      if (response != null && response is List && response.isNotEmpty) {
        final data = response.first as Map<String, dynamic>;
        // Fetch the full entry after creation
        final fullEntry = await _supabase
            .from('user_subscription_queue')
            .select()
            .eq('id', data['queue_entry_id'])
            .single();
        return SubscriptionQueueEntry.fromMap(fullEntry);
      }
      return null;
    } catch (e) {
      if (!isAuthRateLimitFailure(e) && !isExpectedOfflineFailure(e)) {
        print('⚠️ Error adding subscription to queue: $e');
      }
      return null;
    }
  }

  /// Gets the next queued subscription for a user.
  Future<SubscriptionQueueEntry?> getNextQueuedSubscription(
    String userId,
  ) async {
    if (shouldSkipSupabaseCalls()) return null;

    try {
      final response = await _supabase.rpc(
        'get_next_queued_subscription',
        params: {'p_user_id': userId},
      );

      if (response != null && response is List && response.isNotEmpty) {
        final data = response.first as Map<String, dynamic>;
        // Fetch the full entry
        final fullEntry = await _supabase
            .from('user_subscription_queue')
            .select()
            .eq('id', data['queue_id'])
            .single();
        return SubscriptionQueueEntry.fromMap(fullEntry);
      }
      return null;
    } catch (e) {
      if (!isAuthRateLimitFailure(e) && !isExpectedOfflineFailure(e)) {
        print('⚠️ Error getting next queued subscription: $e');
      }
      return null;
    }
  }

  /// Cancels a queued subscription.
  Future<bool> cancelQueuedSubscription(
    String queueId, {
    String? reason,
  }) async {
    if (shouldSkipSupabaseCalls()) return false;

    try {
      final response = await _supabase.rpc(
        'cancel_queued_subscription',
        params: {'p_queue_id': queueId, 'p_reason': reason},
      );
      return response == true;
    } catch (e) {
      if (!isAuthRateLimitFailure(e) && !isExpectedOfflineFailure(e)) {
        print('⚠️ Error cancelling queued subscription: $e');
      }
      return false;
    }
  }

  /// Gets the full subscription timeline for a user.
  /// Combines current subscription from users table with queued subscriptions.
  Future<SubscriptionTimeline> getSubscriptionTimeline(String userId) async {
    if (shouldSkipSupabaseCalls()) return SubscriptionTimeline(queued: []);
    try {
      // Get current subscription info from users table
      final userResponse = await _supabase
          .from('users')
          .select('subscription_tier, subscription_expires_at')
          .eq('id', userId)
          .single();

      SubscriptionQueueEntry? current;
      final tier = userResponse['subscription_tier']?.toString();
      final expiresAt = userResponse['subscription_expires_at'] != null
          ? DateTime.parse(userResponse['subscription_expires_at'] as String)
          : null;

      if (tier != null &&
          tier != 'free' &&
          expiresAt != null &&
          expiresAt.isAfter(DateTime.now())) {
        current = SubscriptionQueueEntry(
          id: 'current',
          userId: userId,
          tier: tier,
          status: 'active',
          startsAt: DateTime.now().subtract(const Duration(days: 1)),
          expiresAt: expiresAt,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
      }

      // Get queued subscriptions
      final queued = await fetchSubscriptionQueue(userId);

      return SubscriptionTimeline(current: current, queued: queued);
    } catch (e) {
      if (!isAuthRateLimitFailure(e) && !isExpectedOfflineFailure(e)) {
        print('⚠️ Error getting subscription timeline: $e');
      }
      return SubscriptionTimeline(queued: []);
    }
  }

  /// Triggers subscription normalization (activates queued subscriptions when current expires).
  Future<void> triggerNormalization() async {
    if (shouldSkipSupabaseCalls()) return;

    try {
      await _supabase.rpc('trigger_subscription_normalization');
    } catch (e) {
      if (!isAuthRateLimitFailure(e) && !isExpectedOfflineFailure(e)) {
        print('⚠️ Error triggering subscription normalization: $e');
      }
    }
  }

  /// Checks and normalizes a specific user's subscription.
  /// Returns normalization result or null if no change needed.
  /// Call this when app opens or periodically for immediate subscription updates.
  Future<SubscriptionNormalizationResult?> checkAndNormalizeUserSubscription(
    String userId,
  ) async {
    if (shouldSkipSupabaseCalls()) return null;

    try {
      final response = await _supabase.rpc(
        'check_and_normalize_user_subscription',
        params: {'p_user_id': userId},
      );

      if (response != null && response is List && response.isNotEmpty) {
        final data = response.first as Map<String, dynamic>;
        final normalized = data['normalized'] as bool? ?? false;

        if (normalized) {
          return SubscriptionNormalizationResult(
            previousTier: data['previous_tier'] as String?,
            newTier: data['new_tier'] as String?,
            normalized: normalized,
          );
        }
      }
      return null;
    } catch (e) {
      if (!isAuthRateLimitFailure(e) && !isExpectedOfflineFailure(e)) {
        print('⚠️ Error checking and normalizing subscription: $e');
      }
      return null;
    }
  }

  /// Gets the cron job status for debugging.
  Future<Map<String, dynamic>?> getCronStatus() async {
    if (shouldSkipSupabaseCalls()) return null;

    try {
      final response = await _supabase.rpc('get_subscription_cron_status');
      if (response != null && response is List && response.isNotEmpty) {
        return response.first as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      if (!isAuthRateLimitFailure(e) && !isExpectedOfflineFailure(e)) {
        print('⚠️ Error getting cron status: $e');
      }
      return null;
    }
  }

  /// Gets all subscription queue entries for a user (including completed/cancelled).
  Future<List<SubscriptionQueueEntry>> fetchFullQueueHistory(
    String userId,
  ) async {
    if (shouldSkipSupabaseCalls()) return _loadCachedQueueHistory(userId);
    try {
      final response = await _supabase
          .from('user_subscription_queue')
          .select()
          .eq('user_id', userId)
          .order('created_at', ascending: false);

      final history = (response as List)
          .map((data) => SubscriptionQueueEntry.fromMap(data))
          .toList();
      await _cacheQueueHistory(userId, history);
      return history;
    } catch (e) {
      // 42501 / dead-token failures fall back to cache silently.
      if (!isAuthRateLimitFailure(e) && !isExpectedOfflineFailure(e)) {
        print('⚠️ Error fetching full queue history: $e');
      }
      return _loadCachedQueueHistory(userId);
    }
  }
}
