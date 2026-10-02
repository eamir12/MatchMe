import 'dart:typed_data';

import 'package:matchme/config/security_constants.dart';
import 'package:matchme/services/crypto_service.dart';
import 'package:matchme/services/chat_key_service.dart';

class ChatRecoveryService {
  ChatRecoveryService._();
  static final ChatRecoveryService instance = ChatRecoveryService._();

  final CryptoService _crypto = CryptoService.instance;
  final ChatKeyService _chatKeyService = ChatKeyService.instance;

  Future<Uint8List> generateCrk() async {
    return _crypto.generateRandomBytes(SecurityConstants.crkByteLength);
  }

  String formatCrk(Uint8List crkBytes) {
    return _crypto.encodeCrk(crkBytes);
  }

  Uint8List? parseCrk(String formatted) {
    return _crypto.decodeCrk(formatted);
  }

  bool validateCrkChecksum(Uint8List crkBytes) {
    if (crkBytes.length != SecurityConstants.crkByteLength) return false;
    return true;
  }

  Future<void> saveCrkLocally(String userId, Uint8List crkBytes) async {
    await _chatKeyService.storeCrkBytes(userId, crkBytes);
  }

  Future<Uint8List?> loadCrkLocally(String userId) async {
    return _chatKeyService.loadCrkBytes(userId);
  }

  String generateRecoveryCode(Uint8List crkBytes) {
    final formatted = _crypto.encodeCrk(crkBytes);
    return formatted;
  }
}
