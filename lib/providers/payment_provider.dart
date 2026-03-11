import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/services/payment_service.dart';
import 'package:matchme/services/subscription_service.dart';
import 'package:matchme/models/subscription_tier.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/local_db_service.dart';

/// Provider for the raw PaymentService instance
final paymentServiceProvider = Provider<PaymentService>((ref) {
  return PaymentService();
});

/// Provider for the SubscriptionService
final subscriptionServiceProvider = Provider<SubscriptionService>((ref) {
  return SubscriptionService(Supabase.instance.client);
});

/// Provider to fetch subscription tiers (metadata from Supabase)
final subscriptionTiersProvider = FutureProvider<List<SubscriptionTier>>((ref) async {
  final service = ref.read(subscriptionServiceProvider);
  return service.fetchTiers();
});

final subscriptionNowProvider = StreamProvider.autoDispose<DateTime>((ref) async* {
  yield DateTime.now();
  yield* Stream.periodic(const Duration(minutes: 1), (_) => DateTime.now());
});

DateTime? _asDateTime(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  if (value is int) {
    final ms = value > 1000000000000 ? value : value * 1000;
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
  }
  if (value is double) {
    final intValue = value.round();
    final ms = intValue > 1000000000000 ? intValue : intValue * 1000;
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
  }
  return null;
}

DateTime? _extractSubscriptionExpiryUtc(CustomerInfo info, {String? preferredEntitlementId}) {
  final entitlementId = (preferredEntitlementId ?? '').trim();
  if (entitlementId.isNotEmpty && entitlementId != 'free') {
    final ent = info.entitlements.all[entitlementId];
    if (ent?.isActive ?? false) {
      final exp = _asDateTime(ent?.expirationDate);
      if (exp != null) return exp.toUtc();
    }
  }

  DateTime? latest;
  for (final ent in info.entitlements.all.values) {
    if (!ent.isActive) continue;
    final exp = _asDateTime(ent.expirationDate);
    if (exp == null) continue;
    if (latest == null || exp.isAfter(latest)) latest = exp;
  }
  if (latest != null) return latest.toUtc();

  final Map<String, dynamic> expDates = info.allExpirationDates;
  if (expDates.isNotEmpty) {
    for (final productId in info.activeSubscriptions) {
      final exp = _asDateTime(expDates[productId]);
      if (exp == null) continue;
      if (latest == null || exp.isAfter(latest)) latest = exp;
    }
  }
  if (latest != null) return latest.toUtc();

  final exp = _asDateTime(info.latestExpirationDate);
  return exp?.toUtc();
}

final subscriptionExpiryUtcProvider = Provider<DateTime?>((ref) {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId != null) {
    final profile = ref.watch(userProfileProvider(userId)).asData?.value;
    final exp = profile?.subscriptionExpiresAt;
    if (exp != null) return exp.toUtc();
  }
  return null;
});

final subscriptionTimeRemainingProvider = Provider<Duration?>((ref) {
  final expiresAt = ref.watch(subscriptionExpiryUtcProvider);
  if (expiresAt == null) return null;
  final now = ref.watch(subscriptionNowProvider).asData?.value ?? DateTime.now();
  final remaining = expiresAt.difference(now.toUtc());
  if (remaining.isNegative) return Duration.zero;
  return remaining;
});

/// State class for subscription status
class SubscriptionState {
  final bool isPremium;
  final String? activeTier;
  final CustomerInfo? customerInfo;
  final bool isLoading;

  const SubscriptionState({
    this.isPremium = false,
    this.activeTier,
    this.customerInfo,
    this.isLoading = false,
  });

