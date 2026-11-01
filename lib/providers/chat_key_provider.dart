import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/user_chat_key_model.dart';
import 'package:matchme/services/chat_key_service.dart';
import 'package:matchme/services/encrypted_cache_service.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ChatKeyState {
  final bool isLoaded;
  final bool isLocked;
  final UserChatKeyModel? activeKey;
  final Uint8List? privateKeyBytes;
  final bool hasRecoveryKey;
  final bool hasPasswordWrapper;

  const ChatKeyState({
    this.isLoaded = false,
    this.isLocked = true,
    this.activeKey,
    this.privateKeyBytes,
    this.hasRecoveryKey = false,
    this.hasPasswordWrapper = false,
  });

  ChatKeyState copyWith({
    bool? isLoaded,
    bool? isLocked,
    UserChatKeyModel? activeKey,
    Uint8List? privateKeyBytes,
    bool? hasRecoveryKey,
    bool? hasPasswordWrapper,
  }) {
    return ChatKeyState(
      isLoaded: isLoaded ?? this.isLoaded,
      isLocked: isLocked ?? this.isLocked,
      activeKey: activeKey ?? this.activeKey,
      privateKeyBytes: privateKeyBytes ?? this.privateKeyBytes,
      hasRecoveryKey: hasRecoveryKey ?? this.hasRecoveryKey,
      hasPasswordWrapper: hasPasswordWrapper ?? this.hasPasswordWrapper,
    );
  }
}

class ChatKeyNotifier extends Notifier<ChatKeyState> {
  final ChatKeyService _chatKeyService = ChatKeyService.instance;
  late Future<void> _initFuture;
  String? _initializedForUserId;
  bool _resumeListenerRegistered = false;
  VoidCallback? _resumeListenerDispose;
  bool _resumeRefreshInFlight = false;
  DateTime? _lastResumeRefreshAt;

  /// The user id the provider's current state was initialized for. Null
  /// until the first init starts. Consumers use this to detect whether
  /// the loaded private key belongs to the currently authenticated user
  /// (e.g. after a user switch without an app restart).
  String? get initializedUserId => _initializedForUserId;

  @override
  ChatKeyState build() {
    // The provider is invalidated on login/logout (bootstrap, navigation,
    // profile wizard), which discards this notifier and builds a new one.
    // Without disposing the old listener here, every invalidation leaked a
    // resume callback that fired a full offline key refresh on reconnect.
    ref.onDispose(() {
      _resumeListenerDispose?.call();
      _resumeListenerDispose = null;
      _resumeListenerRegistered = false;
    });
    _initFuture = _init();
    return const ChatKeyState();
  }

  Future<void> get initializationComplete => _initFuture;

  Future<void> _init() async {
    // Self-heal on reconnect: if this device booted while offline, the key
    // may have been left locked or unverified. The moment Supabase is
    // reachable again, re-run init so the key resolves to its healthy state
    // without any user action.
    if (!_resumeListenerRegistered) {
      _resumeListenerRegistered = true;
      _resumeListenerDispose = onSupabaseResume(() {
        // The restore coordinator fires short bursts of events (the
        // connectivity monitor, then FCM's registerSession a few seconds
        // later). One key refresh is enough — the cooldown dedupes the burst.
        if (_resumeRefreshInFlight) return;
        final now = DateTime.now();
        if (_lastResumeRefreshAt != null &&
            now.difference(_lastResumeRefreshAt!) <
                const Duration(seconds: 15)) {
          return;
        }
        _lastResumeRefreshAt = now;
        debugPrint(
          '🔑 [ChatKeyProvider] Connectivity resumed — re-running key init',
        );
        _resumeRefreshInFlight = true;
        unawaited(refresh().whenComplete(() => _resumeRefreshInFlight = false));
      });
    }

    if (shouldSkipSupabaseCalls()) {
      // Offline boot: try to use the local private key as-is. It is the
      // source of truth on this device and works offline (messages already
      // in the local DB decrypt without any server round-trip). Server-side
      // verification (stale-key detection, backup backfill) is deferred to
      // the connectivity-resume refresh above.
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId != null) {
        try {
          await EncryptedCacheService.instance.initialize(userId);
        } catch (_) {}
        final hasLocal = await _chatKeyService.hasPrivateKeyLocally(userId);
        final hasCrk = await _chatKeyService.loadCrkBytes(userId) != null;
        // Mark init done for this user even offline: otherwise consumers
        // (e.g. chatMessagesProvider) see initializedUserId != currentUser
        // forever and fire refresh() on every rebuild -> rebuild loop that
        // flashes the chat between data and loading while offline.
        _initializedForUserId = userId;
        if (hasLocal) {
          final privateKey = await _chatKeyService.loadPrivateKeyBytes(userId);
          if (privateKey != null && privateKey.isNotEmpty) {
            state = ChatKeyState(
              isLoaded: true,
              isLocked: false,
              privateKeyBytes: privateKey,
              hasRecoveryKey: hasCrk,
            );
            return;
          }
        }
        // No local key and offline — nothing else we can do right now. Stay
        // loaded-but-unlocked so the UI keeps rendering; the resume-refresh
        // above will run the full auto-heal when connectivity returns.
        state = ChatKeyState(
          isLoaded: true,
          isLocked: false,
          hasRecoveryKey: hasCrk,
        );
        return;
      }
      state = ChatKeyState(isLoaded: true, isLocked: false);
      return;
    }
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    try {
      await EncryptedCacheService.instance.initialize(userId);
    } catch (_) {}

