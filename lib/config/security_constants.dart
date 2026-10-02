class SecurityConstants {
  SecurityConstants._();

  static const supabaseTranslationKeyId =
      'f5af9936-a780-4380-b9e8-b04396d4d903';
  static const supabaseTranslationPublicKeyBase64 =
      'MKms0fHanc5NGwrh9O9olNMWP/41wys205+mVkYhmhM=';

  static const crkInfoLabel = 'matchme-chat-recovery-key-wrap-v1';
  static const recipientWrapInfoLabel = 'matchme-recipient-message-key-wrap-v1';
  static const supabaseWrapInfoLabel =
      'matchme-supabase-translation-key-wrap-v1';
  static const messageOriginalAadPrefix = 'matchme.chat.v1|original';
  static const messageTranslatedAadPrefix = 'matchme.chat.v1|translated';
  static const wrapAadPrefix = 'matchme.chat.v1|wrap';
  static const clientAssistedRequestAadPrefix =
      'matchme.chat.v1|client-assisted-translate-request';
  static const clientAssistedResponseAadPrefix =
      'matchme.chat.v1|client-assisted-translate-response';
  static const dckInfoLabel = 'matchme-device-cache-key-v1';

  static const pbkdf2Iterations = 600000;
  static const pbkdf2SaltLength = 32;

  static const hkdfOutputLength = 32;
  static const messageKeyLength = 32;
  static const aesGcmNonceLength = 12;

  static const crkVersionByte = 0x01;
  static const crkByteLength = 32;
  static const crkCrcPolynomial = 0x1021;
  static const crkCrcInitial = 0xFFFF;

  static const activeKeyCacheTtlMinutes = 15;
  static const activeKeyCacheOfflineTtlHours = 24;

  static const outboxRetryDelays = [
    Duration(seconds: 5),
    Duration(seconds: 30),
    Duration(minutes: 2),
    Duration(minutes: 10),
  ];
}
