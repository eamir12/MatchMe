import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/models/subscription_tier.dart';
import 'package:matchme/models/subscription_queue_entry.dart';

class SubscriptionService {
  final SupabaseClient _supabase;

  SubscriptionService(this._supabase);

  /// Fetches active subscription tiers from Supabase.
  /// Returns a list of [SubscriptionTier] sorted by [sortOrder].
  /// If an error occurs, returns the fallback list.
  Future<List<SubscriptionTier>> fetchTiers() async {
    try {
      final response = await _supabase
          .from('subscription_tiers')
          .select('*, subscription_plans(*)')
          .eq('is_active', true)
          .order('sort_order', ascending: true);

      return (response as List)
          .map((data) => SubscriptionTier.fromMap(data))
          .toList();
    } catch (e) {
      debugPrint('⚠️ Error fetching subscription tiers: $e');
      // Return fallbacks on error to ensure UI always has something to show
      return SubscriptionTier.fallbacks;
    }
  }

  // ============================================================================
  // SUBSCRIPTION QUEUE METHODS
  // ============================================================================

  /// Fetches the subscription queue for a user.
  /// Returns pending and active queued subscriptions sorted by start time.
  Future<List<SubscriptionQueueEntry>> fetchSubscriptionQueue(String userId) async {
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
      debugPrint('⚠️ Error fetching subscription queue: $e');
      return [];
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
      debugPrint('⚠️ Error adding subscription to queue: $e');
      return null;
    }
  }

  /// Gets the next queued subscription for a user.
  Future<SubscriptionQueueEntry?> getNextQueuedSubscription(String userId) async {
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
      debugPrint('⚠️ Error getting next queued subscription: $e');
      return null;
    }
  }

  /// Cancels a queued subscription.
  Future<bool> cancelQueuedSubscription(String queueId, {String? reason}) async {
    try {
      final response = await _supabase.rpc(
        'cancel_queued_subscription',
        params: {
          'p_queue_id': queueId,
          'p_reason': reason,
        },
      );
      return response == true;
    } catch (e) {
      debugPrint('⚠️ Error cancelling queued subscription: $e');
      return false;
    }
  }

  /// Gets the full subscription timeline for a user.
  /// Combines current subscription from users table with queued subscriptions.
  Future<SubscriptionTimeline> getSubscriptionTimeline(String userId) async {
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

      return SubscriptionTimeline(
        current: current,
        queued: queued,
      );
    } catch (e) {
      debugPrint('⚠️ Error getting subscription timeline: $e');
      return SubscriptionTimeline(queued: []);
    }
  }

  /// Triggers subscription normalization (activates queued subscriptions when current expires).
  Future<void> triggerNormalization() async {
    try {
      await _supabase.rpc('trigger_subscription_normalization');
    } catch (e) {
      debugPrint('⚠️ Error triggering subscription normalization: $e');
    }
  }

  /// Checks and normalizes a specific user's subscription.
  /// Returns normalization result or null if no change needed.
  /// Call this when app opens or periodically for immediate subscription updates.
  Future<SubscriptionNormalizationResult?> checkAndNormalizeUserSubscription(String userId) async {
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
      debugPrint('⚠️ Error checking and normalizing subscription: $e');
      return null;
    }
  }

  /// Gets the cron job status for debugging.
  Future<Map<String, dynamic>?> getCronStatus() async {
    try {
      final response = await _supabase.rpc('get_subscription_cron_status');
      if (response != null && response is List && response.isNotEmpty) {
        return response.first as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      debugPrint('⚠️ Error getting cron status: $e');
      return null;
    }
  }

  /// Gets all subscription queue entries for a user (including completed/cancelled).
  Future<List<SubscriptionQueueEntry>> fetchFullQueueHistory(String userId) async {
    try {
      final response = await _supabase
          .from('user_subscription_queue')
          .select()
          .eq('user_id', userId)
          .order('created_at', ascending: false);

      return (response as List)
          .map((data) => SubscriptionQueueEntry.fromMap(data))
          .toList();
    } catch (e) {
      debugPrint('⚠️ Error fetching full queue history: $e');
      return [];
    }
  }
}
