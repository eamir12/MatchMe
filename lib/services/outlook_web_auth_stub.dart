// Stub for mobile platforms - Outlook Web Auth is only used on web
class OutlookWebAuth {
  static OutlookWebAuth get instance => OutlookWebAuth();
  
  bool get isInitialized => false;
  
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
  }) async {
    throw UnsupportedError('OutlookWebAuth is only available on web platform');
  }
  
  Future<String?> getAccessToken({List<String>? scopes, bool forceRefresh = false}) async {
    throw UnsupportedError('OutlookWebAuth is only available on web platform');
  }
  
  Future<String?> handleRedirectCallback() async {
    throw UnsupportedError('OutlookWebAuth is only available on web platform');
  }

  Future<void> signOut() async {
    throw UnsupportedError('OutlookWebAuth is only available on web platform');
  }
}
