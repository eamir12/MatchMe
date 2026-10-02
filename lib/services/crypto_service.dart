import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:matchme/config/security_constants.dart';

class CryptoService {
  CryptoService._();
  static final CryptoService instance = CryptoService._();

  final crypto.AesGcm _aesGcm = crypto.AesGcm.with256bits();
  final crypto.X25519 _x25519 = crypto.X25519();

  Future<crypto.SecretKey> _secretKeyFromBytes(Uint8List bytes) async {
    return crypto.SecretKey(bytes);
  }

  Future<Uint8List> hkdfDeriveBytes({
    required Uint8List inputKeyMaterial,
    required Uint8List salt,
    required String info,
    int outputLength = SecurityConstants.hkdfOutputLength,
  }) async {
    final hkdf = crypto.Hkdf(
      hmac: crypto.Hmac.sha256(),
      outputLength: outputLength,
    );
    final key = await hkdf.deriveKey(
      secretKey: crypto.SecretKey(inputKeyMaterial),
      nonce: salt,
      info: Uint8List.fromList(utf8.encode(info)),
    );
    final bytes = await key.extractBytes();
    return Uint8List.fromList(bytes);
  }

  Future<Uint8List> pbkdf2DeriveBytes({
    required Uint8List password,
    required Uint8List salt,
    int iterations = SecurityConstants.pbkdf2Iterations,
    int outputLength = SecurityConstants.hkdfOutputLength,
  }) async {
    final pbkdf2 = crypto.Pbkdf2.hmacSha256(
      iterations: iterations,
      bits: outputLength * 8,
    );
    final key = await pbkdf2.deriveKey(
      secretKey: crypto.SecretKey(password),
      nonce: salt,
    );
    final bytes = await key.extractBytes();
    return Uint8List.fromList(bytes);
  }

  Future<crypto.SimpleKeyPair> generateX25519KeyPair() async {
    return _x25519.newKeyPair();
  }