  SubscriptionState copyWith({
    bool? isPremium,
    String? activeTier,
    CustomerInfo? customerInfo,
    bool? isLoading,
  }) {
    return SubscriptionState(
      isPremium: isPremium ?? this.isPremium,
      activeTier: activeTier ?? this.activeTier,
      customerInfo: customerInfo ?? this.customerInfo,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

/// Notifier to manage subscription state
class SubscriptionNotifier extends Notifier<SubscriptionState> {
  PaymentService get _paymentService => ref.read(paymentServiceProvider);
  DateTime? _lastManualUpdate;
  Timer? _normalizeTimer;

  Duration _expiresInForPlanDuration(String? planDuration) {
    switch ((planDuration ?? '').trim().toLowerCase()) {
      case 'day':
      case 'daily':
        return const Duration(days: 1);
      case 'week':
      case 'weekly':
        return const Duration(days: 7);
      case 'month':
      case 'monthly':
        return const Duration(days: 30);
      case 'year':
      case 'annual':
      case 'yearly':
        return const Duration(days: 365);
      default:
        return const Duration(days: 30);
    }
  }

  Future<void> _normalizeSubscription() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    try {
      await Supabase.instance.client.rpc(
        'check_and_normalize_user_subscription',
        params: {'p_user_id': userId},
      );
    } catch (_) {
      try {
        await Supabase.instance.client.rpc(
          'normalize_user_subscription',
          params: {'p_user_id': userId},
        );
      } catch (_) {
        final profile = ref.read(userProfileProvider(userId)).asData?.value;
        final currentTier = (profile?.subscriptionTier ?? 'free').toString();
        final currentExpiryUtc = profile?.subscriptionExpiresAt?.toUtc();
        final nowUtc = DateTime.now().toUtc();

        if (currentTier != 'free' &&
            currentExpiryUtc != null &&
            !nowUtc.isBefore(currentExpiryUtc)) {
          await _updateSubscriptionDirect(
            userId,
            tier: 'free',
            expiresAtUtc: null,
          );
        }
      }
    }

    await ref.read(profileSyncProvider).syncProfile(userId);
  }

  @override
  SubscriptionState build() {
    _normalizeTimer ??= Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(_normalizeSubscription());
    });
    ref.onDispose(() {
      _normalizeTimer?.cancel();
      _normalizeTimer = null;
    });
    // Trigger initialization after the build phase
    Future.microtask(() => _init());
    return const SubscriptionState();
  }

