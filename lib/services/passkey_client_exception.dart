class PasskeyClientException implements Exception {
  const PasskeyClientException({required this.code, required this.message});

  final String code;
  final String message;

  @override
  String toString() => message;
}
