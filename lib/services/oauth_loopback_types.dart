// lib/services/oauth_loopback_types.dart
//
// Shared types for the desktop OAuth loopback listener. Kept in their own file
// (rather than in either implementation) so the dart:io implementation and the
// web stub can both depend on them without a circular import.

/// Why a loopback OAuth attempt ended without a usable authorization code.
enum OAuthLoopbackFailure {
  /// The platform has no loopback listener (web).
  unsupported,

  /// No listener was running when a callback was awaited.
  notListening,

  /// The local HTTP listener could not be bound.
  bindFailed,

  /// No browser callback arrived within the allotted time.
  timeout,
}

/// Raised by [OAuthLoopbackServer] when a loopback sign-in cannot complete.
class OAuthLoopbackException implements Exception {
  const OAuthLoopbackException(this.failure);

  final OAuthLoopbackFailure failure;

  @override
  String toString() => 'OAuthLoopbackException: ${failure.name}';
}

/// The provider callback captured by the loopback listener.
///
/// The Supabase client runs the PKCE flow, so a successful hand-off is a single
/// `code` query parameter that the client then exchanges for a session.
class OAuthLoopbackCallback {
  const OAuthLoopbackCallback.success(String this.code)
    : error = null,
      errorDescription = null;

  const OAuthLoopbackCallback.error(String this.error, [this.errorDescription])
    : code = null;

  /// Neither a code nor an error - e.g. a stray `favicon.ico` probe.
  static const OAuthLoopbackCallback none = OAuthLoopbackCallback._none();

  /// Builds a callback from the query string of the loopback redirect.
  factory OAuthLoopbackCallback.fromQuery(Map<String, String> query) {
    final code = query['code']?.trim();
    if (code != null && code.isNotEmpty) {
      return OAuthLoopbackCallback.success(code);
    }
    final error = query['error']?.trim();
    if (error != null && error.isNotEmpty) {
      return OAuthLoopbackCallback.error(
        error,
        query['error_description']?.trim(),
      );
    }
    return none;
  }

  const OAuthLoopbackCallback._none()
    : code = null,
      error = null,
      errorDescription = null;

  final String? code;
  final String? error;
  final String? errorDescription;

  bool get isSuccess => (code ?? '').isNotEmpty;

  /// True when the provider explicitly reported a failure (user denied consent,
  /// provider outage, ...). Distinct from [isSuccess] being false because
  /// nothing usable arrived at all.
  bool get isProviderError => (error ?? '').isNotEmpty;
}
