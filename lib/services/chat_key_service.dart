import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:matchme/config/security_constants.dart';
import 'package:matchme/models/user_chat_key_model.dart';
import 'package:matchme/services/crypto_service.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/secure_storage_service.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ChatKeyService {
  ChatKeyService._();
  static final ChatKeyService instance = ChatKeyService._();

  bool _lifecycleObserverAttached = false;

  /// Zeroize the in-memory decrypted-content cache when the app is
  /// backgrounded (lock screen / app switcher). Subsequent foreground reads
  /// re-decrypt from the still-cached ciphertext, so this only costs a little
  /// CPU, never correctness. Call once at startup after bindings are ready.
  void attachLifecycleObserver() {
    if (_lifecycleObserverAttached) return;
    _lifecycleObserverAttached = true;
    WidgetsBinding.instance.addObserver(_ChatKeyLifecycleObserver());
  }

  final SecureStorageService _secureStorage = SecureStorageService.instance;
  static const _privateKeyPrefix = 'chat_private_key:';
  static const _privateKeyActiveIdPrefix = 'chat_private_key_active_id:';
  static const _crkPrefix = 'chat_crk:';
  static const _recoveryConfirmedPrefix = 'chat_recovery_confirmed:';

  final CryptoService _crypto = CryptoService.instance;
  final Map<String, UserChatKeyModel?> _peerKeyCache = {};

  // In-memory cache for decrypted message content. Keyed by messageId.
  // Avoids re-running the expensive X25519 + HKDF + AES-GCM decryption on
  // every syncChatsNow pass for messages that haven't changed.
  static final Map<String, String?> _decryptedContentCache = {};

  Future<bool> hasPrivateKeyLocally(String userId) async {
    final key = await _secureStorage.read('$_privateKeyPrefix$userId');
    return key != null && key.isNotEmpty;
  }

  Future<Uint8List?> loadPrivateKeyBytes(String userId) async {
    final encoded = await _secureStorage.read('$_privateKeyPrefix$userId');
    if (encoded == null || encoded.isEmpty) return null;
    return base64Decode(encoded);
  }

  Future<void> storePrivateKeyBytes(String userId, Uint8List privateKey) async {
    final encoded = base64Encode(privateKey);
    await _secureStorage.write('$_privateKeyPrefix$userId', encoded);
  }

  /// Stores the active key ID that [storePrivateKeyBytes] corresponds to.
  /// Used on init to detect a stale local key (e.g. another device rotated
  /// the key while this one was offline) and trigger an auto-heal.
  Future<void> storeActiveKeyIdLocally(
    String userId,
    String activeKeyId,
  ) async {
    await _secureStorage.write(
      '$_privateKeyActiveIdPrefix$userId',
      activeKeyId,
    );
  }

  /// Returns the active key ID the local private key was set up for, or null
  /// if the local key has no associated ID (legacy entry, pre-tracking).
  Future<String?> loadActiveKeyIdLocally(String userId) async {
    return _secureStorage.read('$_privateKeyActiveIdPrefix$userId');
  }

  Future<void> deleteActiveKeyIdLocally(String userId) async {
    await _secureStorage.delete('$_privateKeyActiveIdPrefix$userId');
  }

  Future<void> deletePrivateKeyLocally(String userId) async {
    await _secureStorage.delete('$_privateKeyPrefix$userId');
    await deleteActiveKeyIdLocally(userId);
  }

  /// Loads a private key that was archived for a specific key ID.
  /// This allows decryption of old messages after key rotation.
  Future<Uint8List?> loadPrivateKeyBytesByKeyId(
    String userId,
    String keyId,
  ) async {
    final encoded = await _secureStorage.read(
      '$_privateKeyPrefix$userId:$keyId',
    );
    if (encoded == null || encoded.isEmpty) return null;
    return base64Decode(encoded);
  }

  /// Archives a private key under its key ID so it can be retrieved later
  /// for decrypting messages encrypted before a key rotation.
  Future<void> storePrivateKeyBytesByKeyId(
    String userId,
    String keyId,
    Uint8List privateKey,
  ) async {
    final encoded = base64Encode(privateKey);
    await _secureStorage.write('$_privateKeyPrefix$userId:$keyId', encoded);
  }

  Future<Uint8List?> loadCrkBytes(String userId) async {
    final encoded = await _secureStorage.read('$_crkPrefix$userId');
    if (encoded == null || encoded.isEmpty) return null;
    return base64Decode(encoded);
  }

  Future<void> storeCrkBytes(String userId, Uint8List crkBytes) async {
    final encoded = base64Encode(crkBytes);
    await _secureStorage.write('$_crkPrefix$userId', encoded);
  }

  Future<bool> isRecoveryConfirmed(String userId) async {
    final val = await _secureStorage.read('$_recoveryConfirmedPrefix$userId');
    return val == 'true';
  }

  Future<void> setRecoveryConfirmed(String userId, bool confirmed) async {
    await _secureStorage.write(
      '$_recoveryConfirmedPrefix$userId',
      confirmed ? 'true' : 'false',
    );
  }

  Future<UserChatKeyModel?> fetchActiveKey(String userId) async {
    if (shouldSkipSupabaseCalls()) return null;
    final supabase = Supabase.instance.client;
    final data = await supabase
        .from('user_chat_keys')
        .select()
        .eq('user_id', userId)
        .eq('status', 'active')
        .maybeSingle();
    if (data == null) return null;
    return UserChatKeyModel.fromJson(data);
  }

  Future<UserChatKeyModel?> fetchKeyById(String keyId) async {
    if (shouldSkipSupabaseCalls()) return null;
    final supabase = Supabase.instance.client;
    final data = await supabase
        .from('user_chat_keys')
        .select()
        .eq('id', keyId)
        .maybeSingle();
    if (data == null) return null;
    return UserChatKeyModel.fromJson(data);
  }

  Future<List<UserChatKeyWrapperModel>> fetchWrappers(
    String userChatKeyId,
  ) async {
    if (shouldSkipSupabaseCalls()) return [];
    final supabase = Supabase.instance.client;
    final data = await supabase
        .from('user_chat_key_wrappers')
        .select()
        .eq('user_chat_key_id', userChatKeyId);
    return data.map((e) => UserChatKeyWrapperModel.fromJson(e)).toList();
  }

  Future<UserChatKeyWrapperModel?> fetchWrapperByType(
    String userChatKeyId,
    String wrapperType,
  ) async {
    if (shouldSkipSupabaseCalls()) return null;
    final supabase = Supabase.instance.client;
    final data = await supabase
        .from('user_chat_key_wrappers')
        .select()
        .eq('user_chat_key_id', userChatKeyId)
        .eq('wrapper_type', wrapperType)
        .maybeSingle();
    if (data == null) return null;
    return UserChatKeyWrapperModel.fromJson(data);
  }

  /// Attempts to deactivate the active key by setting its status to 'retired'.
  /// If RLS blocks the UPDATE (returns 0 rows affected), falls back to keeping
  /// the old key intact. Returns the old key (or null if none existed).
  Future<UserChatKeyModel?> deleteActiveKey(String userId) async {
    if (shouldSkipSupabaseCalls()) return null;
    final supabase = Supabase.instance.client;
    final activeKey = await fetchActiveKey(userId);
    if (activeKey == null) return null;
    final result = await supabase
        .from('user_chat_keys')
        .update({
          'status': 'retired',
          'retired_at': DateTime.now().toIso8601String(),
        })
        .eq('id', activeKey.id)
        .select();
    if (result.isEmpty) {
      return activeKey;
    }
    return null;
  }

  /// Decrypts a v1-encrypted message's content using the current user's private key.
  /// [recipientId] is the user who received the message (not the current user).
  /// If null, it will be derived from the match.
  /// Core decryption using a specific private key. Returns null on failure.
  Future<String?> _decryptMessageContentWithKey({
    required Uint8List myPrivateKey,
    required Uint8List peerPublicKeyBytes,
    required String messageId,
    required String senderKeyId,
    required String recipientKeyId,
    required String contentOriginalEncryptedBase64,
    required String contentOriginalNonceBase64,
    required Map<String, dynamic> wrappedKeys,
    required String effectiveRecipientId,
    required String matchId,
    required String senderId,
  }) async {
    try {
      final sharedSecret = await _crypto.x25519SharedSecretFromPrivateKey(
        myPrivateKey: myPrivateKey,
        theirPublicKey: peerPublicKeyBytes,
      );

      final messageIdBytes = Uint8List.fromList(utf8.encode(messageId));
      final wrapKey = await _crypto.hkdfDeriveBytes(
        inputKeyMaterial: sharedSecret,
        salt: messageIdBytes,
        info: SecurityConstants.recipientWrapInfoLabel,
      );

      final wrapAad = _crypto.buildWrapAad(
        purpose: 'recipient',
        messageId: messageId,
        senderKeyId: senderKeyId,
        recipientOrSupabaseKeyId: recipientKeyId,
      );

      final recipientWrap = wrappedKeys['recipient'] as Map<String, dynamic>?;
      if (recipientWrap == null) return null;
      final wrapNonceBase64 = recipientWrap['nonce'] as String?;
      final wrapCiphertextBase64 = recipientWrap['ciphertext'] as String?;
      if (wrapNonceBase64 == null || wrapCiphertextBase64 == null) return null;

      Uint8List messageKey;
      try {
        messageKey = await _crypto.unwrapMessageKey(
          wrappedKey: base64Decode(wrapCiphertextBase64),
          wrapKey: wrapKey,
          nonce: base64Decode(wrapNonceBase64),
          aad: wrapAad,
        );
      } catch (unwrapErr) {
        debugPrint('❌ [decrypt] unwrapMessageKey FAILED');
        debugPrint(
          '   key sizes: myPrivateKey=${myPrivateKey.length} peerPubKey=${peerPublicKeyBytes.length}',
        );
        debugPrint(
          '   sharedSecret.len=${sharedSecret.length} wrapKey.len=${wrapKey.length}',
        );
        debugPrint(
          '   wrapNonce.len=${base64Decode(wrapNonceBase64).length} wrapCt.len=${base64Decode(wrapCiphertextBase64).length}',
        );
        return null;
      }

      final decryptedBytes = await _crypto.decryptOriginal(
        ciphertext: base64Decode(contentOriginalEncryptedBase64),
        messageKey: messageKey,
        nonce: base64Decode(contentOriginalNonceBase64),
        messageId: messageId,
        matchId: matchId,
        senderId: senderId,
        recipientId: effectiveRecipientId,
        senderKeyId: senderKeyId,
        recipientKeyId: recipientKeyId,
      );

      return utf8.decode(decryptedBytes);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _resolveEffectiveRecipientId({
    required String matchId,
    required String senderId,
    required String currentUserId,
    String? explicitRecipientId,
  }) async {
    if (explicitRecipientId != null && explicitRecipientId.isNotEmpty) {
      return explicitRecipientId;
    }
    if (currentUserId != senderId) {
      return currentUserId;
    }
    // Sender is current user. Find match partner locally (100% offline friendly).
    try {
      final localDb = await LocalDbService.instance;
      final cachedMatches = await localDb.watchMatches(currentUserId).first;
      for (final m in cachedMatches) {
        if (m['id']?.toString() == matchId) {
          final u1 = m['user1_id']?.toString();
          final u2 = m['user2_id']?.toString();
          if (u1 != null && u2 != null) {
            return (u1 == senderId) ? u2 : u1;
          }
        }
      }
      final cachedChats = await localDb.watchChats(currentUserId).first;
      for (final c in cachedChats) {
        if (c['id']?.toString() == matchId ||
            c['match_id']?.toString() == matchId) {
          final otherId = c['other_user_id']?.toString();
          if (otherId != null && otherId.isNotEmpty) {
            return otherId;
          }
        }
      }
    } catch (_) {}

    if (!shouldSkipSupabaseCalls()) {
      try {
        final supabase = Supabase.instance.client;
        final matchResp = await supabase
            .from('matches')
            .select('user1_id, user2_id')
            .eq('id', matchId)
            .maybeSingle();
        if (matchResp != null) {
          return matchResp['user1_id'] == senderId
              ? matchResp['user2_id'] as String?
              : matchResp['user1_id'] as String?;
        }
      } catch (_) {}
    }
    return null;
  }

  Future<String?> decryptMessageContent({
    required String currentUserId,
    required Uint8List currentUserPrivateKey,
    required String messageId,
    required String matchId,
    required String senderId,
    required String senderKeyId,
    required String recipientKeyId,
    required String contentOriginalEncryptedBase64,
    required String contentOriginalNonceBase64,
    required Map<String, dynamic> wrappedKeys,
    String? recipientId,
    UserChatKeyModel? prefetchedPeerKey,
  }) async {
    // Check in-memory cache first — same message always decrypts to same plaintext
    final cacheKey = '$messageId|${contentOriginalEncryptedBase64.hashCode}';
    final cached = _decryptedContentCache[cacheKey];
    if (cached != null || _decryptedContentCache.containsKey(cacheKey)) {
      return cached;
    }

    final effectiveRecipientId = await _resolveEffectiveRecipientId(
      matchId: matchId,
      senderId: senderId,
      currentUserId: currentUserId,
      explicitRecipientId: recipientId,
    );
    if (effectiveRecipientId == null) return null;

    final bool iAmSender = currentUserId == senderId;
    final String peerKeyId = iAmSender ? recipientKeyId : senderKeyId;

    final peerKey = prefetchedPeerKey ?? await fetchPeerPublicKey(peerKeyId);
    if (peerKey == null) {
      // Do not cache null: the key may be fetched later or loaded on reconnect
      return null;
    }
    final peerPublicKeyBytes = base64Decode(peerKey.publicKeyBase64);

    // Try with the provided (current) private key first
    final result = await _decryptMessageContentWithKey(
      myPrivateKey: currentUserPrivateKey,
      peerPublicKeyBytes: peerPublicKeyBytes,
      messageId: messageId,
      senderKeyId: senderKeyId,
      recipientKeyId: recipientKeyId,
      contentOriginalEncryptedBase64: contentOriginalEncryptedBase64,
      contentOriginalNonceBase64: contentOriginalNonceBase64,
      wrappedKeys: wrappedKeys,
      effectiveRecipientId: effectiveRecipientId,
      matchId: matchId,
      senderId: senderId,
    );
    if (result != null) {
      _decryptedContentCache[cacheKey] = result;
      return result;
    }

    // Fallback: the current key didn't work (likely rotated).
    // Try the archived private key for the key ID that was active when this
    // message was encrypted.
    final String requiredKeyId = iAmSender ? senderKeyId : recipientKeyId;
    final archivedKey = await loadPrivateKeyBytesByKeyId(
      currentUserId,
      requiredKeyId,
    );
    if (archivedKey != null) {
      final fallbackResult = await _decryptMessageContentWithKey(
        myPrivateKey: archivedKey,
        peerPublicKeyBytes: peerPublicKeyBytes,
        messageId: messageId,
        senderKeyId: senderKeyId,
        recipientKeyId: recipientKeyId,
        contentOriginalEncryptedBase64: contentOriginalEncryptedBase64,
        contentOriginalNonceBase64: contentOriginalNonceBase64,
        wrappedKeys: wrappedKeys,
        effectiveRecipientId: effectiveRecipientId,
        matchId: matchId,
        senderId: senderId,
      );
      if (fallbackResult != null) {
        _decryptedContentCache[cacheKey] = fallbackResult;
        return fallbackResult;
      }
    }

    // Cache null only when keys were genuinely available and failed verification
    _decryptedContentCache[cacheKey] = null;
    return null;
  }

  /// Core translated content decryption using a specific private key.
  /// Returns null on failure (no exceptions thrown to caller).
  Future<String?> _decryptMessageTranslatedWithKey({
    required Uint8List myPrivateKey,
    required Uint8List peerPublicKeyBytes,
    required String messageId,
    required String senderKeyId,
    required String recipientKeyId,
    required String contentTranslatedEncryptedBase64,
    required String contentTranslatedNonceBase64,
    required Map<String, dynamic> wrappedKeys,
    required String effectiveRecipientId,
    required String matchId,
    required String senderId,
    required String detectedSourceLanguage,
    required String targetLanguage,
  }) async {
    try {
      final sharedSecret = await _crypto.x25519SharedSecretFromPrivateKey(
        myPrivateKey: myPrivateKey,
        theirPublicKey: peerPublicKeyBytes,
      );

      final messageIdBytes = Uint8List.fromList(utf8.encode(messageId));
      final wrapKey = await _crypto.hkdfDeriveBytes(
        inputKeyMaterial: sharedSecret,
        salt: messageIdBytes,
        info: SecurityConstants.recipientWrapInfoLabel,
      );

      final wrapAad = _crypto.buildWrapAad(
        purpose: 'recipient',
        messageId: messageId,
        senderKeyId: senderKeyId,
        recipientOrSupabaseKeyId: recipientKeyId,
      );

      final recipientWrap = wrappedKeys['recipient'] as Map<String, dynamic>?;
      if (recipientWrap == null) return null;
      final wrapNonceBase64 = recipientWrap['nonce'] as String?;
      final wrapCiphertextBase64 = recipientWrap['ciphertext'] as String?;
      if (wrapNonceBase64 == null || wrapCiphertextBase64 == null) return null;

      final messageKey = await _crypto.unwrapMessageKey(
        wrappedKey: base64Decode(wrapCiphertextBase64),
        wrapKey: wrapKey,
        nonce: base64Decode(wrapNonceBase64),
        aad: wrapAad,
      );

      final decryptedBytes = await _crypto.decryptTranslated(
        ciphertext: base64Decode(contentTranslatedEncryptedBase64),
        messageKey: messageKey,
        nonce: base64Decode(contentTranslatedNonceBase64),
        messageId: messageId,
        matchId: matchId,
        senderId: senderId,
        recipientId: effectiveRecipientId,
        detectedSourceLanguage: detectedSourceLanguage,
        targetLanguage: targetLanguage,
        senderKeyId: senderKeyId,
        recipientKeyId: recipientKeyId,
      );
      return utf8.decode(decryptedBytes);
    } catch (_) {
      return null;
    }
  }

  Future<String?> decryptMessageTranslatedContent({
    required String currentUserId,
    required Uint8List currentUserPrivateKey,
    required String messageId,
    required String matchId,
    required String senderId,
    required String senderKeyId,
    required String recipientKeyId,
    required String contentTranslatedEncryptedBase64,
    required String contentTranslatedNonceBase64,
    required Map<String, dynamic> wrappedKeys,
    required String detectedSourceLanguage,
    required String targetLanguage,
    String? recipientId,
    UserChatKeyModel? prefetchedPeerKey,
  }) async {
    // Cache key MUST include both languages: the translation AAD binds the
    // ciphertext to (source, target), so the same blob decrypted for 'he'
    // must never satisfy a later 'es' request. Omitting the target caused
    // stale-language reuse after a UI language switch (UI=es, target=he
    // incorrectly returned the cached Hebrew text via Case C).
    final cacheKey =
        'translated|$messageId|${detectedSourceLanguage.trim().toLowerCase()}|${targetLanguage.trim().toLowerCase()}|${contentTranslatedEncryptedBase64.hashCode}';
    final cached = _decryptedContentCache[cacheKey];
    if (cached != null || _decryptedContentCache.containsKey(cacheKey)) {
      return cached;
    }

    final effectiveRecipientId = await _resolveEffectiveRecipientId(
      matchId: matchId,
      senderId: senderId,
      currentUserId: currentUserId,
      explicitRecipientId: recipientId,
    );
    if (effectiveRecipientId == null) return null;

    final bool iAmSender = currentUserId == senderId;
    final String peerKeyId = iAmSender ? recipientKeyId : senderKeyId;

    final peerKey = prefetchedPeerKey ?? await fetchPeerPublicKey(peerKeyId);
    if (peerKey == null) {
      // Do not cache null: the key may be fetched later or loaded on reconnect
      return null;
    }
    final peerPublicKeyBytes = base64Decode(peerKey.publicKeyBase64);

    // Try with the provided (current) private key first
    final result = await _decryptMessageTranslatedWithKey(
      myPrivateKey: currentUserPrivateKey,
      peerPublicKeyBytes: peerPublicKeyBytes,
      messageId: messageId,
      senderKeyId: senderKeyId,
      recipientKeyId: recipientKeyId,
      contentTranslatedEncryptedBase64: contentTranslatedEncryptedBase64,
      contentTranslatedNonceBase64: contentTranslatedNonceBase64,
      wrappedKeys: wrappedKeys,
      effectiveRecipientId: effectiveRecipientId,
      matchId: matchId,
      senderId: senderId,
      detectedSourceLanguage: detectedSourceLanguage,
      targetLanguage: targetLanguage,
    );
    if (result != null) {
      _decryptedContentCache[cacheKey] = result;
      return result;
    }

    // Fallback: the current key didn't work (likely rotated).
    // Try the archived private key for the key ID that was active when this
    // message was encrypted.
    final String requiredKeyId = iAmSender ? senderKeyId : recipientKeyId;
    final archivedKey = await loadPrivateKeyBytesByKeyId(
      currentUserId,
      requiredKeyId,
    );
    if (archivedKey != null) {
      final fallbackResult = await _decryptMessageTranslatedWithKey(
        myPrivateKey: archivedKey,
        peerPublicKeyBytes: peerPublicKeyBytes,
        messageId: messageId,
        senderKeyId: senderKeyId,
        recipientKeyId: recipientKeyId,
        contentTranslatedEncryptedBase64: contentTranslatedEncryptedBase64,
        contentTranslatedNonceBase64: contentTranslatedNonceBase64,
        wrappedKeys: wrappedKeys,
        effectiveRecipientId: effectiveRecipientId,
        matchId: matchId,
        senderId: senderId,
        detectedSourceLanguage: detectedSourceLanguage,
        targetLanguage: targetLanguage,
      );
      if (fallbackResult != null) {
        _decryptedContentCache[cacheKey] = fallbackResult;
        return fallbackResult;
      }
    }

    // Cache null only when keys were genuinely available and failed verification
    _decryptedContentCache[cacheKey] = null;
    return null;
  }

  /// Derives the X25519 public key (base64) from a raw private key seed.
  /// Used to detect stale local keys by comparing the derived public key
  /// with the server's stored active key public key.
  Future<String> derivePublicKeyFromPrivate(Uint8List privateKey) async {
    final crypto = CryptoService.instance;
    final kp = await crypto.newKeyPairFromSeed(privateKey);
    final pubKeyBytes = await crypto.publicKeyToBytes(kp);
    return crypto.publicKeyToBase64(pubKeyBytes);
  }

  Future<UserChatKeyModel?> fetchPeerPublicKey(String keyId) async {
    if (_peerKeyCache.containsKey(keyId)) {
      final cached = _peerKeyCache[keyId];
      if (cached != null) return cached;
    }

    // Check persistent disk cache (SharedPreferences)
    try {
      final prefs = await SharedPreferences.getInstance();
      final storedJson = prefs.getString('peer_chat_key:$keyId');
      if (storedJson != null && storedJson.isNotEmpty) {
        final key = UserChatKeyModel.fromJson(
          jsonDecode(storedJson) as Map<String, dynamic>,
        );
        _peerKeyCache[keyId] = key;
        return key;
      }
    } catch (e) {
      debugPrint('⚠️ [fetchPeerPublicKey] Failed loading peer key from prefs: $e');
    }

    if (shouldSkipSupabaseCalls()) return _peerKeyCache[keyId];

    try {
      final supabase = Supabase.instance.client;
      final data = await supabase
          .from('user_chat_keys')
          .select(
            'id, user_id, key_version, public_key, status, created_at, activated_at, retired_at',
          )
          .eq('id', keyId)
          .maybeSingle();
      if (data == null) return null;
      final key = UserChatKeyModel.fromJson(data);
      _peerKeyCache[keyId] = key;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'peer_chat_key:$keyId',
          jsonEncode(key.toJson()),
        );
      } catch (_) {}
      return key;
    } catch (e) {
      debugPrint('⚠️ [fetchPeerPublicKey] Supabase fetch failed: $e');
      return null;
    }
  }

  /// Batch warm peer public keys into memory and persistent disk cache.
  /// Called on chat sync and Phase 2 decryption so offline access always succeeds.
  Future<void> warmPeerKeys(Iterable<String> keyIds) async {
    final toFetch = <String>[];
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {}

    for (final id in keyIds) {
      if (id.isEmpty) continue;
      if (_peerKeyCache[id] != null) continue;
      if (prefs != null) {
        final stored = prefs.getString('peer_chat_key:$id');
        if (stored != null && stored.isNotEmpty) {
          try {
            _peerKeyCache[id] = UserChatKeyModel.fromJson(
              jsonDecode(stored) as Map<String, dynamic>,
            );
            continue;
          } catch (_) {}
        }
      }
      toFetch.add(id);
    }

    if (toFetch.isEmpty || shouldSkipSupabaseCalls()) return;

    try {
      final supabase = Supabase.instance.client;
      final rows = await supabase
          .from('user_chat_keys')
          .select(
            'id, user_id, key_version, public_key, status, created_at, activated_at, retired_at',
          )
          .filter('id', 'in', toFetch);
      for (final row in rows) {
        final key = UserChatKeyModel.fromJson(row);
        _peerKeyCache[key.id] = key;
        if (prefs != null) {
          await prefs.setString(
            'peer_chat_key:${key.id}',
            jsonEncode(key.toJson()),
          );
        }
      }
    } catch (e) {
      debugPrint('⚠️ [warmPeerKeys] Failed warming peer keys: $e');
    }
  }

  void clearPeerKeyCache() => _peerKeyCache.clear();

  /// Clears all in-memory decryption/peer-key caches. Called when the
  /// authenticated user changes so stale entries from the previous user
  /// (including cached null results from failed decrypt attempts) cannot
  /// leak into or block the new user's session.
  void clearMemoryCaches() {
    _decryptedContentCache.clear();
    _peerKeyCache.clear();
  }

  Future<UserChatKeyModel> setupEncryption({
    required String userId,
    String? password,
    String? existingKeyId,
  }) async {
    final keyPair = await _crypto.generateX25519KeyPair();
    final privateKeyBytes = await _crypto.privateKeyToBytes(keyPair);
    final publicKeyBytes = await _crypto.publicKeyToBytes(keyPair);
    final publicKeyBase64 = _crypto.publicKeyToBase64(publicKeyBytes);
    final crkBytes = await _crypto.generateRandomBytes(
      SecurityConstants.crkByteLength,
    );
    final recoverySalt = _crypto.generateRandomBytesSync(
      SecurityConstants.pbkdf2SaltLength,
    );
    final recoveryWrapKey = await _crypto.hkdfDeriveBytes(
      inputKeyMaterial: crkBytes,
      salt: recoverySalt,
      info: SecurityConstants.crkInfoLabel,
    );
    final recoveryNonce = _crypto.generateNonce();
    final recoveryAad = Uint8List.fromList(
      utf8.encode('chat-private-key-recovery'),
    );
    final encryptedPrivateKeyByRecovery = await _crypto.aesGcmEncrypt(
      plaintext: privateKeyBytes,
      key: recoveryWrapKey,
      nonce: recoveryNonce,
      aad: recoveryAad,
    );

    final supabase = Supabase.instance.client;
    final String userChatKeyId;
    final int keyVersion;

    final maxVersionResult = await supabase
        .from('user_chat_keys')
        .select('key_version')
        .eq('user_id', userId)
        .order('key_version', ascending: false)
        .limit(1);
    final nextVersion = (maxVersionResult.isNotEmpty
        ? (maxVersionResult.first['key_version'] as int) + 1
        : 1);

    if (existingKeyId != null) {
      final keyResult = await supabase
          .from('user_chat_keys')
          .upsert({
            'id': existingKeyId,
            'user_id': userId,
            'key_version': nextVersion,
            'public_key': publicKeyBase64,
            'status': 'active',
          }, onConflict: 'id')
          .select()
          .single();
      userChatKeyId = keyResult['id'] as String;
      keyVersion = keyResult['key_version'] as int;
      await supabase
          .from('user_chat_key_wrappers')
          .delete()
          .eq('user_chat_key_id', existingKeyId);
    } else {
      final keyResult = await supabase
          .from('user_chat_keys')
          .insert({
            'user_id': userId,
            'key_version': nextVersion,
            'public_key': publicKeyBase64,
            'status': 'active',
          })
          .select()
          .single();
      userChatKeyId = keyResult['id'] as String;
      keyVersion = nextVersion;
    }

    await supabase.from('user_chat_key_wrappers').insert({
      'user_chat_key_id': userChatKeyId,
      'user_id': userId,
      'wrapper_type': 'recovery_key',
      'kdf': 'HKDF-SHA256',
      'kdf_salt': base64Encode(recoverySalt),
      'wrap_alg': 'AES-256-GCM',
      'wrap_nonce': base64Encode(recoveryNonce),
      'encrypted_private_key': base64Encode(encryptedPrivateKeyByRecovery),
    });

    // Store CRK encrypted with auth-derived key for automatic recovery.
    // This is a non-critical optimization — if it fails, the recovery key
    // wrapper and local storage still ensure the user can decrypt messages.
    try {
      await _storeAuthEncryptedCrk(userId, userChatKeyId, crkBytes);
    } catch (_) {
      // Non-fatal: recovery key wrapper and local store are sufficient
    }

    // Before overwriting the private key, archive the old one under its key ID
    // so old messages can still be decrypted after rotation.
    if (existingKeyId != null) {
      final existingArchive = await loadPrivateKeyBytesByKeyId(
        userId,
        existingKeyId,
      );
      if (existingArchive == null) {
        final oldPrivateKey = await loadPrivateKeyBytes(userId);
        if (oldPrivateKey != null) {
          await storePrivateKeyBytesByKeyId(
            userId,
            existingKeyId,
            oldPrivateKey,
          );
        }
      }
    }

    // Persist the key locally FIRST. This way a failure in the server-side
    // backup below never strands a brand-new key with no local copy — the
    // next boot on this device will backfill the wrapper itself.
    await storePrivateKeyBytes(userId, privateKeyBytes);
    await storeActiveKeyIdLocally(userId, userChatKeyId);
    await storeCrkBytes(userId, crkBytes);

    // Store the private key encrypted with a key derived from the user's UUID.
    // This is the primary auto-heal path on web: if local storage is lost
    // (cleared site data, new browser, incognito, etc.) the chat key can still
    // be recovered without any user interaction.
    await _storeAuthEncryptedPrivateKey(userId, userChatKeyId, privateKeyBytes);

    if (password != null && password.isNotEmpty) {
      await createPasswordWrapper(
        userId: userId,
        userChatKeyId: userChatKeyId,
        privateKeyBytes: privateKeyBytes,
        password: password,
      );
    }

    return UserChatKeyModel(
      id: userChatKeyId,
      userId: userId,
      keyVersion: keyVersion,
      publicKeyBase64: publicKeyBase64,
      status: 'active',
      createdAt: DateTime.now(),
      activatedAt: DateTime.now(),
    );
  }

  /// Stores the CRK encrypted with a key derived from the user's UUID.
  /// The user ID is the only truly immutable identifier — it never changes,
  /// not even on email change. This ensures the CRK is always recoverable
  /// after any session change on web.
  Future<void> _storeAuthEncryptedCrk(
    String userId,
    String userChatKeyId,
    Uint8List crkBytes,
  ) async {
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user == null) return;

    final salt = _crypto.generateRandomBytesSync(
      SecurityConstants.pbkdf2SaltLength,
    );
    final authWrapKey = await _crypto.hkdfDeriveBytes(
      inputKeyMaterial: Uint8List.fromList(utf8.encode(userId)),
      salt: salt,
      info: 'matchme-auth-crk-wrap-v3',
    );

    final nonce = _crypto.generateNonce();
    final aad = Uint8List.fromList(utf8.encode('chat-crk-auth-wrap'));
    final encryptedCrk = await _crypto.aesGcmEncrypt(
      plaintext: crkBytes,
      key: authWrapKey,
      nonce: nonce,
      aad: aad,
    );

    // Store in database
    await supabase.from('user_chat_crk_wrappers').upsert({
      'user_id': userId,
      'user_chat_key_id': userChatKeyId,
      'kdf': 'HKDF-SHA256-UID',
      'kdf_salt': base64Encode(salt),
      'wrap_alg': 'AES-256-GCM',
      'wrap_nonce': base64Encode(nonce),
      'encrypted_crk': base64Encode(encryptedCrk),
    }, onConflict: 'user_id,user_chat_key_id');
  }

  /// Attempts to automatically recover the CRK from the database.
  ///
  /// Tries three derivation methods in order of stability:
  /// 1. User-ID-based (v3) — immutable, never changes — primary method.
  /// 2. Email-based (v2) — stable unless the user changes email.
  /// 3. Access-token-based (v1) — legacy, session-dependent fallback.
  ///
  /// Returns the CRK bytes if any method succeeds, null otherwise.
  Future<Uint8List?> _recoverAuthEncryptedCrk(
    String userId,
    String userChatKeyId,
  ) async {
    try {
      final supabase = Supabase.instance.client;
      final session = supabase.auth.currentSession;
      if (session == null) return null;

      // Fetch encrypted CRK from database
      final data = await supabase
          .from('user_chat_crk_wrappers')
          .select()
          .eq('user_id', userId)
          .eq('user_chat_key_id', userChatKeyId)
          .maybeSingle();

      if (data == null) return null;

      final salt = base64Decode(data['kdf_salt'] as String);
      final nonce = base64Decode(data['wrap_nonce'] as String);
      final encryptedCrk = base64Decode(data['encrypted_crk'] as String);
      final aad = Uint8List.fromList(utf8.encode('chat-crk-auth-wrap'));

      // Method 1: user-ID-based (immutable — survives email changes, session changes)
      try {
        final idWrapKey = await _crypto.hkdfDeriveBytes(
          inputKeyMaterial: Uint8List.fromList(utf8.encode(userId)),
          salt: salt,
          info: 'matchme-auth-crk-wrap-v3',
        );
        final crkBytes = await _crypto.aesGcmDecrypt(
          ciphertext: encryptedCrk,
          key: idWrapKey,
          nonce: nonce,
          aad: aad,
        );
        return crkBytes;
      } catch (_) {
        // UID derivation failed — try next method
      }

      // Method 2: email-based (stable across sessions, breaks on email change)
      final user = supabase.auth.currentUser;
      if (user != null) {
        final identity = user.email;
        if (identity != null && identity.isNotEmpty) {
          try {
            final emailWrapKey = await _crypto.hkdfDeriveBytes(
              inputKeyMaterial: Uint8List.fromList(utf8.encode(identity)),
              salt: salt,
              info: 'matchme-auth-crk-wrap-v2',
            );
            final crkBytes = await _crypto.aesGcmDecrypt(
              ciphertext: encryptedCrk,
              key: emailWrapKey,
              nonce: nonce,
              aad: aad,
            );
            return crkBytes;
          } catch (_) {
            // Email derivation failed — fall through to legacy method
          }
        }
      }

      // Method 3: access-token-based (legacy, session-dependent)
      try {
        final tokenWrapKey = await _crypto.hkdfDeriveBytes(
          inputKeyMaterial: Uint8List.fromList(
            utf8.encode('$userId:${session.accessToken}'),
          ),
          salt: salt,
          info: 'matchme-auth-crk-wrap-v1',
        );
        final crkBytes = await _crypto.aesGcmDecrypt(
          ciphertext: encryptedCrk,
          key: tokenWrapKey,
          nonce: nonce,
          aad: aad,
        );
        return crkBytes;
      } catch (_) {
        return null;
      }
    } catch (_) {
      return null;
    }
  }

  /// Stores the private chat key encrypted with a key derived from the user's
  /// UUID (immutable). This is the primary auto-heal path on web: if local
  /// storage is lost, the private key can still be recovered after login
  /// without any user interaction and without rotating the key.
  ///
  /// SECURITY NOTE: userId is low-entropy/public (visible in `users` table),
  /// so this wrapper is RECOVERABILITY, not a second factor. Anyone with DB
  /// read + the stored salt/nonce can re-derive the wrap key. It is safe to
  /// keep because RLS restricts `user_chat_key_wrappers` to the owner, but a
  /// DB leak would expose it. The password (PBKDF2 600k) and CRK recovery
  /// wrappers remain the strong recovery paths; this one is convenience only.
  /// Do not rely on it for threat models that include server-side read.
  ///
  /// Failure of this method is treated as fatal in `setupEncryption` — losing
  /// this backup would force the user to go through the manual recovery flow,
  /// which is exactly what the auto-heal is meant to prevent.
  Future<void> _storeAuthEncryptedPrivateKey(
    String userId,
    String userChatKeyId,
    Uint8List privateKeyBytes,
  ) async {
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user == null) return;

    final salt = _crypto.generateRandomBytesSync(
      SecurityConstants.pbkdf2SaltLength,
    );
    final authWrapKey = await _crypto.hkdfDeriveBytes(
      inputKeyMaterial: Uint8List.fromList(utf8.encode(userId)),
      salt: salt,
      info: 'matchme-auth-private-key-wrap-v1',
    );

    final nonce = _crypto.generateNonce();
    final aad = Uint8List.fromList(utf8.encode('chat-private-key-auth-wrap'));
    final encryptedPrivateKey = await _crypto.aesGcmEncrypt(
      plaintext: privateKeyBytes,
      key: authWrapKey,
      nonce: nonce,
      aad: aad,
    );

    // Use the existing user_chat_key_wrappers RPC so the wrapper_type CHECK
    // constraint is enforced server-side and any pre-existing auth_crk/
    // recovery_key wrappers are preserved.
    await supabase.rpc(
      'create_or_replace_chat_key_wrapper',
      params: {
        'p_user_chat_key_id': userChatKeyId,
        'p_wrapper_type': 'auth_private_key',
        'p_kdf': 'HKDF-SHA256-UID',
        'p_kdf_iterations': null,
        'p_kdf_salt': base64Encode(salt),
        'p_wrap_alg': 'AES-256-GCM',
        'p_wrap_nonce': base64Encode(nonce),
        'p_encrypted_private_key': base64Encode(encryptedPrivateKey),
      },
    );
  }

  /// Recovers the private chat key from the server-side `auth_private_key`
  /// wrapper using the user's UUID as key material. Returns the private key
  /// bytes if successful, null otherwise. Single-step recovery — does not
  /// depend on the CRK wrapper or any local state.
  Future<Uint8List?> _recoverAuthEncryptedPrivateKey(
    String userId,
    String userChatKeyId,
  ) async {
    try {
      final wrapper = await fetchWrapperByType(
        userChatKeyId,
        'auth_private_key',
      );
      if (wrapper == null) return null;

      final salt = base64Decode(wrapper.kdfSaltBase64);
      final nonce = base64Decode(wrapper.wrapNonceBase64);
      final encryptedPrivateKey = base64Decode(
        wrapper.encryptedPrivateKeyBase64,
      );
      final aad = Uint8List.fromList(utf8.encode('chat-private-key-auth-wrap'));

      final wrapKey = await _crypto.hkdfDeriveBytes(
        inputKeyMaterial: Uint8List.fromList(utf8.encode(userId)),
        salt: salt,
        info: 'matchme-auth-private-key-wrap-v1',
      );

      return await _crypto.aesGcmDecrypt(
        ciphertext: encryptedPrivateKey,
        key: wrapKey,
        nonce: nonce,
        aad: aad,
      );
    } catch (_) {
      return null;
    }
  }

  /// Ensures an `auth_private_key` wrapper exists in the database for the
  /// current private key. Call this after any successful unlock so the
  /// server-side backup is always present and current.
  Future<void> ensureAuthEncryptedPrivateKeyExists(
    String userId,
    String userChatKeyId,
    Uint8List privateKeyBytes,
  ) async {
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user == null) return;

    final existing = await fetchWrapperByType(
      userChatKeyId,
      'auth_private_key',
    );
    if (existing != null) return;

    await _storeAuthEncryptedPrivateKey(userId, userChatKeyId, privateKeyBytes);
  }

  /// Ensures that a CRK wrapper exists in the database for automatic recovery,
  /// using the user's UUID (immutable) as key material.
  ///
  /// If a wrapper already exists with a legacy `kdf` (email-based or
  /// access-token-based), it is replaced with the UUID-based derivation so
  /// the CRK remains recoverable after any session or email change on web.
  /// This should be called after successful unlock to enable future automatic recovery.
  Future<void> ensureAuthCrkWrapperExists(
    String userId,
    String userChatKeyId,
    Uint8List crkBytes,
  ) async {
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user == null) return;

    // Check if wrapper already exists with the current (UID-based) kdf
    final existing = await supabase
        .from('user_chat_crk_wrappers')
        .select('kdf')
        .eq('user_id', userId)
        .eq('user_chat_key_id', userChatKeyId)
        .maybeSingle();

    if (existing != null && existing['kdf'] == 'HKDF-SHA256-UID') {
      // Already using UUID-based derivation — nothing to do
      return;
    }

    final salt = _crypto.generateRandomBytesSync(
      SecurityConstants.pbkdf2SaltLength,
    );
    final authWrapKey = await _crypto.hkdfDeriveBytes(
      inputKeyMaterial: Uint8List.fromList(utf8.encode(userId)),
      salt: salt,
      info: 'matchme-auth-crk-wrap-v3',
    );

    final nonce = _crypto.generateNonce();
    final aad = Uint8List.fromList(utf8.encode('chat-crk-auth-wrap'));
    final encryptedCrk = await _crypto.aesGcmEncrypt(
      plaintext: crkBytes,
      key: authWrapKey,
      nonce: nonce,
      aad: aad,
    );

    // Upsert so legacy wrappers get upgraded to UUID-based derivation
    await supabase.from('user_chat_crk_wrappers').upsert({
      'user_id': userId,
      'user_chat_key_id': userChatKeyId,
      'kdf': 'HKDF-SHA256-UID',
      'kdf_salt': base64Encode(salt),
      'wrap_alg': 'AES-256-GCM',
      'wrap_nonce': base64Encode(nonce),
      'encrypted_crk': base64Encode(encryptedCrk),
    }, onConflict: 'user_id,user_chat_key_id');
  }

  Future<void> createPasswordWrapper({
    required String userId,
    required String userChatKeyId,
    required Uint8List privateKeyBytes,
    required String password,
  }) async {
    final passwordBytes = Uint8List.fromList(utf8.encode(password));
    final salt = _crypto.generateRandomBytesSync(
      SecurityConstants.pbkdf2SaltLength,
    );
    final passwordWrapKey = await _crypto.pbkdf2DeriveBytes(
      password: passwordBytes,
      salt: salt,
      iterations: SecurityConstants.pbkdf2Iterations,
    );
    final wrapNonce = _crypto.generateNonce();
    final aad = Uint8List.fromList(utf8.encode('chat-private-key-password'));
    final encryptedPrivateKey = await _crypto.aesGcmEncrypt(
      plaintext: privateKeyBytes,
      key: passwordWrapKey,
      nonce: wrapNonce,
      aad: aad,
    );

    final supabase = Supabase.instance.client;
    await supabase.rpc(
      'create_or_replace_chat_key_wrapper',
      params: {
        'p_user_chat_key_id': userChatKeyId,
        'p_wrapper_type': 'password',
        'p_kdf': 'PBKDF2-HMAC-SHA256',
        'p_kdf_iterations': SecurityConstants.pbkdf2Iterations,
        'p_kdf_salt': base64Encode(salt),
        'p_wrap_alg': 'AES-256-GCM',
        'p_wrap_nonce': base64Encode(wrapNonce),
        'p_encrypted_private_key': base64Encode(encryptedPrivateKey),
      },
    );
  }

  Future<Uint8List?> unlockWithPassword({
    required String userId,
    required String userChatKeyId,
    required String password,
  }) async {
    final wrapper = await fetchWrapperByType(userChatKeyId, 'password');
    if (wrapper == null) return null;

    final salt = base64Decode(wrapper.kdfSaltBase64);
    final passwordBytes = Uint8List.fromList(utf8.encode(password));
    final iterations =
        wrapper.kdfIterations ?? SecurityConstants.pbkdf2Iterations;
    final passwordWrapKey = await _crypto.pbkdf2DeriveBytes(
      password: passwordBytes,
      salt: salt,
      iterations: iterations,
    );

    final nonce = base64Decode(wrapper.wrapNonceBase64);
    final encryptedPrivateKey = base64Decode(wrapper.encryptedPrivateKeyBase64);
    final aad = Uint8List.fromList(utf8.encode('chat-private-key-password'));

    try {
      final privateKey = await _crypto.aesGcmDecrypt(
        ciphertext: encryptedPrivateKey,
        key: passwordWrapKey,
        nonce: nonce,
        aad: aad,
      );
      await storePrivateKeyBytes(userId, privateKey);
      await storeActiveKeyIdLocally(userId, userChatKeyId);
      return privateKey;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> unlockWithCrk({
    required String userId,
    required String userChatKeyId,
    required Uint8List crkBytes,
  }) async {
    final wrapper = await fetchWrapperByType(userChatKeyId, 'recovery_key');
    if (wrapper == null) return null;

    final salt = base64Decode(wrapper.kdfSaltBase64);
    final recoveryWrapKey = await _crypto.hkdfDeriveBytes(
      inputKeyMaterial: crkBytes,
      salt: salt,
      info: SecurityConstants.crkInfoLabel,
    );

    final nonce = base64Decode(wrapper.wrapNonceBase64);
    final encryptedPrivateKey = base64Decode(wrapper.encryptedPrivateKeyBase64);
    final aad = Uint8List.fromList(utf8.encode('chat-private-key-recovery'));

    try {
      final privateKey = await _crypto.aesGcmDecrypt(
        ciphertext: encryptedPrivateKey,
        key: recoveryWrapKey,
        nonce: nonce,
        aad: aad,
      );
      await storePrivateKeyBytes(userId, privateKey);
      await storeActiveKeyIdLocally(userId, userChatKeyId);
      await storeCrkBytes(userId, crkBytes);
      return privateKey;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> unlockAfterPasswordAuth(
    String userId,
    String password,
  ) async {
    final activeKey = await fetchActiveKey(userId);
    if (activeKey == null) return null;

    if (await hasPrivateKeyLocally(userId)) {
      return loadPrivateKeyBytes(userId);
    }

    return unlockWithPassword(
      userId: userId,
      userChatKeyId: activeKey.id,
      password: password,
    );
  }

  Future<Uint8List> ensurePrivateKeyUnlocked(String userId) async {
    final localKey = await loadPrivateKeyBytes(userId);
    if (localKey != null) return localKey;

    final activeKey = await fetchActiveKey(userId);
    if (activeKey == null) {
      throw Exception('No active chat key found');
    }

    throw Exception('Private key not unlocked locally');
  }

  Future<void> replaceRecoveryKey({
    required String userId,
    required String userChatKeyId,
    required Uint8List privateKeyBytes,
    required Uint8List newCrkBytes,
  }) async {
    final recoverySalt = _crypto.generateRandomBytesSync(
      SecurityConstants.pbkdf2SaltLength,
    );
    final recoveryWrapKey = await _crypto.hkdfDeriveBytes(
      inputKeyMaterial: newCrkBytes,
      salt: recoverySalt,
      info: SecurityConstants.crkInfoLabel,
    );
    final recoveryNonce = _crypto.generateNonce();
    final aad = Uint8List.fromList(utf8.encode('chat-private-key-recovery'));
    final encryptedPrivateKey = await _crypto.aesGcmEncrypt(
      plaintext: privateKeyBytes,
      key: recoveryWrapKey,
      nonce: recoveryNonce,
      aad: aad,
    );

    final supabase = Supabase.instance.client;
    await supabase.rpc(
      'create_or_replace_chat_key_wrapper',
      params: {
        'p_user_chat_key_id': userChatKeyId,
        'p_wrapper_type': 'recovery_key',
        'p_kdf': 'HKDF-SHA256',
        'p_kdf_salt': base64Encode(recoverySalt),
        'p_wrap_alg': 'AES-256-GCM',
        'p_wrap_nonce': base64Encode(recoveryNonce),
        'p_encrypted_private_key': base64Encode(encryptedPrivateKey),
      },
    );

    await storeCrkBytes(userId, newCrkBytes);
  }

  Future<void> replacePasswordWrapper({
    required String userId,
    required String userChatKeyId,
    required Uint8List privateKeyBytes,
    required String newPassword,
  }) async {
    await createPasswordWrapper(
      userId: userId,
      userChatKeyId: userChatKeyId,
      privateKeyBytes: privateKeyBytes,
      password: newPassword,
    );
  }

  /// Attempts to automatically recover the CRK from the database using the user's auth session.
  /// Returns the CRK bytes if successful, null otherwise.
  Future<Uint8List?> attemptAutoRecoverCrk(
    String userId,
    String userChatKeyId,
  ) async {
    return _recoverAuthEncryptedCrk(userId, userChatKeyId);
  }

  /// Attempts to auto-heal the private key from the server-side
  /// `auth_private_key` wrapper using the user's UUID as key material. This
  /// is the primary recovery path on web, where FlutterSecureStorage is not
  /// durable. Returns the private key bytes if successful, null otherwise.
  Future<Uint8List?> attemptAutoRecoverAuthPrivateKey(
    String userId,
    String userChatKeyId,
  ) async {
    return _recoverAuthEncryptedPrivateKey(userId, userChatKeyId);
  }

  /// True when no chat message references [keyId] as its sender or recipient
  /// key — i.e. rotating the key would destroy nothing. Conservative: any
  /// failure to check (offline, RLS, error) returns false.
  Future<bool> canSafelyReplaceLostKey(String keyId) async {
    if (shouldSkipSupabaseCalls()) return false;
    try {
      final supabase = Supabase.instance.client;
      final refs = await supabase
          .from('chat_messages')
          .select('id')
          .or('sender_key_id.eq.$keyId,recipient_key_id.eq.$keyId')
          .limit(1);
      return refs.isEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<UserChatKeyModel> replaceLostChatKey({
    required String userId,
    required String lostKeyId,
    String? reauthToken,
  }) async {
    final keyPair = await _crypto.generateX25519KeyPair();
    final privateKeyBytes = await _crypto.privateKeyToBytes(keyPair);
    final publicKeyBytes = await _crypto.publicKeyToBytes(keyPair);
    final publicKeyBase64 = _crypto.publicKeyToBase64(publicKeyBytes);
    final crkBytes = await _crypto.generateRandomBytes(
      SecurityConstants.crkByteLength,
    );

    final supabase = Supabase.instance.client;
    final result = await supabase.rpc(
      'replace_lost_chat_key',
      params: {
        'p_lost_key_id': lostKeyId,
        'p_new_public_key': publicKeyBase64,
        'p_reauth_token': reauthToken,
      },
    );
    final newKeyId = result as String;

    final recoverySalt = _crypto.generateRandomBytesSync(
      SecurityConstants.pbkdf2SaltLength,
    );
    final recoveryWrapKey = await _crypto.hkdfDeriveBytes(
      inputKeyMaterial: crkBytes,
      salt: recoverySalt,
      info: SecurityConstants.crkInfoLabel,
    );
    final recoveryNonce = _crypto.generateNonce();
    final aad = Uint8List.fromList(utf8.encode('chat-private-key-recovery'));
    final encryptedPrivateKey = await _crypto.aesGcmEncrypt(
      plaintext: privateKeyBytes,
      key: recoveryWrapKey,
      nonce: recoveryNonce,
      aad: aad,
    );

    await supabase.from('user_chat_key_wrappers').insert({
      'user_chat_key_id': newKeyId,
      'user_id': userId,
      'wrapper_type': 'recovery_key',
      'kdf': 'HKDF-SHA256',
      'kdf_salt': base64Encode(recoverySalt),
      'wrap_alg': 'AES-256-GCM',
      'wrap_nonce': base64Encode(recoveryNonce),
      'encrypted_private_key': base64Encode(encryptedPrivateKey),
    });

    await storePrivateKeyBytes(userId, privateKeyBytes);
    await storeActiveKeyIdLocally(userId, newKeyId);
    await storeCrkBytes(userId, crkBytes);

    // Backfill the server-side auto-heal backups immediately so the new key
    // is recoverable on ANY device from day one, even if this device never
    // boots again.
    await _storeAuthEncryptedPrivateKey(userId, newKeyId, privateKeyBytes);
    try {
      await _storeAuthEncryptedCrk(userId, newKeyId, crkBytes);
    } catch (_) {
      // Non-fatal: auth_private_key wrapper and local storage are sufficient
    }

    return UserChatKeyModel(
      id: newKeyId,
      userId: userId,
      keyVersion: 0,
      publicKeyBase64: publicKeyBase64,
      status: 'active',
      createdAt: DateTime.now(),
      activatedAt: DateTime.now(),
    );
  }
}

/// Clears the decrypted-content cache when the app leaves the foreground so
/// plaintext message content is not held in memory while the device is locked
/// or the app is backgrounded.
class _ChatKeyLifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      ChatKeyService.instance.clearMemoryCaches();
    }
  }
}
