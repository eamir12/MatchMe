import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/auth_provider.dart';
import 'package:matchme/services/payment_service.dart';
import 'package:matchme/services/subscription_service.dart';
import 'package:matchme/models/subscription_tier.dart';
import 'package:matchme/models/subscription_queue_entry.dart';
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
/// Cache-first (memory + Hive): returns cached snapshot instantly on UI
/// startup, refreshes in background.
final subscriptionTiersProvider = FutureProvider<List<SubscriptionTier>>((
  ref,
) async {
  final service = ref.read(subscriptionServiceProvider);
  final cached = await service.loadCachedTiersFast();
  if (cached.isNotEmpty) {
    if (!service.isTiersMemoryFresh()) {
      unawaited(() async {
        try {
          final fresh = await service.refreshTiersInBackground();
          if (fresh == null || fresh.isEmpty) return;
          var same = fresh.length == cached.length;
          if (same) {
            for (var i = 0; i < fresh.length; i++) {
              if (fresh[i].id != cached[i].id) {
                same = false;
                break;
              }
            }
          }
          if (!same) {
            try {
              ref.invalidateSelf();
            } catch (_) {}
          }
        } catch (_) {}
      }());
    }
    return cached;
  }
  return service.fetchTiers();
});

/// Watches the subscription_tiers table and invalidates [subscriptionTiersProvider]
/// on any INSERT / UPDATE / DELETE so the paywall reflects admin changes instantly.
final subscriptionTiersRealtimeProvider =
    StreamProvider<List<Map<String, dynamic>>>((ref) {
      final hasSession = ref.watch(
        authStateProvider.select((auth) => auth.asData?.value.session != null),
      );
      if (!hasSession) {
        return const Stream.empty();
      }
      return supabase
          .from('subscription_tiers')
          .stream(primaryKey: const ['id'])
          .map((rows) {
            developer.log(
              'Subscription tiers table changed, invalidating provider',
              name: 'PaymentProvider',
            );
            ref.invalidate(subscriptionTiersProvider);
            return rows;
          })
          .handleError((e) {
            developer.log(
              'subscriptionTiersRealtimeProvider error: $e',
              name: 'PaymentProvider',
            );
          });
    });

/// Watches the subscription_plans table and invalidates [subscriptionTiersProvider]
/// on any INSERT / UPDATE / DELETE so plan-level changes (price, duration) apply instantly.
final subscriptionPlansRealtimeProvider =
    StreamProvider<List<Map<String, dynamic>>>((ref) {
      final hasSession = ref.watch(
        authStateProvider.select((auth) => auth.asData?.value.session != null),
      );
      if (!hasSession) {
        return const Stream.empty();
      }
      return supabase
          .from('subscription_plans')
          .stream(primaryKey: const ['id'])
          .map((rows) {
            developer.log(
              'Subscription plans table changed, invalidating tiers provider',
              name: 'PaymentProvider',
            );
            ref.invalidate(subscriptionTiersProvider);
            return rows;
          })
          .handleError((e) {
            developer.log(
              'subscriptionPlansRealtimeProvider error: $e',
              name: 'PaymentProvider',
            );
          });
    });

