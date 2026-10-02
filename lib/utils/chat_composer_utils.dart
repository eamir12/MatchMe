bool canSubmitChatComposer(String text, {required bool isSending}) {
  return !isSending && text.trim().isNotEmpty;
}
