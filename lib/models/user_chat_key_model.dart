class UserChatKeyModel {
  final String id;
  final String userId;
  final int keyVersion;
  final String publicKeyBase64;
  final String status;
  final DateTime createdAt;
  final DateTime activatedAt;
  final DateTime? retiredAt;

  UserChatKeyModel({
    required this.id,
    required this.userId,
    required this.keyVersion,
    required this.publicKeyBase64,
    required this.status,
    required this.createdAt,
    required this.activatedAt,
    this.retiredAt,
  });

  bool get isActive => status == 'active';

  factory UserChatKeyModel.fromJson(Map<String, dynamic> json) {
    return UserChatKeyModel(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      keyVersion: json['key_version'] as int,
      publicKeyBase64: json['public_key'] as String,
      status: json['status'] as String? ?? 'active',
      createdAt: DateTime.parse(json['created_at'] as String),
      activatedAt: DateTime.parse(json['activated_at'] as String),
      retiredAt: json['retired_at'] != null
          ? DateTime.parse(json['retired_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'user_id': userId,
    'key_version': keyVersion,
    'public_key': publicKeyBase64,
    'status': status,
    'created_at': createdAt.toIso8601String(),
    'activated_at': activatedAt.toIso8601String(),
    'retired_at': retiredAt?.toIso8601String(),
  };
}

class UserChatKeyWrapperModel {
  final String id;
  final String userChatKeyId;
  final String userId;
  final String wrapperType;
  final String kdf;
  final int? kdfIterations;
  final String kdfSaltBase64;
  final String wrapAlg;
  final String wrapNonceBase64;
  final String encryptedPrivateKeyBase64;
  final DateTime createdAt;
  final DateTime updatedAt;

  UserChatKeyWrapperModel({
    required this.id,
    required this.userChatKeyId,
    required this.userId,
    required this.wrapperType,
    required this.kdf,
    this.kdfIterations,
    required this.kdfSaltBase64,
    required this.wrapAlg,
    required this.wrapNonceBase64,
    required this.encryptedPrivateKeyBase64,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isRecoveryKey => wrapperType == 'recovery_key';
  bool get isPassword => wrapperType == 'password';

  factory UserChatKeyWrapperModel.fromJson(Map<String, dynamic> json) {
    return UserChatKeyWrapperModel(
      id: json['id'] as String,
      userChatKeyId: json['user_chat_key_id'] as String,
      userId: json['user_id'] as String,
      wrapperType: json['wrapper_type'] as String,
      kdf: json['kdf'] as String,
      kdfIterations: json['kdf_iterations'] as int?,
      kdfSaltBase64: json['kdf_salt'] as String,
      wrapAlg: json['wrap_alg'] as String? ?? 'AES-256-GCM',
      wrapNonceBase64: json['wrap_nonce'] as String,
      encryptedPrivateKeyBase64: json['encrypted_private_key'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'user_chat_key_id': userChatKeyId,
    'user_id': userId,
    'wrapper_type': wrapperType,
    'kdf': kdf,
    'kdf_iterations': kdfIterations,
    'kdf_salt': kdfSaltBase64,
    'wrap_alg': wrapAlg,
    'wrap_nonce': wrapNonceBase64,
    'encrypted_private_key': encryptedPrivateKeyBase64,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };
}

class WrappedMessageKey {
  final String alg;
  final String kdf;
  final String? senderKeyId;
  final String? recipientKeyId;
  final String? supabaseKeyId;
  final String nonceBase64;
  final String ciphertextBase64;

  WrappedMessageKey({
    required this.alg,
    required this.kdf,
    this.senderKeyId,
    this.recipientKeyId,
    this.supabaseKeyId,
    required this.nonceBase64,
    required this.ciphertextBase64,
  });

  Map<String, dynamic> toJson() => {
    'alg': alg,
    'kdf': kdf,
    if (senderKeyId != null) 'sender_key_id': senderKeyId,
    if (recipientKeyId != null) 'recipient_key_id': recipientKeyId,
    if (supabaseKeyId != null) 'supabase_key_id': supabaseKeyId,
    'nonce': nonceBase64,
    'ciphertext': ciphertextBase64,
  };

  factory WrappedMessageKey.fromJson(Map<String, dynamic> json) {
    return WrappedMessageKey(
      alg: json['alg'] as String,
      kdf: json['kdf'] as String,
      senderKeyId: json['sender_key_id'] as String?,
      recipientKeyId: json['recipient_key_id'] as String?,
      supabaseKeyId: json['supabase_key_id'] as String?,
      nonceBase64: json['nonce'] as String,
      ciphertextBase64: json['ciphertext'] as String,
    );
  }
}
