import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/models/chat_model.dart';
import 'package:matchme/utils/chat_inbox_utils.dart';

ChatModel _chat(String id, int unreadCount) {
  return ChatModel(
    matchId: id,
    otherUserId: 'user-$id',
    otherUserName: 'User $id',
    lastMessage: 'Hello',
    lastMessageId: 'message-$id',
    lastMessageAt: DateTime(2026, 1, 1),
    unreadCount: unreadCount,
  );
}

void main() {
  final chats = [_chat('one', 2), _chat('two', 0), _chat('three', 1)];

  test('unread-only filtering preserves conversation order', () {
    final filtered = filterUnreadChats(chats, unreadOnly: true);

    expect(filtered.map((chat) => chat.matchId), ['one', 'three']);
  });

  test('disabled unread filtering returns all conversations', () {
    final filtered = filterUnreadChats(chats, unreadOnly: false);

    expect(filtered.map((chat) => chat.matchId), ['one', 'two', 'three']);
  });
}
