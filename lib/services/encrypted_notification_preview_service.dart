import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:matchme/services/chat_key_service.dart';
import 'package:matchme/services/crypto_service.dart';
import 'package:matchme/services/secure_storage_service.dart';
import 'package:matchme/config/security_constants.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class EncryptedNotificationPreviewService {
  EncryptedNotificationPreviewService._();
  static final EncryptedNotificationPreviewService instance =
      EncryptedNotificationPreviewService._();

  final SecureStorageService _secureStorage = SecureStorageService.instance;
  static const _previewEnabledPrefix = 'notification_preview_enabled:';

  // Provider container (same pattern as MobileLocalNotificationService). When
  // present, the preview preference is owned by userPreferencesProvider so it
  // is persisted locally, synced to the server, and honored by the native
  // Android service. The SecureStorage key is kept only as a legacy fallback
  // and for the one-time migration performed by the provider.
  static ProviderContainer? _container;
  static void setProviderContainer(ProviderContainer container) {
    _container = container;
  }

  final ChatKeyService _chatKeyService = ChatKeyService.instance;
  final CryptoService _crypto = CryptoService.instance;

  Future<bool> isPreviewEnabled(String userId) async {
    final container = _container;
    if (container != null) {
      return container
          .read(userPreferencesProvider)
          .notifications
          .messagePreviews;
    }
    final val = await _secureStorage.read('$_previewEnabledPrefix$userId');
    // Default to true so notifications show message content unless user opts out
    return val != 'false';
  }

  Future<void> setPreviewEnabled(String userId, bool enabled) async {
    final container = _container;
    if (container != null) {
      await container
          .read(userPreferencesProvider.notifier)
          .setMessagePreviews(enabled);
    }
    // Mirror to the legacy key so the non-wired fallback path stays coherent.
    await _secureStorage.write(
      '$_previewEnabledPrefix$userId',
      enabled ? 'true' : 'false',
    );
  }

  Future<String?> decryptPreview({
    required String messageId,
    required String matchId,
    required String senderId,
    required String recipientId,
    required String senderKeyId,
    required String recipientKeyId,
    required String contentOriginalEncryptedBase64,
    required String contentOriginalNonceBase64,
    required String wrappedKeysJson,
    String? translatedEncryptedBase64,
    String? translatedNonceBase64,
    // When both are provided, the ciphertext/nonce are treated as translated
    // content and decrypted with the translated AAD (which includes source
    // and target languages) instead of the original AAD.
    String? detectedSourceLanguage,
    String? targetLanguage,
  }) async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return null;

    final enabled = await isPreviewEnabled(userId);
    if (!enabled) return null;

    try {
      final wrappedKeys = jsonDecode(wrappedKeysJson) as Map<String, dynamic>;
      final recipientWrap = wrappedKeys['recipient'];
      if (recipientWrap == null) return null;
      final recipientWrapMap = recipientWrap as Map<String, dynamic>;

      final senderKey = await _chatKeyService.fetchPeerPublicKey(senderKeyId);
      if (senderKey == null) return null;

      final senderPublicKey = _crypto.base64ToPublicKey(
        senderKey.publicKeyBase64,
      );

      // Try current private key first, then fall back to archived key
      Future<String?> tryDecrypt(Uint8List pk) async {
        try {
          final sharedSecret = await _crypto.x25519SharedSecretFromPrivateKey(
            myPrivateKey: pk,
            theirPublicKey: senderPublicKey,
          );

          final messageIdBytes = Uint8List.fromList(utf8.encode(messageId));
          final wrapKey = await _crypto.hkdfDeriveBytes(
            inputKeyMaterial: sharedSecret,
            salt: messageIdBytes,
            info: SecurityConstants.recipientWrapInfoLabel,
          );

          final wrapNonce = base64Decode(recipientWrapMap['nonce'] as String);
          final wrapCiphertext = base64Decode(
            recipientWrapMap['ciphertext'] as String,
          );
          final wrapAad = _crypto.buildWrapAad(
            purpose: 'recipient',
            messageId: messageId,
            senderKeyId: senderKeyId,
            recipientOrSupabaseKeyId: recipientKeyId,
          );

          final messageKey = await _crypto.unwrapMessageKey(
            wrappedKey: wrapCiphertext,
            wrapKey: wrapKey,
            nonce: wrapNonce,
            aad: wrapAad,
          );

          final contentNonce = base64Decode(contentOriginalNonceBase64);
          final contentCiphertext = base64Decode(
            contentOriginalEncryptedBase64,
          );

          final Uint8List plaintext;
          if (detectedSourceLanguage != null && targetLanguage != null) {
            plaintext = await _crypto.decryptTranslated(
              ciphertext: contentCiphertext,
              messageKey: messageKey,
              nonce: contentNonce,
              messageId: messageId,
              matchId: matchId,
              senderId: senderId,
              recipientId: recipientId,
              detectedSourceLanguage: detectedSourceLanguage,
              targetLanguage: targetLanguage,
              senderKeyId: senderKeyId,
              recipientKeyId: recipientKeyId,
            );
          } else {
            plaintext = await _crypto.decryptOriginal(
              ciphertext: contentCiphertext,
              messageKey: messageKey,
              nonce: contentNonce,
              messageId: messageId,
              matchId: matchId,
              senderId: senderId,
              recipientId: recipientId,
              senderKeyId: senderKeyId,
              recipientKeyId: recipientKeyId,
            );
          }

          return utf8.decode(plaintext);
        } catch (_) {
          return null;
        }
      }

      // Try with current key first
      final currentKey = await _chatKeyService.loadPrivateKeyBytes(userId);
      if (currentKey != null) {
        final result = await tryDecrypt(currentKey);
        if (result != null) return result;
      }

      // Fallback: try archived key for the recipient's key ID
      final archivedKey = await _chatKeyService.loadPrivateKeyBytesByKeyId(
        userId,
        recipientKeyId,
      );
      if (archivedKey != null) {
        final result = await tryDecrypt(archivedKey);
        if (result != null) return result;
      }

      return null;
    } catch (e) {
      debugPrint('[EncryptedNotificationPreview] Decryption failed: $e');
      return null;
    }
  }
}