final subscriptionNowProvider = StreamProvider.autoDispose<DateTime>((
  ref,
) async* {
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

DateTime? _extractSubscriptionExpiryUtc(
  CustomerInfo info, {
  String? preferredEntitlementId,
}) {
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

/// Represents the effective current subscription as the UI should see it.
///
/// When the user profile already reflects an active (non-free, future)
/// subscription, that is preferred. Otherwise, the most recent active or
/// started queue entry is used. This avoids a window where the profile is
/// stale (e.g. before the normalization cron has run or before the client
/// has refetched the profile) and the UI displays the user as "free" with
/// no time left while the queued subscription is actually live.
class EffectiveSubscription {
  final String tier;
  final DateTime expiresAt;
  final SubscriptionQueueEntry? queueEntry;

  const EffectiveSubscription({
    required this.tier,
    required this.expiresAt,
    this.queueEntry,
  });
}

final effectiveCurrentSubscriptionProvider = Provider<EffectiveSubscription?>((
  ref,
) {
  final userId = Supabase.instance.client.auth.currentUser?.id;

  String? profileTier;
  DateTime? profileExpires;
  if (userId != null) {
    // Use .select(...) to watch only the two fields this provider actually
    // needs. Watching the full userProfileProvider causes this provider (and
    // the entire subscriptionExpiryUtcProvider → subscriptionTimeRemainingProvider
    // chain) to rebuild on unrelated profile changes (photos, name, etc.),
    // which triggers a Riverpod reentrancy assertion (paused subscription
    // count mismatch) when a TickerProvider resumes its subscriptions in the
    // middle of the cascade. See home_providers.dart's
    // TotalUnreadChatCountNotifier for a similar workaround.
    //
    // .select(...) on a StreamProvider unwraps the AsyncValue, so the
    // callback receives the raw value (or null while loading) and the
    // result is a plain non-AsyncValue record.
    final profileSlice = ref.watch(
      userProfileProvider(userId).select((state) {
        final value = state.asData?.value;
        if (value == null) return null;
        return (value.subscriptionTier, value.subscriptionExpiresAt);
      }),
    );
    if (profileSlice != null) {
      profileTier = profileSlice.$1.trim().toLowerCase();
      profileExpires = profileSlice.$2?.toUtc();
    }
  }

  final nowUtc = DateTime.now().toUtc();
  if (profileTier != null &&
      profileTier != 'free' &&
      profileExpires != null &&
      profileExpires.isAfter(nowUtc)) {
    return EffectiveSubscription(tier: profileTier, expiresAt: profileExpires);
  }

  final queueHistory = ref
      .watch(subscriptionQueueHistoryProvider)
      .asData
      ?.value;
  if (queueHistory != null && queueHistory.isNotEmpty) {
    // Pick the earliest active entry that is still valid, or fall back to
    // a started-but-not-yet-normalized pending entry. We don't restrict to
    // status='active' only because there is a small window between
    // starts_at and the next normalization run.
    SubscriptionQueueEntry? best;
    for (final entry in queueHistory) {
      if (entry.expiresAt.toUtc().isBefore(nowUtc)) continue;
      final isActiveOrStarted =
          entry.isActive ||
          (entry.isPending && entry.hasStarted && !entry.hasExpired);
      if (!isActiveOrStarted) continue;
      if (best == null || entry.expiresAt.isBefore(best.expiresAt)) {
        best = entry;
      }
    }
    if (best != null) {
      return EffectiveSubscription(
        tier: best.tier.trim().toLowerCase(),
        expiresAt: best.expiresAt.toUtc(),
        queueEntry: best,
      );
    }
  }

  return null;
});

final subscriptionExpiryUtcProvider = Provider<DateTime?>((ref) {
  // Delegate entirely to the effective sub. It already prefers a live
  // (non-free, future-expiring) profile entry and otherwise falls back to
  // the active/started queue entry, so we don't need a duplicate
  // profile-only check that would short-circuit the fallback whenever the
  // profile has a stale (expired) expires_at.
  return ref.watch(effectiveCurrentSubscriptionProvider)?.expiresAt;
});

final subscriptionTimeRemainingProvider = Provider<Duration?>((ref) {
  final expiresAt = ref.watch(subscriptionExpiryUtcProvider);
  if (expiresAt == null) return null;
  final now =
      ref.watch(subscriptionNowProvider).asData?.value ?? DateTime.now();
  final remaining = expiresAt.difference(now.toUtc());
  if (remaining.isNegative) return Duration.zero;
  return remaining;
});

/// Local-first provider for subscription queue history.
///
/// Reads the cached list from local storage immediately, then syncs with
/// Supabase in the background. Subsequent local cache updates (from new
/// purchases or background refreshes) are streamed through.
final subscriptionQueueHistoryProvider =
    StreamProvider.autoDispose<List<SubscriptionQueueEntry>>((ref) async* {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null || userId.isEmpty) {
        yield const <SubscriptionQueueEntry>[];
        return;
      }

      final localDb = ref.watch(localDbProvider);

      StreamSubscription<List<Map<String, dynamic>>?>? sub;
      final controller = StreamController<List<SubscriptionQueueEntry>>();

      List<SubscriptionQueueEntry> toEntries(List<Map<String, dynamic>>? raw) {
        if (raw == null) return const <SubscriptionQueueEntry>[];
        final list = raw
            .map((m) {
              try {
                return SubscriptionQueueEntry.fromMap(m);
              } catch (_) {
                return null;
              }
            })
            .whereType<SubscriptionQueueEntry>()
            .toList();
        list.sort((a, b) => a.startsAt.compareTo(b.startsAt));
        return list;
      }

      unawaited(() async {
        try {
          final cached = await localDb.getSubscriptionQueueHistory(userId);
          if (!controller.isClosed) {
            controller.add(toEntries(cached));
          }

          if (cached == null || cached.isEmpty) {
            try {
              final service = ref.read(subscriptionServiceProvider);
              final fresh = await service.fetchFullQueueHistory(userId);
              fresh.sort((a, b) => a.startsAt.compareTo(b.startsAt));
              if (!controller.isClosed) controller.add(fresh);
            } catch (e) {
              print(
                '⚠️ [PaymentProvider] subscriptionQueueHistoryProvider sync failed: $e',
              );
            }
          }
        } catch (e) {
          print(
            '⚠️ [PaymentProvider] subscriptionQueueHistoryProvider local read failed: $e',
          );
        }
      }());

      try {
        final watchStream = localDb.watchSubscriptionQueueHistory(userId);
        sub = watchStream.listen(
          (raw) {
            if (!controller.isClosed) controller.add(toEntries(raw));
          },
          onError: (Object e) {
            print(
              '⚠️ [PaymentProvider] subscriptionQueueHistoryProvider watch error: $e',
            );
          },
        );
      } catch (e) {
        print(
          '⚠️ [PaymentProvider] subscriptionQueueHistoryProvider watch subscribe failed: $e',
        );
      }

      ref.onDispose(() {
        unawaited(sub?.cancel());
        if (!controller.isClosed) controller.close();
      });

      yield* controller.stream;
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
        // Both RPCs failed — instead of writing directly to users table,
        // call force_normalize_subscription which delegates to the server's
        // normalization logic and never trusts client-side clock/state.
        try {
          final result = await Supabase.instance.client.rpc(
            'force_normalize_subscription',
            params: {'p_user_id': userId},
          );
          if (result is Map && result['normalized'] == true) {
            await ref
                .read(profileSyncProvider)
                .syncProfile(userId, source: 'payment-normalize-force');
          }
        } catch (_) {
          // Server normalization is also failing — the cron job will handle this.
          // Logging is suppressed as the cron runs every 5 minutes.
        }
      }
    }
  }

  @override
  SubscriptionState build() {
    // Disable periodic normalization on web - it causes unnecessary watchMatches calls
    if (!kIsWeb) {
      _normalizeTimer ??= Timer.periodic(const Duration(minutes: 1), (_) {
        unawaited(_normalizeSubscription());
      });
    }
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
      print('Error initializing subscription provider: $e');
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
      print(
        '💰 [PaymentProvider] Web mode: No CustomerInfo, relying on Supabase for subscription state',
      );
      state = state.copyWith(isLoading: false);
    } else {
      state = state.copyWith(isLoading: false);
    }
  }

  void _updateFromCustomerInfo(CustomerInfo info) {
    print(
      '💰 [PaymentProvider] _updateFromCustomerInfo called. Entitlements: ${info.entitlements.all.keys}',
    );

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
        print(
          '💰 [PaymentProvider] No active entitlements, checking active subscriptions: $activeSubs',
        );
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
        DateTime.now().difference(_lastManualUpdate!) <
            const Duration(seconds: 45)) {
      print(
        '💰 [PaymentProvider] Ignoring "free" update from RevenueCat due to recent manual update (grace period active).',
      );
      return;
    }

    print(
      '💰 [PaymentProvider] Determined new tier: $newTier (was: ${state.activeTier})',
    );

    state = state.copyWith(
      isPremium: newTier != 'free',
      activeTier: newTier,
      customerInfo: info,
      isLoading: false,
    );

    final expiryUtc = _extractSubscriptionExpiryUtc(
      info,
      preferredEntitlementId: newTier,
    );
    _syncRevenueCatSubscriptionToDatabase(
      tier: newTier,
      expiresAtUtc: expiryUtc,
    );
  }

  /// Manually set the tier (used for testing or non-RevenueCat flows)
  Future<void> setTierManually(
    String tierId, {
    String? planDuration,
    Duration extraDuration = Duration.zero,
    Map<String, dynamic> purchaseMetadata = const {},
  }) async {
    print('💰 [PaymentProvider] Manually setting tier to: $tierId');

    _lastManualUpdate = DateTime.now();
    final safeExtraDuration = extraDuration.isNegative
        ? Duration.zero
        : extraDuration;
    final totalDuration =
        _expiresInForPlanDuration(planDuration) + safeExtraDuration;

    if (state.customerInfo != null) {
      state = state.copyWith(
        isPremium: tierId != 'free',
        activeTier: tierId,
        isLoading: false,
      );
      final revenueCatExpiryUtc = _extractSubscriptionExpiryUtc(
        state.customerInfo!,
        preferredEntitlementId: tierId,
      );
      final expiryUtc = revenueCatExpiryUtc == null
          ? DateTime.now().toUtc().add(totalDuration)
          : revenueCatExpiryUtc.add(safeExtraDuration);
      await _syncRevenueCatSubscriptionToDatabase(
        tier: tierId,
        expiresAtUtc: expiryUtc,
      );
      return;
    }

    final userId = Supabase.instance.client.auth.currentUser?.id;
    final durationSeconds = totalDuration.inSeconds;

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
      final currentProfile = ref
          .read(userProfileProvider(userId))
          .asData
          ?.value;
      if (currentProfile != null) {
        final updatedProfile = currentProfile.copyWith(
          subscriptionTier: tier,
          subscriptionExpiresAt: expiresAtUtc?.toUtc(),
        );
        // We need to save this back to Local DB.
        // UserProfile has toMap() or similar?
        // UserProfile.toMap() exists.
        await localDb.saveLocalProfile(userId, updatedProfile.toMap());
        print('💰 [PaymentProvider] Optimistic local DB update applied: $tier');
      }
    } catch (e) {
      print('⚠️ [PaymentProvider] Failed to apply optimistic local update: $e');
    }

    print('💰 [PaymentProvider] Syncing subscription $tier to Supabase');
    try {
      try {
        await Supabase.instance.client.rpc(
          'apply_revenuecat_subscription',
          params: {
            'p_tier': tier,
            'p_expires_at': expiresAtUtc?.toUtc().toIso8601String(),
          },
        );
        print('💰 [PaymentProvider] Supabase update complete via RPC.');
      } catch (rpcError) {
        print(
          '⚠️ [PaymentProvider] RPC update failed (likely function missing), falling back to direct update: $rpcError',
        );

        try {
          await Supabase.instance.client.auth.updateUser(
            UserAttributes(data: {'subscription_tier': tier}),
          );
          print('💰 [PaymentProvider] User metadata update complete.');
        } catch (metaError) {
          print('⚠️ [PaymentProvider] User metadata update failed: $metaError');
        }

        // Fallback 2: Direct table update
        await _updateSubscriptionDirect(
          userId,
          tier: tier,
          expiresAtUtc: expiresAtUtc,
        );
        print(
          '💰 [PaymentProvider] Supabase update complete via direct update.',
        );
      }

      print('💰 [PaymentProvider] Triggering profile sync...');
      await ref
          .read(profileSyncProvider)
          .syncProfile(userId, source: 'payment-revenuecat-sync');
      print('💰 [PaymentProvider] Profile sync requested.');
    } catch (e) {
      print('⚠️ [PaymentProvider] Error syncing subscription tier to DB: $e');
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
      await _updateSubscriptionDirect(userId, tier: 'free', expiresAtUtc: null);
    }

    await ref
        .read(profileSyncProvider)
        .syncProfile(userId, source: 'payment-clear-subscription');
    await _refreshSubscriptionQueueCache(userId);
    state = state.copyWith(
      isPremium: false,
      activeTier: 'free',
      isLoading: false,
    );
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
        'subscription_tier': (userRow['subscription_tier'] ?? 'free')
            .toString(),
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
        } else if (rpcResult is List &&
            rpcResult.isNotEmpty &&
            rpcResult.first is Map) {
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

      if (currentTier != 'free' &&
          currentExpiryUtc != null &&
          nowUtc.isBefore(currentExpiryUtc)) {
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
    final expiresAtUtc = DateTime.tryParse(
      (result['subscription_expires_at'] ?? '').toString(),
    )?.toUtc();

    await _optimisticallyUpdateLocalSubscription(
      userId,
      tier: tier,
      expiresAtUtc: expiresAtUtc,
    );

    await ref
        .read(profileSyncProvider)
        .syncProfile(userId, source: 'payment-manual-purchase');
    await _refreshSubscriptionQueueCache(userId);
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
        await Supabase.instance.client
            .from('users')
            .update(payload)
            .eq('id', userId);
        return;
      } catch (e) {
        if (e is PostgrestException) {
          final msg = e.message;
          final missingColumnRegex = RegExp(
            r'column\s+"?(\w+)"?\s+does not exist',
            caseSensitive: false,
          );
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
      final currentProfile = ref
          .read(userProfileProvider(userId))
          .asData
          ?.value;
      if (currentProfile == null) return;
      final updated = currentProfile.copyWith(
        subscriptionTier: tier,
        subscriptionExpiresAt: expiresAtUtc?.toUtc(),
      );
      await localDb.saveLocalProfile(userId, updated.toMap());
    } catch (_) {}
  }

  /// Refresh the local subscription queue history cache from Supabase so the
  /// Billing screen (and any other consumer) sees new entries immediately.
  Future<void> _refreshSubscriptionQueueCache(String userId) async {
    if (userId.isEmpty) return;
    try {
      final service = ref.read(subscriptionServiceProvider);
      await service.fetchFullQueueHistory(userId);
    } catch (e) {
      print(
        '⚠️ [PaymentProvider] Failed to refresh subscription queue cache: $e',
      );
    }
  }

  Future<void> showPaywall() async {
    final success = await _paymentService.showPaywall();
    if (success) {
      await refreshStatus();
    }
  }

  /// Public hook to refresh the cached subscription queue history. Callers
  /// (e.g. pull-to-refresh on the home screen) can use this to pick up
  /// server-side normalization changes that may have promoted a queued
  /// entry to active without going through a fresh purchase.
  Future<void> refreshQueueHistory() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;
    await _normalizeSubscription();
    await _refreshSubscriptionQueueCache(userId);
  }
}

/// Provider that exposes the subscription state
final subscriptionProvider =
    NotifierProvider<SubscriptionNotifier, SubscriptionState>(
      SubscriptionNotifier.new,
    );
