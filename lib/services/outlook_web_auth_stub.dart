// Stub for mobile platforms - Outlook Web Auth is only used on web
class OutlookWebAccount {
  final String username;
  final String? name;

  const OutlookWebAccount({required this.username, this.name});
}

class OutlookWebAuth {
  static OutlookWebAuth get instance => OutlookWebAuth();

  bool get isInitialized => false;

  Future<void> reset() async {
    throw UnsupportedError('OutlookWebAuth is only available on web platform');
  }

  Future<void> initialize({
    required String clientId,
    required String tenantId,
    required String redirectUri,
  }) async {
    throw UnsupportedError('OutlookWebAuth is only available on web platform');
  }

  Future<String?> signIn({
    List<String>? scopes,
    bool useRedirect = false,
    bool forceConsent = false,
    String? loginHint,
  }) async {
    throw UnsupportedError('OutlookWebAuth is only available on web platform');
  }

  Future<String?> getAccessToken({
    List<String>? scopes,
    bool forceRefresh = false,
  }) async {
    throw UnsupportedError('OutlookWebAuth is only available on web platform');
  }

  List<OutlookWebAccount> listAccounts() {
    throw UnsupportedError('OutlookWebAuth is only available on web platform');
  }

  Future<String?> getAccessTokenForUsername({
    required String username,
    List<String>? scopes,
    bool forceRefresh = false,
  }) async {
    throw UnsupportedError('OutlookWebAuth is only available on web platform');
  }

  Future<String?> handleRedirectCallback() async {
    throw UnsupportedError('OutlookWebAuth is only available on web platform');
  }

  Future<void> signOut() async {
    throw UnsupportedError('OutlookWebAuth is only available on web platform');
  }
}