  Future<void> _init() async {
    state = state.copyWith(isLoading: true);
    try {
      await _paymentService.init();

      // Identify user if logged in
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId != null) {
        await _paymentService.login(userId);
      }

      await refreshStatus();
      await _normalizeSubscription();
      
      // Listen for updates (only for mobile - web doesn't support this)
      if (!_paymentService.isWebMode) {
        _paymentService.addCustomerInfoUpdateListener((info) {
          _updateFromCustomerInfo(info);
        });
      }
    } catch (e) {
      debugPrint('Error initializing subscription provider: $e');
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> refreshStatus() async {
    final info = await _paymentService.getCustomerInfo();
    if (info != null) {
      _updateFromCustomerInfo(info);
    } else if (_paymentService.isWebMode) {
      // Web mode: RevenueCat doesn't provide CustomerInfo, so we rely on Supabase
      // The subscription state will be updated from the profile provider
      debugPrint('💰 [PaymentProvider] Web mode: No CustomerInfo, relying on Supabase for subscription state');
      state = state.copyWith(isLoading: false);
    } else {
      state = state.copyWith(isLoading: false);
    }
  }

  void _updateFromCustomerInfo(CustomerInfo info) {
    debugPrint('💰 [PaymentProvider] _updateFromCustomerInfo called. Entitlements: ${info.entitlements.all.keys}');
    
    // Determine tier based on active entitlements (highest to lowest)
    String newTier = 'free';
    
    if (info.entitlements.all['platinum']?.isActive ?? false) {
      newTier = 'platinum';
    } else if (info.entitlements.all['gold']?.isActive ?? false) {
      newTier = 'gold';
    } else if (info.entitlements.all['plus']?.isActive ?? false) {
      newTier = 'plus';
    } else if (info.entitlements.all['pro']?.isActive ?? false) {
      // Legacy or generic fallback
      newTier = 'plus';
    } else {
       // Check active subscriptions (Product IDs) if no Entitlements are found
       // This handles misconfigured RevenueCat setups where Entitlements aren't linked.
       final activeSubs = info.activeSubscriptions;
       if (activeSubs.isNotEmpty) {
         debugPrint('💰 [PaymentProvider] No active entitlements, checking active subscriptions: $activeSubs');
         // Simple heuristic: check if product ID contains tier name
         // You should adjust these strings to match your actual RevenueCat Product IDs
         if (activeSubs.any((s) => s.contains('platinum'))) {
           newTier = 'platinum';
         } else if (activeSubs.any((s) => s.contains('gold'))) {
           newTier = 'gold';
         } else if (activeSubs.any((s) => s.contains('plus'))) {
           newTier = 'plus';
         }
       }
    }

    // Protection against race conditions:
    // If we recently manually set a tier (e.g. optimistic update after purchase),
    // and RevenueCat returns 'free' (likely due to webhook latency or missing entitlements),
    // ignore this update for a short grace period.
    if (_lastManualUpdate != null && 
        newTier == 'free' && 
        DateTime.now().difference(_lastManualUpdate!) < const Duration(seconds: 45)) {
      debugPrint('💰 [PaymentProvider] Ignoring "free" update from RevenueCat due to recent manual update (grace period active).');
      return;
    }
    
    debugPrint('💰 [PaymentProvider] Determined new tier: $newTier (was: ${state.activeTier})');

    state = state.copyWith(
      isPremium: newTier != 'free',
      activeTier: newTier,
      customerInfo: info,
      isLoading: false,
    );

    final expiryUtc = _extractSubscriptionExpiryUtc(info, preferredEntitlementId: newTier);
    _syncRevenueCatSubscriptionToDatabase(tier: newTier, expiresAtUtc: expiryUtc);
  }

  /// Manually set the tier (used for testing or non-RevenueCat flows)
  Future<void> setTierManually(
    String tierId, {
    String? planDuration,
    Map<String, dynamic> purchaseMetadata = const {},
  }) async {
    debugPrint('💰 [PaymentProvider] Manually setting tier to: $tierId');
    
    _lastManualUpdate = DateTime.now();

    if (state.customerInfo != null) {
      state = state.copyWith(
        isPremium: tierId != 'free',
        activeTier: tierId,
        isLoading: false,
      );
      final expiryUtc = _extractSubscriptionExpiryUtc(state.customerInfo!, preferredEntitlementId: tierId);
      await _syncRevenueCatSubscriptionToDatabase(
        tier: tierId,
        expiresAtUtc: expiryUtc,
      );
      return;
    }

    final userId = Supabase.instance.client.auth.currentUser?.id;
    final duration = _expiresInForPlanDuration(planDuration);
    final durationSeconds = duration.inSeconds;

    if (userId == null || userId.isEmpty) {
      state = state.copyWith(
        isPremium: tierId != 'free',
        activeTier: tierId,
        isLoading: false,
      );
      return;
    }

    if (tierId == 'free') {
      await _clearSubscriptionToDatabase(userId);
      return;
    }

    final applied = await _applyManualSubscriptionPurchaseToDatabase(
      userId: userId,
      tierId: tierId,
      durationSeconds: durationSeconds,
      purchaseMetadata: purchaseMetadata,
    );

    state = state.copyWith(
      isPremium: (applied['subscription_tier'] ?? tierId).toString() != 'free',
      activeTier: (applied['subscription_tier'] ?? tierId).toString(),
      isLoading: false,
    );
  }

  Future<void> _syncRevenueCatSubscriptionToDatabase({
    required String tier,
    required DateTime? expiresAtUtc,
  }) async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    // 1. IMMEDIATE LOCAL DB UPDATE (Optimistic UI Update)
    // This ensures the dashboard updates instantly, even if the network is slow or syncProfile fails.
    try {
      final localDb = await LocalDbService.instance;
      // We need to read the current profile data manually from the box
      // Since we can't easily access the box directly without internal knowledge,
      // we'll use the public methods.
      // Wait, LocalDbService doesn't expose a simple "getProfile" that returns Map.
      // It has watchLocalProfile.
      // But we can peek at the box implementation in LocalDbService:
      // "_getProfileBox" is private.
      // However, we can use the stream to get the first element? No, that's async.
      
      // Let's rely on the fact that we can call saveLocalProfile if we had the full profile.
      // We don't have the full profile here.
      // BUT, ProfileSyncService DOES.
      
      // Better approach:
      // We can create a partial update helper in LocalDbService or just accept that we might overwrite if we are not careful.
      // Actually, let's just use a dedicated provider/service method if available.
      
      // Since we can't easily do it without risking data loss (overwriting with empty fields),
      // let's try to update via the ProfileProvider's notifier if it exists?
      // userProfileProvider is a StreamProvider (implied from MainNavigationScreen usage).
      
      // Alternative: Just trust the ProfileSync to happen fast enough?
      // The user says it DOESN'T happen.
      
      // So we MUST force a local update.
      // Let's use reflection/hack or just modify LocalDbService to allow patching tier.
      
      // I'll assume we can't modify LocalDbService easily right now (it's big).
      // But wait, I can just use Supabase.instance.client.auth.currentUser?.userMetadata?
      // No, that's auth metadata.
      
      // Let's try to fetch the current profile from Supabase first? No, that defeats the purpose.
      
      // Wait, I can just use `ref.read(userProfileProvider(userId)).value`.
      // It returns `UserProfile?`.
      final currentProfile = ref.read(userProfileProvider(userId)).asData?.value;
      if (currentProfile != null) {
        final updatedProfile = currentProfile.copyWith(
          subscriptionTier: tier,
          subscriptionExpiresAt: expiresAtUtc?.toUtc(),
        );
        // We need to save this back to Local DB.
        // UserProfile has toMap() or similar?
        // UserProfile.toMap() exists.
        await localDb.saveLocalProfile(userId, updatedProfile.toMap());
        debugPrint('💰 [PaymentProvider] Optimistic local DB update applied: $tier');
      }
    } catch (e) {
      debugPrint('⚠️ [PaymentProvider] Failed to apply optimistic local update: $e');
    }
    
    debugPrint('💰 [PaymentProvider] Syncing subscription $tier to Supabase for user $userId');
    try {
      try {
        await Supabase.instance.client.rpc(
          'apply_revenuecat_subscription',
          params: {
            'p_tier': tier,
            'p_expires_at': expiresAtUtc?.toUtc().toIso8601String(),
          },
        );
        debugPrint('💰 [PaymentProvider] Supabase update complete via RPC.');
      } catch (rpcError) {
        debugPrint('⚠️ [PaymentProvider] RPC update failed (likely function missing), falling back to direct update: $rpcError');

        try {
          await Supabase.instance.client.auth.updateUser(
            UserAttributes(data: {'subscription_tier': tier}),
          );
          debugPrint('💰 [PaymentProvider] User metadata update complete.');
        } catch (metaError) {
          debugPrint('⚠️ [PaymentProvider] User metadata update failed: $metaError');
        }

        // Fallback 2: Direct table update
        await _updateSubscriptionDirect(
          userId,
          tier: tier,
          expiresAtUtc: expiresAtUtc,
        );
        debugPrint('💰 [PaymentProvider] Supabase update complete via direct update.');
      }

      debugPrint('💰 [PaymentProvider] Triggering profile sync...');
      await ref.read(profileSyncProvider).syncProfile(userId);
      debugPrint('💰 [PaymentProvider] Profile sync requested.');
    } catch (e) {
      debugPrint('⚠️ [PaymentProvider] Error syncing subscription tier to DB: $e');
    }
  }