  Future<Uint8List> x25519SharedSecret({
    required crypto.SimpleKeyPair myKeyPair,
    required Uint8List theirPublicKey,
  }) async {
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: crypto.SimplePublicKey(
        theirPublicKey,
        type: crypto.KeyPairType.x25519,
      ),
    );
    final bytes = await sharedSecret.extractBytes();
    return Uint8List.fromList(bytes);
  }

  Future<Uint8List> x25519SharedSecretFromPrivateKey({
    required Uint8List myPrivateKey,
    required Uint8List theirPublicKey,
  }) async {
    final pubKey = crypto.SimplePublicKey(
      theirPublicKey,
      type: crypto.KeyPairType.x25519,
    );
    final kp = await _x25519.newKeyPairFromSeed(myPrivateKey);
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: kp,
      remotePublicKey: pubKey,
    );
    final bytes = await sharedSecret.extractBytes();
    return Uint8List.fromList(bytes);
  }

  /// Creates an X25519 key pair from a raw private key seed.
  /// Returns a [crypto.SimpleKeyPair] whose public key can be extracted
  /// with [publicKeyToBytes]. Used for stale-key detection: derive the
  /// public key from the local private key and compare with the server's
  /// stored active key public key.
  Future<crypto.SimpleKeyPair> newKeyPairFromSeed(Uint8List seed) async {
    return _x25519.newKeyPairFromSeed(seed);
  }

  Future<Uint8List> aesGcmEncrypt({
    required Uint8List plaintext,
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List aad,
  }) async {
    final secretKey = await _secretKeyFromBytes(key);
    final result = await _aesGcm.encrypt(
      plaintext,
      secretKey: secretKey,
      nonce: nonce,
      aad: aad,
    );
    final ctLen = result.cipherText.length;
    final macLen = result.mac.bytes.length;
    final combined = Uint8List(ctLen + macLen)
      ..setRange(0, ctLen, result.cipherText)
      ..setRange(ctLen, ctLen + macLen, result.mac.bytes);
    return combined;
  }

  Future<Uint8List> aesGcmDecrypt({
    required Uint8List ciphertext,
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List aad,
    Uint8List? mac,
  }) async {
    final secretKey = await _secretKeyFromBytes(key);
    final actualMac = mac ?? ciphertext.sublist(ciphertext.length - 16);
    final actualCiphertext = mac != null
        ? ciphertext
        : ciphertext.sublist(0, ciphertext.length - 16);
    final result = await _aesGcm.decrypt(
      crypto.SecretBox(
        actualCiphertext,
        nonce: nonce,
        mac: crypto.Mac(actualMac),
      ),
      secretKey: secretKey,
      aad: aad,
    );
    return Uint8List.fromList(result);
  }

  Future<Uint8List> generateRandomBytes(int length) async {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  Uint8List generateRandomBytesSync(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  Future<Uint8List> generateMessageKey() async {
    return generateRandomBytes(SecurityConstants.messageKeyLength);
  }

  Uint8List generateNonce() {
    return generateRandomBytesSync(SecurityConstants.aesGcmNonceLength);
  }

  String publicKeyToBase64(Uint8List publicKey) {
    return base64Encode(publicKey);
  }

  Uint8List base64ToPublicKey(String base64Str) {
    return base64Decode(base64Str);
  }

  Future<Uint8List> privateKeyToBytes(crypto.SimpleKeyPair keyPair) async {
    final bytes = await keyPair.extractPrivateKeyBytes();
    return Uint8List.fromList(bytes);
  }

  Future<Uint8List> publicKeyToBytes(crypto.SimpleKeyPair keyPair) async {
    final pubKey = await keyPair.extractPublicKey();
    return Uint8List.fromList(pubKey.bytes);
  }

  int crkChecksum(Uint8List crkBytes) {
    var crc = SecurityConstants.crkCrcInitial;
    final data = Uint8List(SecurityConstants.crkByteLength + 1)
      ..[0] = SecurityConstants.crkVersionByte
      ..setRange(1, SecurityConstants.crkByteLength + 1, crkBytes);
    for (final b in data) {
      crc ^= (b << 8);
      for (var i = 0; i < 8; i++) {
        final highBitSet = (crc & 0x8000) != 0;
        crc = ((crc << 1) & 0xFFFF);
        if (highBitSet) crc ^= SecurityConstants.crkCrcPolynomial;
      }
    }
    return crc & 0xFFFF;
  }

  static const String _crockfordAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  String _crockfordBase32Encode(Uint8List bytes) {
    final result = StringBuffer();
    var buffer = 0;
    var bitsInBuffer = 0;
    for (final b in bytes) {
      buffer = (buffer << 8) | b;
      bitsInBuffer += 8;
      while (bitsInBuffer >= 5) {
        bitsInBuffer -= 5;
        result.write(_crockfordAlphabet[(buffer >> bitsInBuffer) & 0x1F]);
      }
    }
    if (bitsInBuffer > 0) {
      result.write(_crockfordAlphabet[(buffer << (5 - bitsInBuffer)) & 0x1F]);
    }
    return result.toString();
  }

  Uint8List _crockfordBase32Decode(String encoded) {
    final cleaned = encoded
        .replaceAll('-', '')
        .replaceAll(' ', '')
        .toUpperCase()
        .replaceAll('O', '0')
        .replaceAll('I', '1')
        .replaceAll('L', '1');
    final output = <int>[];
    var buffer = 0;
    var bitsInBuffer = 0;
    for (final c in cleaned.runes) {
      final char = String.fromCharCode(c);
      final idx = _crockfordAlphabet.indexOf(char);
      if (idx < 0) continue;
      buffer = (buffer << 5) | idx;
      bitsInBuffer += 5;
      if (bitsInBuffer >= 8) {
        bitsInBuffer -= 8;
        output.add((buffer >> bitsInBuffer) & 0xFF);
      }
    }
    return Uint8List.fromList(output);
  }

  String encodeCrk(Uint8List crkBytes) {
    final checksum = crkChecksum(crkBytes);
    final checksumBytes = Uint8List(2)
      ..[0] = (checksum >> 8) & 0xFF
      ..[1] = checksum & 0xFF;
    final payloadWithChecksum = Uint8List(SecurityConstants.crkByteLength + 2)
      ..setRange(0, SecurityConstants.crkByteLength, crkBytes)
      ..setRange(
        SecurityConstants.crkByteLength,
        SecurityConstants.crkByteLength + 2,
        checksumBytes,
      );
    final encoded = _crockfordBase32Encode(payloadWithChecksum);
    final groups = <String>[];
    for (var i = 0; i < encoded.length; i += 4) {
      groups.add(
        encoded.substring(i, i + 4 > encoded.length ? encoded.length : i + 4),
      );
    }
    return 'MMRK1-${groups.join('-')}';
  }

  Uint8List? decodeCrk(String formatted) {
    try {
      final cleaned = formatted
          .replaceAll('MMRK1-', '')
          .replaceAll('MMRK1', '')
          .replaceAll('-', '')
          .trim();
      if (cleaned.length < 4) return null;
      final payloadPart = cleaned.substring(0, cleaned.length - 4);
      final payloadBytes = _crockfordBase32Decode(payloadPart);
      if (payloadBytes.length != SecurityConstants.crkByteLength + 2) {
        return null;
      }
      final crkBytes = payloadBytes.sublist(0, SecurityConstants.crkByteLength);
      final expectedChecksumBytes = payloadBytes.sublist(
        SecurityConstants.crkByteLength,
      );
      final expectedChecksum =
          (expectedChecksumBytes[0] << 8) | expectedChecksumBytes[1];
      final actualChecksum = crkChecksum(crkBytes);
      if (actualChecksum != expectedChecksum) return null;
      return crkBytes;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> wrapMessageKey({
    required Uint8List messageKey,
    required Uint8List wrapKey,
    required Uint8List nonce,
    required Uint8List aad,
  }) async {
    return aesGcmEncrypt(
      plaintext: messageKey,
      key: wrapKey,
      nonce: nonce,
      aad: aad,
    );
  }

  Future<Uint8List> unwrapMessageKey({
    required Uint8List wrappedKey,
    required Uint8List wrapKey,
    required Uint8List nonce,
    required Uint8List aad,
  }) async {
    return aesGcmDecrypt(
      ciphertext: wrappedKey,
      key: wrapKey,
      nonce: nonce,
      aad: aad,
    );
  }

  Uint8List buildOriginalAad({
    required String messageId,
    required String matchId,
    required String senderId,
    required String recipientId,
    required String senderKeyId,
    required String recipientKeyId,
  }) {
    final aad =
        '${SecurityConstants.messageOriginalAadPrefix}|$messageId|$matchId|$senderId|$recipientId|$senderKeyId|$recipientKeyId';
    return Uint8List.fromList(utf8.encode(aad));
  }

  Uint8List buildTranslatedAad({
    required String messageId,
    required String matchId,
    required String senderId,
    required String recipientId,
    required String detectedSourceLanguage,
    required String targetLanguage,
    required String senderKeyId,
    required String recipientKeyId,
  }) {
    final aad =
        '${SecurityConstants.messageTranslatedAadPrefix}|$messageId|$matchId|$senderId|$recipientId|$detectedSourceLanguage|$targetLanguage|$senderKeyId|$recipientKeyId';
    return Uint8List.fromList(utf8.encode(aad));
  }

  Uint8List buildWrapAad({
    required String purpose,
    required String messageId,
    required String senderKeyId,
    required String recipientOrSupabaseKeyId,
  }) {
    final aad =
        '${SecurityConstants.wrapAadPrefix}|$purpose|$messageId|$senderKeyId|$recipientOrSupabaseKeyId';
    return Uint8List.fromList(utf8.encode(aad));
  }

  Uint8List buildClientAssistedRequestAad({
    required String messageId,
    required String matchId,
    required String currentUserId,
    required String targetLanguage,
    required String currentUserKeyId,
    required String supabaseKeyId,
  }) {
    final aad =
        '${SecurityConstants.clientAssistedRequestAadPrefix}|$messageId|$matchId|$currentUserId|$targetLanguage|$currentUserKeyId|$supabaseKeyId';
    return Uint8List.fromList(utf8.encode(aad));
  }

  Uint8List buildClientAssistedResponseAad({
    required String messageId,
    required String matchId,
    required String currentUserId,
    required String detectedSourceLanguage,
    required String targetLanguage,
    required String currentUserKeyId,
    required String supabaseKeyId,
  }) {
    final aad =
        '${SecurityConstants.clientAssistedResponseAadPrefix}|$messageId|$matchId|$currentUserId|$detectedSourceLanguage|$targetLanguage|$currentUserKeyId|$supabaseKeyId';
    return Uint8List.fromList(utf8.encode(aad));
  }

  String canonicalizeUuid(String uuid) {
    return uuid.toLowerCase();
  }

  String canonicalizeLanguage(String lang) {
    return lang.toLowerCase().trim();
  }

  Future<Uint8List> encryptOriginal({
    required Uint8List plaintext,
    required Uint8List messageKey,
    required Uint8List nonce,
    required String messageId,
    required String matchId,
    required String senderId,
    required String recipientId,
    required String senderKeyId,
    required String recipientKeyId,
  }) async {
    final aad = buildOriginalAad(
      messageId: messageId,
      matchId: matchId,
      senderId: senderId,
      recipientId: recipientId,
      senderKeyId: senderKeyId,
      recipientKeyId: recipientKeyId,
    );
    return aesGcmEncrypt(
      plaintext: plaintext,
      key: messageKey,
      nonce: nonce,
      aad: aad,
    );
  }

  Future<Uint8List> decryptOriginal({
    required Uint8List ciphertext,
    required Uint8List messageKey,
    required Uint8List nonce,
    required String messageId,
    required String matchId,
    required String senderId,
    required String recipientId,
    required String senderKeyId,
    required String recipientKeyId,
  }) async {
    final aad = buildOriginalAad(
      messageId: messageId,
      matchId: matchId,
      senderId: senderId,
      recipientId: recipientId,
      senderKeyId: senderKeyId,
      recipientKeyId: recipientKeyId,
    );
    return aesGcmDecrypt(
      ciphertext: ciphertext,
      key: messageKey,
      nonce: nonce,
      aad: aad,
    );
  }

  Future<Uint8List> encryptTranslated({
    required Uint8List plaintext,
    required Uint8List messageKey,
    required Uint8List nonce,
    required String messageId,
    required String matchId,
    required String senderId,
    required String recipientId,
    required String detectedSourceLanguage,
    required String targetLanguage,
    required String senderKeyId,
    required String recipientKeyId,
  }) async {
    final aad = buildTranslatedAad(
      messageId: messageId,
      matchId: matchId,
      senderId: senderId,
      recipientId: recipientId,
      detectedSourceLanguage: detectedSourceLanguage,
      targetLanguage: targetLanguage,
      senderKeyId: senderKeyId,
      recipientKeyId: recipientKeyId,
    );
    return aesGcmEncrypt(
      plaintext: plaintext,
      key: messageKey,
      nonce: nonce,
      aad: aad,
    );
  }

  Future<Uint8List> decryptTranslated({
    required Uint8List ciphertext,
    required Uint8List messageKey,
    required Uint8List nonce,
    required String messageId,
    required String matchId,
    required String senderId,
    required String recipientId,
    required String detectedSourceLanguage,
    required String targetLanguage,
    required String senderKeyId,
    required String recipientKeyId,
  }) async {
    final aad = buildTranslatedAad(
      messageId: messageId,
      matchId: matchId,
      senderId: senderId,
      recipientId: recipientId,
      detectedSourceLanguage: detectedSourceLanguage,
      targetLanguage: targetLanguage,
      senderKeyId: senderKeyId,
      recipientKeyId: recipientKeyId,
    );
    return aesGcmDecrypt(
      ciphertext: ciphertext,
      key: messageKey,
      nonce: nonce,
      aad: aad,
    );
  }
}
