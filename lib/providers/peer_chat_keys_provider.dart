import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/user_chat_key_model.dart';
import 'package:matchme/services/chat_key_service.dart';

class PeerChatKeysNotifier extends Notifier<Map<String, UserChatKeyModel>> {
  final ChatKeyService _chatKeyService = ChatKeyService.instance;

  @override
  Map<String, UserChatKeyModel> build() {
    return {};
  }

  Future<UserChatKeyModel?> fetchKeyById(String keyId) async {
    final cached = state[keyId];
    if (cached != null) return cached;

    final key = await _chatKeyService.fetchPeerPublicKey(keyId);
    if (key != null) {
      state = {...state, keyId: key};
    }
    return key;
  }

  Future<UserChatKeyModel?> fetchActiveKeyByUserId(String userId) async {
    final key = await _chatKeyService.fetchActiveKey(userId);
    if (key != null) {
      state = {...state, key.id: key};
    }
    return key;
  }

  void cacheKey(UserChatKeyModel key) {
    state = {...state, key.id: key};
  }
}

final peerChatKeysProvider =
    NotifierProvider<PeerChatKeysNotifier, Map<String, UserChatKeyModel>>(() {
      return PeerChatKeysNotifier();
    });