  Future<void> _clearSubscriptionToDatabase(String userId) async {
    await _optimisticallyUpdateLocalSubscription(
      userId,
      tier: 'free',
      expiresAtUtc: null,
    );

    try {
      await Supabase.instance.client.rpc('clear_user_subscription');
    } catch (_) {
      await _updateSubscriptionDirect(
        userId,
        tier: 'free',
        expiresAtUtc: null,
      );
    }

    await ref.read(profileSyncProvider).syncProfile(userId);
    state = state.copyWith(isPremium: false, activeTier: 'free', isLoading: false);
  }

  Future<Map<String, dynamic>> _applyManualSubscriptionPurchaseToDatabase({
    required String userId,
    required String tierId,
    required int durationSeconds,
    Map<String, dynamic> purchaseMetadata = const {},
  }) async {
    Map<String, dynamic>? result;
    try {
      final duration = Duration(seconds: durationSeconds);
      final subscriptionService = ref.read(subscriptionServiceProvider);
      await subscriptionService.addToQueue(
        userId: userId,
        tier: tierId,
        duration: duration,
        paymentProvider: 'manual',
        metadata: purchaseMetadata,
      );
      await subscriptionService.checkAndNormalizeUserSubscription(userId);

      final userRow = await Supabase.instance.client
          .from('users')
          .select('subscription_tier, subscription_expires_at')
          .eq('id', userId)
          .single();

      result = {
        'subscription_tier': (userRow['subscription_tier'] ?? 'free').toString(),
        'subscription_expires_at': userRow['subscription_expires_at'],
      };
    } catch (_) {}

    if (result == null) {
      try {
        final dynamic rpcResult = await Supabase.instance.client.rpc(
          'apply_manual_subscription_purchase',
          params: {
            'p_tier': tierId,
            'p_duration_seconds': durationSeconds,
            'p_user_id': userId,
          },
        );
        if (rpcResult is Map) {
          result = Map<String, dynamic>.from(rpcResult);
        } else if (rpcResult is List && rpcResult.isNotEmpty && rpcResult.first is Map) {
          result = Map<String, dynamic>.from(rpcResult.first as Map);
        }
      } catch (_) {}
    }

    if (result == null) {
      final profile = ref.read(userProfileProvider(userId)).asData?.value;
      final nowUtc = DateTime.now().toUtc();
      final duration = Duration(seconds: durationSeconds);

      final currentTier = (profile?.subscriptionTier ?? 'free').toString();
      final currentExpiryUtc = profile?.subscriptionExpiresAt?.toUtc();

      String newTier = tierId;
      DateTime newExpiryUtc = nowUtc.add(duration);

      if (currentTier != 'free' && currentExpiryUtc != null && nowUtc.isBefore(currentExpiryUtc)) {
        if (currentTier == tierId) {
          newTier = currentTier;
          newExpiryUtc = currentExpiryUtc.add(duration);
        } else {
          newTier = tierId;
          newExpiryUtc = currentExpiryUtc.add(duration);
        }
      }

      await _updateSubscriptionDirect(
        userId,
        tier: newTier,
        expiresAtUtc: newExpiryUtc,
      );

      result = {
        'subscription_tier': newTier,
        'subscription_expires_at': newExpiryUtc.toIso8601String(),
      };
    }

    final tier = (result['subscription_tier'] ?? tierId).toString();
    final expiresAtUtc = DateTime.tryParse((result['subscription_expires_at'] ?? '').toString())?.toUtc();

    await _optimisticallyUpdateLocalSubscription(
      userId,
      tier: tier,
      expiresAtUtc: expiresAtUtc,
    );

    await ref.read(profileSyncProvider).syncProfile(userId);
    return result;
  }

