import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/models/chat_model.dart';
import 'package:matchme/models/attendee_model.dart';

void main() {
  test('ChatModel masks other_user_name to first and last initial', () {
    final json = {
      'match_id': 'm1',
      'other_user_id': 'u2',
      'other_user_name': 'Jane Smith',
      'last_message_content': 'Hi',
      'last_message_id': 'msg1',
      'last_message_at': '2025-12-01T12:00:00Z',
      'unread_count': 0,
    };

    final chat = ChatModel.fromJsonRpc(json);
    expect(chat.otherUserName, 'Jane S.');
    expect(chat.getFormattedName(), contains('Jane'));
    expect(chat.getFormattedName(), contains('S.'));
  });

  test('AttendeeModel masks user_name on fromJson', () {
    final json = {
      'user_id': 'u3',
      'user_name': 'John Doe',
    };

    final attendee = AttendeeModel.fromJson(json);
    expect(attendee.fullName, 'John D.');
    expect(attendee.formattedName, 'John D.');
  });
}
