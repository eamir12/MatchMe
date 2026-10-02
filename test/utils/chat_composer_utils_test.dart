import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/utils/chat_composer_utils.dart';

void main() {
  test('composer is enabled only for non-empty text while idle', () {
    expect(canSubmitChatComposer('', isSending: false), isFalse);
    expect(canSubmitChatComposer('   ', isSending: false), isFalse);
    expect(canSubmitChatComposer('Hello', isSending: false), isTrue);
  });

  test('composer stays disabled while sending', () {
    expect(canSubmitChatComposer('Hello', isSending: true), isFalse);
  });
}
