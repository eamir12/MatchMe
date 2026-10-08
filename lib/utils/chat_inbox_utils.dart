import 'package:matchme/models/chat_model.dart';

List<ChatModel> filterUnreadChats(
  Iterable<ChatModel> chats, {
  required bool unreadOnly,
}) {
  if (!unreadOnly) return chats.toList(growable: false);
  return chats.where((chat) => chat.unreadCount > 0).toList(growable: false);
}

/// Splits a chat list into active and archived views. Archive is per-user and
/// display-only: archived chats still receive notifications and keep their
/// cached row, they are just shown in the Archived view instead of the main
/// list.
List<ChatModel> filterArchivedChats(
  Iterable<ChatModel> chats, {
  required bool archived,
}) {
  return chats.where((chat) => chat.isArchived == archived).toList();
}
