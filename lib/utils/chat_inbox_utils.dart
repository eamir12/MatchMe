import 'package:matchme/models/chat_model.dart';

List<ChatModel> filterUnreadChats(
  Iterable<ChatModel> chats, {
  required bool unreadOnly,
}) {
  if (!unreadOnly) return chats.toList(growable: false);
  return chats.where((chat) => chat.unreadCount > 0).toList(growable: false);
}