  Future<void> _updateSubscriptionDirect(
    String userId, {
    required String tier,
    required DateTime? expiresAtUtc,
  }) async {
    if (userId.isEmpty) return;
    final basePayload = <String, dynamic>{
      'subscription_tier': tier,
      'subscription_expires_at': expiresAtUtc?.toUtc().toIso8601String(),
    };

    var payload = Map<String, dynamic>.from(basePayload);
    final triedSignatures = <String>{};

    while (payload.isNotEmpty) {
      final signature = payload.keys.join(',');
      if (triedSignatures.contains(signature)) break;
      triedSignatures.add(signature);

      try {
        await Supabase.instance.client.from('users').update(payload).eq('id', userId);
        return;
      } catch (e) {
        if (e is PostgrestException) {
          final msg = e.message;
          final missingColumnRegex = RegExp(r'column\s+"?(\w+)"?\s+does not exist', caseSensitive: false);
          final match = missingColumnRegex.firstMatch(msg);
          final missing = match?.group(1);
          if (missing != null && payload.containsKey(missing)) {
            payload.remove(missing);
            continue;
          }
        }
        rethrow;
      }
    }
  }

  Future<void> _optimisticallyUpdateLocalSubscription(
    String userId, {
    required String tier,
    required DateTime? expiresAtUtc,
  }) async {
    if (userId.isEmpty) return;
    try {
      final localDb = await LocalDbService.instance;
      final currentProfile = ref.read(userProfileProvider(userId)).asData?.value;
      if (currentProfile == null) return;
      final updated = currentProfile.copyWith(
        subscriptionTier: tier,
        subscriptionExpiresAt: expiresAtUtc?.toUtc(),
      );
      await localDb.saveLocalProfile(userId, updated.toMap());
    } catch (_) {}
  }

  Future<void> showPaywall() async {
    final success = await _paymentService.showPaywall();
    if (success) {
      await refreshStatus();
    }
  }
}

/// Provider that exposes the subscription state
final subscriptionProvider = NotifierProvider<SubscriptionNotifier, SubscriptionState>(SubscriptionNotifier.new);