    if (_initializedForUserId != userId) {
      // A different user is now active (login after logout, or an account
      // switch on the same device). Purge in-memory decryption/peer-key
      // caches so stale results from the previous user — including cached
      // nulls from failed decrypt attempts with the previous user's key —
      // don't block or leak into this user's session.
      _chatKeyService.clearMemoryCaches();
      _initializedForUserId = userId;
    }

    try {
      final hasLocal = await _chatKeyService.hasPrivateKeyLocally(userId);
      final activeKey = await _chatKeyService.fetchActiveKey(userId);
      final hasCrk = await _chatKeyService.loadCrkBytes(userId) != null;
      // An unauthenticated/expired session makes RLS return an empty result
      // instead of throwing. That empty result must NOT be treated as "the
      // server has no active key": doing so deletes a perfectly good local
      // private key and makes every message encrypted with it unreadable.
      final session = Supabase.instance.client.auth.currentSession;
      final hasValidSession = session != null && !session.isExpired;
      final hasPassword =
          activeKey != null &&
          (await _chatKeyService.fetchWrapperByType(
                activeKey.id,
                'password',
              )) !=
              null;

      if (kDebugMode) {
        debugPrint(
          '🔍 [ChatKeyProvider._init] userId=$userId hasLocal=$hasLocal activeKey=${activeKey?.id} activeKeyStatus=${activeKey?.status}',
        );
      }

      // 1. Local private key — fast path, works for both mobile and web.
      if (hasLocal) {
        // 1a. Stale-key detection: if we know which key ID the local key
        //     belongs to and it doesn't match the server's current active
        //     key, the local key is outdated (another device rotated while
        //     this one was offline). Drop it and fall through to auto-heal
        //     so this device picks up the current key.
        final storedActiveId = await _chatKeyService.loadActiveKeyIdLocally(
          userId,
        );
        if (kDebugMode) {
          debugPrint(
            '🔍 [ChatKeyProvider._init] storedActiveId=$storedActiveId activeKeyId=${activeKey?.id} match=${storedActiveId == activeKey?.id}',
          );
        }
        bool keyCleared = false;
        if (activeKey == null && storedActiveId != null && !hasValidSession) {
          debugPrint(
            '⚠️ [ChatKeyProvider] Active key lookup returned empty without a valid session — preserving local key',
          );
        }
        if (activeKey == null && storedActiveId != null && hasValidSession) {
          // Server has no active key but local has stale state — clear
          // local state and fall through to first-time setup.
          debugPrint(
            '⚠️ [ChatKeyProvider] Server has no active key but found local storedActiveId=$storedActiveId — clearing local state',
          );
          await _chatKeyService.deletePrivateKeyLocally(userId);
          keyCleared = true;
        } else if (activeKey != null &&
            storedActiveId != null &&
            storedActiveId != activeKey.id) {
          debugPrint(
            '⚠️ [ChatKeyProvider] Local key is stale (stored=$storedActiveId, server=${activeKey.id}) — clearing and re-healing',
          );
          await _chatKeyService.deletePrivateKeyLocally(userId);
          keyCleared = true;
        } else {
          final privateKey = await _chatKeyService.loadPrivateKeyBytes(userId);
          if (privateKey != null && privateKey.isNotEmpty) {
            // 1b. Public-key verification: derive the public key from the
            //     local private key and compare it to the server's active
            //     key public key. If they don't match, the local key is
            //     for a different key pair (e.g. another device called
            //     replaceEncryption which UPSERTs a new public key for
            //     the existing key ID) and must be replaced via auto-heal.
            //     This catches the case where the active key ID is the
            //     same but the key pair itself changed.
            if (activeKey != null) {
              try {
                final derivedPubKey = await _chatKeyService
                    .derivePublicKeyFromPrivate(privateKey);
                final serverPubKey = activeKey.publicKeyBase64;
                if (derivedPubKey != serverPubKey) {
                  debugPrint(
                    '⚠️ [ChatKeyProvider] Local key public key mismatch — clearing and re-healing. derived[0..12]=${derivedPubKey.substring(0, derivedPubKey.length < 12 ? derivedPubKey.length : 12)} server[0..12]=${serverPubKey.substring(0, serverPubKey.length < 12 ? serverPubKey.length : 12)} activeKeyId=${activeKey.id}',
                  );
                  await _chatKeyService.deletePrivateKeyLocally(userId);
                  keyCleared = true;
                } else {
                  debugPrint(
                    '✅ [ChatKeyProvider] Local key public key matches server active key',
                  );
                  // Backfill stored active ID for legacy entries.
                  if (storedActiveId == null) {
                    await _chatKeyService.storeActiveKeyIdLocally(
                      userId,
                      activeKey.id,
                    );
                  }
                }
              } catch (e) {
                debugPrint(
                  '⚠️ [ChatKeyProvider] Failed to verify local key public key: $e — proceeding anyway',
                );
              }
            }
            if (!keyCleared) {
              // Backfill the stored active ID for legacy entries that
              // pre-date the tracking. Idempotent.
              if (storedActiveId == null && activeKey != null) {
                await _chatKeyService.storeActiveKeyIdLocally(
                  userId,
                  activeKey.id,
                );
              }
              // Make sure the server-side auth_private_key backup is
              // present so this device can recover next time even if
              // local storage is lost. Best-effort.
              if (activeKey != null) {
                try {
                  await _chatKeyService.ensureAuthEncryptedPrivateKeyExists(
                    userId,
                    activeKey.id,
                    privateKey,
                  );
                } catch (_) {}
              }
              state = ChatKeyState(
                isLoaded: true,
                isLocked: false,
                activeKey: activeKey,
                privateKeyBytes: privateKey,
                hasRecoveryKey: hasCrk,
                hasPasswordWrapper: hasPassword,
              );
              return;
            }
          } else {
            // Private key exists but is null/empty - delete corrupted
            // entry and fall through to the server-side auto-heal path.
            debugPrint(
              '⚠️ [ChatKeyProvider] Private key corrupted locally, falling back to server-side auto-heal',
            );
            await _chatKeyService.deletePrivateKeyLocally(userId);
            keyCleared = true;
          }
        }
        if (keyCleared) {
          // Fall through to the auto-heal path below.
        }
      }

      // 2. No usable local key — try the auto-heal path.
      if (activeKey != null) {
        Uint8List? privateKey;

        // 2a. Primary: server-side auth_private_key wrapper. UUID-derived,
        //     immutable, single-step. This is what makes web fully
        //     self-healing.
        try {
          privateKey = await _chatKeyService.attemptAutoRecoverAuthPrivateKey(
            userId,
            activeKey.id,
          );
        } catch (_) {
          privateKey = null;
        }
        if (privateKey != null) {
          debugPrint(
            '✅ [ChatKeyProvider] Auto-healed private key from server-side auth_private_key wrapper',
          );
          await _chatKeyService.storePrivateKeyBytes(userId, privateKey);
          await _chatKeyService.storeActiveKeyIdLocally(userId, activeKey.id);
          state = ChatKeyState(
            isLoaded: true,
            isLocked: false,
            activeKey: activeKey,
            privateKeyBytes: privateKey,
            hasRecoveryKey: hasCrk,
            hasPasswordWrapper: hasPassword,
          );
          return;
        }

        // 2b. Fallback: local CRK + recovery_key wrapper.
        final localCrk = await _chatKeyService.loadCrkBytes(userId);
        if (localCrk != null) {
          privateKey = await _chatKeyService.unlockWithCrk(
            userId: userId,
            userChatKeyId: activeKey.id,
            crkBytes: localCrk,
          );
          if (privateKey != null) {
            debugPrint(
              '✅ [ChatKeyProvider] Auto-healed private key via local CRK',
            );
            try {
              await _chatKeyService.ensureAuthEncryptedPrivateKeyExists(
                userId,
                activeKey.id,
                privateKey,
              );
            } catch (_) {}
            state = ChatKeyState(
              isLoaded: true,
              isLocked: false,
              activeKey: activeKey,
              privateKeyBytes: privateKey,
              hasRecoveryKey: true,
              hasPasswordWrapper: hasPassword,
            );
            return;
          }
        }

        // 2c. Fallback: server-side auth_crk wrapper + recovery_key wrapper.
        final recoveredCrk = await _chatKeyService.attemptAutoRecoverCrk(
          userId,
          activeKey.id,
        );
        if (recoveredCrk != null) {
          privateKey = await _chatKeyService.unlockWithCrk(
            userId: userId,
            userChatKeyId: activeKey.id,
            crkBytes: recoveredCrk,
          );
          if (privateKey != null) {
            debugPrint(
              '✅ [ChatKeyProvider] Auto-healed private key via server-side auth_crk wrapper',
            );
            try {
              await _chatKeyService.ensureAuthEncryptedPrivateKeyExists(
                userId,
                activeKey.id,
                privateKey,
              );
            } catch (_) {}
            state = ChatKeyState(
              isLoaded: true,
              isLocked: false,
              activeKey: activeKey,
              privateKeyBytes: privateKey,
              hasRecoveryKey: true,
              hasPasswordWrapper: hasPassword,
            );
            return;
          }
        }

        // 3. No key could be recovered. Always auto-rotate to a fresh key
        //    so the account heals itself without any user action. If
        //    messages reference the lost key they are already undecryptable
        //    on this device (no key material exists anywhere), so rotation
        //    destroys nothing that is currently readable — it restores the
        //    user's ability to chat. We never surface a "locked" state.
        debugPrint(
          '♻️ [ChatKeyProvider] Lost key has no recoverable backup — auto-rotating',
        );
        try {
          await _chatKeyService.replaceLostChatKey(
            userId: userId,
            lostKeyId: activeKey.id,
            reauthToken: null,
          );
          final newPrivateKey = await _chatKeyService.loadPrivateKeyBytes(
            userId,
          );
          final newActiveKey = await _chatKeyService.fetchActiveKey(userId);
          final hasCrk = await _chatKeyService.loadCrkBytes(userId) != null;
          state = ChatKeyState(
            isLoaded: true,
            isLocked: false,
            activeKey: newActiveKey,
            privateKeyBytes: newPrivateKey,
            hasRecoveryKey: hasCrk,
            hasPasswordWrapper: false,
          );
          debugPrint(
            '✅ [ChatKeyProvider] Auto-rotated lost chat key — account healed',
          );
          return;
        } catch (e) {
          debugPrint('❌ [ChatKeyProvider] Auto-rotate failed: $e');
        }
        // Rotation failed (transient server error, etc.). Never lock the
        // account — stay loaded and schedule a retry so the next attempt
        // (connectivity resume or this timer) completes the heal.
        state = ChatKeyState(
          isLoaded: true,
          isLocked: false,
          activeKey: activeKey,
          hasRecoveryKey: hasCrk,
          hasPasswordWrapper: hasPassword,
        );
        unawaited(
          Future.delayed(const Duration(seconds: 30), () {
            if (state.isLocked == false && state.privateKeyBytes == null) {
              debugPrint(
                '🔑 [ChatKeyProvider] Retrying auto-heal after rotate failure',
              );
              unawaited(refresh());
            }
          }),
        );
        return;
      } else {
        // 4. First-time setup — no existing key, no messages to lose.
        if (!hasValidSession) {
          // setupEncryption would throw "Not authenticated" and then the
          // 15s retry below would keep firing while the token is dead.
          // Defer until a renewal/refresh provides an authenticated session.
          debugPrint(
            '🔑 [ChatKeyProvider] No valid session — deferring first-time key setup',
          );
          state = ChatKeyState(
            isLoaded: true,
            isLocked: false,
            hasRecoveryKey: hasCrk,
          );
          return;
        }
        debugPrint(
          'ℹ️ [ChatKeyProvider] No active key - setting up encryption',
        );
        await setupEncryption();
      }
    } catch (e) {
      debugPrint('❌ [ChatKeyProvider] Initialization error: $e');
      // Network or DB error during init — fall back to local-only state.
      // Never lock: if a local key exists it works as-is; otherwise stay
      // loaded without a key and let the resume-refresh / retry heal it.
      final hasLocal = await _chatKeyService.hasPrivateKeyLocally(userId);
      final hasCrk = await _chatKeyService.loadCrkBytes(userId) != null;
      if (hasLocal) {
        final privateKey = await _chatKeyService.loadPrivateKeyBytes(userId);
        if (privateKey != null && privateKey.isNotEmpty) {
          state = ChatKeyState(
            isLoaded: true,
            isLocked: false,
            privateKeyBytes: privateKey,
            hasRecoveryKey: hasCrk,
          );
        } else {
          state = ChatKeyState(
            isLoaded: true,
            isLocked: false,
            hasRecoveryKey: hasCrk,
          );
        }
      } else {
        state = ChatKeyState(
          isLoaded: true,
          isLocked: false,
          hasRecoveryKey: hasCrk,
        );
      }
      // Transient init errors (network blip, DB hiccup) self-heal on the
      // next attempt — connectivity resume or this short retry.
      unawaited(
        Future.delayed(const Duration(seconds: 15), () {
          if (state.privateKeyBytes == null && !state.isLocked) {
            debugPrint(
              '🔑 [ChatKeyProvider] Retrying init after transient error',
            );
            unawaited(refresh());
          }
        }),
      );
    }
  }

  Future<void> unlockWithPassword(String password) async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) throw Exception('Not authenticated');

    final activeKey = state.activeKey;
    if (activeKey == null) throw Exception('No active key');

    final privateKey = await _chatKeyService.unlockWithPassword(
      userId: userId,
      userChatKeyId: activeKey.id,
      password: password,
    );

    if (privateKey != null) {
      // Successfully unlocked - update state
      state = state.copyWith(isLocked: false, privateKeyBytes: privateKey);

      // Ensure CRK wrapper exists in database for future automatic recovery
      final crkBytes = await _chatKeyService.loadCrkBytes(userId);
      if (crkBytes != null) {
        try {
          await _chatKeyService.ensureAuthCrkWrapperExists(
            userId,
            activeKey.id,
            crkBytes,
          );
          debugPrint(
            '✅ [ChatKeyProvider] CRK wrapper created/verified for automatic recovery',
          );
        } catch (e) {
          debugPrint('⚠️ [ChatKeyProvider] Failed to create CRK wrapper: $e');
        }
      }

      // Ensure the server-side auth_private_key backup exists so web can
      // auto-heal in the future without user interaction.
      try {
        await _chatKeyService.ensureAuthEncryptedPrivateKeyExists(
          userId,
          activeKey.id,
          privateKey,
        );
        debugPrint(
          '✅ [ChatKeyProvider] auth_private_key backup created/verified for web auto-heal',
        );
      } catch (e) {
        debugPrint(
          '⚠️ [ChatKeyProvider] Failed to refresh auth_private_key backup: $e',
        );
      }
    } else {
      throw Exception('Invalid password');
    }
  }

  Future<void> unlockWithCrk(Uint8List crkBytes) async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) throw Exception('Not authenticated');

    final activeKey = state.activeKey;
    if (activeKey == null) throw Exception('No active key');

    final privateKey = await _chatKeyService.unlockWithCrk(
      userId: userId,
      userChatKeyId: activeKey.id,
      crkBytes: crkBytes,
    );

    if (privateKey != null) {
      // Successfully unlocked - update state
      state = state.copyWith(isLocked: false, privateKeyBytes: privateKey);

      // Ensure CRK wrapper exists in database for future automatic recovery
      try {
        await _chatKeyService.ensureAuthCrkWrapperExists(
          userId,
          activeKey.id,
          crkBytes,
        );
        debugPrint(
          '✅ [ChatKeyProvider] CRK wrapper created/verified for automatic recovery',
        );
      } catch (e) {
        debugPrint('⚠️ [ChatKeyProvider] Failed to create CRK wrapper: $e');
      }

      // Ensure the server-side auth_private_key backup exists so web can
      // auto-heal in the future without user interaction.
      try {
        await _chatKeyService.ensureAuthEncryptedPrivateKeyExists(
          userId,
          activeKey.id,
          privateKey,
        );
        debugPrint(
          '✅ [ChatKeyProvider] auth_private_key backup created/verified for web auto-heal',
        );
      } catch (e) {
        debugPrint(
          '⚠️ [ChatKeyProvider] Failed to refresh auth_private_key backup: $e',
        );
      }
    } else {
      throw Exception('Invalid recovery key');
    }
  }

  Future<void> setupEncryption({String? password}) async {
    if (shouldSkipSupabaseCalls()) {
      debugPrint('🔑 [ChatKeyProvider] Skipping setupEncryption while offline');
      return;
    }
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) throw Exception('Not authenticated');

    final newKey = await _chatKeyService.setupEncryption(
      userId: userId,
      password: password,
    );

    final privateKey = await _chatKeyService.loadPrivateKeyBytes(userId);

    state = ChatKeyState(
      isLoaded: true,
      isLocked: false,
      activeKey: newKey,
      privateKeyBytes: privateKey,
      hasRecoveryKey: true,
      hasPasswordWrapper: password != null && password.isNotEmpty,
    );
  }

  /// Replaces a zombie/locked key (no local private key and no recovery option)
  /// by retiring the old key in the DB and creating a fresh one.
  Future<void> replaceEncryption() async {
    if (shouldSkipSupabaseCalls()) {
      debugPrint(
        '🔑 [ChatKeyProvider] Skipping replaceEncryption while offline',
      );
      return;
    }
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) throw Exception('Not authenticated');

    // Capture the old key ID BEFORE retire so we can archive the private key
    // for decrypting old messages after rotation.
    final oldKeyBeforeRetire = await _chatKeyService.fetchActiveKey(userId);

    // Archive the old private key BEFORE any DB writes.
    // This ensures old messages remain decryptable even if the subsequent
    // setupEncryption call fails (e.g. due to a DB constraint violation).
    if (oldKeyBeforeRetire != null) {
      final oldPrivateKey = await _chatKeyService.loadPrivateKeyBytes(userId);
      if (oldPrivateKey != null) {
        final existingArchive = await _chatKeyService
            .loadPrivateKeyBytesByKeyId(userId, oldKeyBeforeRetire.id);
        if (existingArchive == null) {
          await _chatKeyService.storePrivateKeyBytesByKeyId(
            userId,
            oldKeyBeforeRetire.id,
            oldPrivateKey,
          );
        }
      }
    }

    await _chatKeyService.deleteActiveKey(userId);
    await _chatKeyService.setupEncryption(
      userId: userId,
      existingKeyId: oldKeyBeforeRetire?.id,
    );

    final privateKey = await _chatKeyService.loadPrivateKeyBytes(userId);
    final activeKey = await _chatKeyService.fetchActiveKey(userId);
    final hasCrk = await _chatKeyService.loadCrkBytes(userId) != null;

    state = ChatKeyState(
      isLoaded: true,
      isLocked: false,
      activeKey: activeKey,
      privateKeyBytes: privateKey,
      hasRecoveryKey: hasCrk,
      hasPasswordWrapper: false,
    );
  }

  Future<void> refresh() async {
    _initFuture = _init();
    await _initFuture;
  }

  Future<void> lock() async {
    state = state.copyWith(isLocked: true, privateKeyBytes: null);
  }

  bool get canSendEncrypted =>
      state.isLoaded && !state.isLocked && state.activeKey != null;
}

final chatKeyProvider = NotifierProvider<ChatKeyNotifier, ChatKeyState>(() {
  return ChatKeyNotifier();
});
