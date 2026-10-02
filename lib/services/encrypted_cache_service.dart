import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:matchme/config/security_constants.dart';
import 'package:matchme/services/crypto_service.dart';
import 'package:matchme/services/secure_storage_service.dart';

class EncryptedCacheService {
  EncryptedCacheService._();
  static final EncryptedCacheService instance = EncryptedCacheService._();

  final SecureStorageService _secureStorage = SecureStorageService.instance;
  static const _dckPrefix = 'chat_cache_key:';

  final CryptoService _crypto = CryptoService.instance;
  String? _currentUserId;
  Uint8List? _currentDck;
  bool _initialized = false;

  Future<void> initialize(String userId) async {
    if (_initialized && _currentUserId == userId && _currentDck != null) {
      return;
    }
    _currentUserId = userId;
    _currentDck = await _loadDck(userId);
    if (_currentDck == null) {
      _currentDck = await _crypto.generateRandomBytes(
        SecurityConstants.messageKeyLength,
      );
      await _storeDck(userId, _currentDck!);
    }
    _initialized = true;
  }

  Future<void> resetForUser(String userId) async {
    _currentUserId = userId;
    await _secureStorage.delete('$_dckPrefix$userId');
    _currentDck = await _crypto.generateRandomBytes(
      SecurityConstants.messageKeyLength,
    );
    await _storeDck(userId, _currentDck!);
  }

  Future<Uint8List?> _loadDck(String userId) async {
    final encoded = await _secureStorage.read('$_dckPrefix$userId');
    if (encoded == null || encoded.isEmpty) return null;
    return base64Decode(encoded);
  }

  Future<void> _storeDck(String userId, Uint8List dck) async {
    await _secureStorage.write('$_dckPrefix$userId', base64Encode(dck));
  }

  Uint8List? get currentDck => _currentDck;

  /// Encrypt [plaintext] for the offline cache. Returns null (fail-closed)
  /// when no cache key is available instead of falling back to plaintext.
  Future<String?> encryptForCache(String plaintext) async {
    if (_currentDck == null) return null;
    final nonce = _crypto.generateNonce();
    final aad = Uint8List.fromList(utf8.encode('matchme-chat-cache-v1'));
    final ciphertext = await _crypto.aesGcmEncrypt(
      plaintext: Uint8List.fromList(utf8.encode(plaintext)),
      key: _currentDck!,
      nonce: nonce,
      aad: aad,
    );
    final combined = Uint8List(nonce.length + ciphertext.length)
      ..setRange(0, nonce.length, nonce)
      ..setRange(nonce.length, nonce.length + ciphertext.length, ciphertext);
    return base64Encode(combined);
  }

  /// Decrypt a cached value. Returns null (fail-closed) when no key is loaded
  /// or when a value that IS in encrypted form cannot be verified/decrypted.
  /// Values that are not in the encrypted format are treated as legacy
  /// plaintext from before encryption existed and returned as-is.
  Future<String?> decryptFromCache(String encrypted) async {
    if (_currentDck == null) return null;
    try {
      final combined = base64Decode(encrypted);
      if (combined.length < _nonceLength) {
        return encrypted;
      }
      final nonce = combined.sublist(0, _nonceLength);
      final ciphertext = combined.sublist(_nonceLength);
      final aad = Uint8List.fromList(utf8.encode('matchme-chat-cache-v1'));
      final plaintext = await _crypto.aesGcmDecrypt(
        ciphertext: ciphertext,
        key: _currentDck!,
        nonce: nonce,
        aad: aad,
      );
      return utf8.decode(plaintext);
    } catch (_) {
      return null;
    }
  }

  static const int _nonceLength = 12;

  Future<Map<String, dynamic>?> encryptMessageJson(
    Map<String, dynamic> messageJson,
  ) async {
    if (_currentDck == null) return null;
    try {
      final jsonStr = jsonEncode(messageJson);
      final encrypted = await encryptForCache(jsonStr);
      if (encrypted == null) return null;
      return {'encrypted_content': encrypted, 'is_encrypted': true};
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> decryptMessageJson(
    Map<String, dynamic> cached,
  ) async {
    if (cached['is_encrypted'] == true && cached['encrypted_content'] != null) {
      try {
        final decrypted = await decryptFromCache(
          cached['encrypted_content'] as String,
        );
        if (decrypted == null) return null;
        return jsonDecode(decrypted) as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
    }
    return cached;
  }
}
