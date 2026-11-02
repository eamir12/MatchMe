// lib/services/auth_transition_guard.dart
//
// Marks the brief window in which a *non-login* OAuth exchange is running.
//
// Calendar import borrows Supabase's social sign-in to obtain a Google /
// Microsoft access token. That exchange really does create a Supabase session
// - for the provider account - so `onAuthStateChange` reports `signedIn` and
// the app's auth router (`main.dart`) treats it as a genuine sign-in: it swaps
// the whole widget tree over to `ProfileCheckScreen(key: ValueKey(providerId))`.
// The user gets bounced to the home screen, and widgets such as
// `RatingPromptWatcher` start prompting for the provider account. Restoring the
// original session afterwards cannot undo that, because the `ValueKey` change
// has already disposed the screen the user was on.
//
// So while a calendar OAuth is in flight, a sign-in for any user *other* than
// the one who started it is a transient artefact of the token exchange and must
// be ignored by the auth router.
//
// Deliberately not a lock: it auto-expires so a crash or an early return between
// `begin()` and `end()` can never leave the app permanently ignoring real
// sign-ins.

import 'package:flutter/foundation.dart';

class AuthTransitionGuard {
  AuthTransitionGuard._();

  /// Longer than any realistic provider round trip, short enough that a missed
  /// `end()` self-heals on the next navigation.
  static const Duration _maxDuration = Duration(seconds: 90);

  static String? _anchorUserId;
  static DateTime? _startedAt;

  /// The signed-in user this transition belongs to. Auth routing keeps showing
  /// this user until the original session is restored.
  static String? get anchorUserId => _anchorUserId;

  static bool get isActive {
    final anchor = _anchorUserId;
    final started = _startedAt;
    if (anchor == null || started == null) return false;
    if (DateTime.now().difference(started) > _maxDuration) {
      debugPrint(
        '[AuthTransitionGuard] expired after ${_maxDuration.inSeconds}s without end(); '
        'clearing so real sign-ins are honoured again',
      );
      _anchorUserId = null;
      _startedAt = null;
      return false;
    }
    return true;
  }

  /// Opens the window for [userId], the account that is signed in *now* and
  /// must remain the visible account throughout.
  static void begin(String userId) {
    if (userId.isEmpty) return;
    _anchorUserId = userId;
    _startedAt = DateTime.now();
    debugPrint('[AuthTransitionGuard] begin for anchor $userId');
  }

  static void end() {
    if (_anchorUserId == null) return;
    debugPrint('[AuthTransitionGuard] end for anchor $_anchorUserId');
    _anchorUserId = null;
    _startedAt = null;
  }

  /// Whether a session for [userId] should be treated as the transient
  /// side-effect of an in-flight calendar OAuth rather than a real sign-in.
  static bool shouldIgnoreSessionFor(String? userId) {
    if (userId == null || userId.isEmpty) return false;
    if (!isActive) return false;
    return userId != _anchorUserId;
  }

  /// Whether an auth event for [userId] should be deferred entirely while a
  /// non-login OAuth exchange is in flight.
  ///
  /// Unlike [shouldIgnoreSessionFor] this also covers a null session (a
  /// sign-out event). Side-effecting auth listeners must skip those too for the
  /// duration: reacting to the transient churn of a calendar import by resetting
  /// shared state would undo the very screen the user is working in.
  static bool shouldDeferAuthEvent(String? userId) {
    if (!isActive) return false;
    return userId != _anchorUserId;
  }

  /// Whether the auth router can keep rendering [visibleUserId] while its
  /// stream is temporarily loading. This avoids tearing down an active app
  /// shell during token refreshes or the guarded calendar OAuth exchange.
  static bool shouldPreserveVisibleUserDuringLoading({
    required String? visibleUserId,
    required String? currentUserId,
  }) {
    if (visibleUserId == null || visibleUserId.isEmpty) return false;
    if (currentUserId == visibleUserId) return true;
    return isActive && _anchorUserId == visibleUserId;
  }
}
