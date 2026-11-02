// test/auth_transition_guard_test.dart
//
// Calendar import borrows Supabase's social sign-in to obtain a provider access
// token, which transiently creates a session for the *provider* account. If the
// auth router honours that `signedIn` event it swaps the whole widget tree to
// `ProfileCheckScreen(key: ValueKey(providerId))` - the user gets bounced to
// the home screen and widgets like RatingPromptWatcher start prompting for the
// wrong person. AuthTransitionGuard makes that window explicit.

import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/auth_transition_guard.dart';

void main() {
  tearDown(AuthTransitionGuard.end);

  test('ignores nothing when no transition is in flight', () {
    expect(AuthTransitionGuard.isActive, isFalse);
    expect(AuthTransitionGuard.shouldIgnoreSessionFor('user-a'), isFalse);
    expect(AuthTransitionGuard.shouldIgnoreSessionFor('user-b'), isFalse);
  });

  test('ignores a different user while a transition is active', () {
    AuthTransitionGuard.begin('user-a');

    expect(AuthTransitionGuard.isActive, isTrue);
    expect(AuthTransitionGuard.anchorUserId, 'user-a');
    // The provider account that the token exchange signs in as.
    expect(AuthTransitionGuard.shouldIgnoreSessionFor('google-user'), isTrue);
  });

  test('never ignores the anchor user', () {
    AuthTransitionGuard.begin('user-a');

    expect(AuthTransitionGuard.shouldIgnoreSessionFor('user-a'), isFalse);
  });

  test('end() restores normal sign-in handling', () {
    AuthTransitionGuard.begin('user-a');
    AuthTransitionGuard.end();

    expect(AuthTransitionGuard.isActive, isFalse);
    expect(AuthTransitionGuard.anchorUserId, isNull);
    expect(AuthTransitionGuard.shouldIgnoreSessionFor('google-user'), isFalse);
  });

  test('begin() with an empty id is a no-op', () {
    AuthTransitionGuard.begin('');

    expect(AuthTransitionGuard.isActive, isFalse);
    expect(AuthTransitionGuard.anchorUserId, isNull);
  });

  test('never ignores a null or empty user id', () {
    AuthTransitionGuard.begin('user-a');

    expect(AuthTransitionGuard.shouldIgnoreSessionFor(null), isFalse);
    expect(AuthTransitionGuard.shouldIgnoreSessionFor(''), isFalse);
  });

  test('end() without a begin() does not throw', () {
    expect(AuthTransitionGuard.end, returnsNormally);
  });

  test('a second begin() re-anchors to the newest account', () {
    AuthTransitionGuard.begin('user-a');
    AuthTransitionGuard.begin('user-b');

    expect(AuthTransitionGuard.anchorUserId, 'user-b');
    expect(AuthTransitionGuard.shouldIgnoreSessionFor('user-a'), isTrue);
    expect(AuthTransitionGuard.shouldIgnoreSessionFor('user-b'), isFalse);
  });

  group('shouldDeferAuthEvent', () {
    // Side-effecting auth listeners (e.g. main.dart's, which resets the chat
    // key provider and forces the tab to Home on an account switch) must skip
    // the transient provider session, or the user is pulled out of the screen
    // they started the calendar import from.
    test('defers nothing when no transition is active', () {
      expect(AuthTransitionGuard.shouldDeferAuthEvent('user-a'), isFalse);
      expect(AuthTransitionGuard.shouldDeferAuthEvent(null), isFalse);
    });

    test('defers a different user while active', () {
      AuthTransitionGuard.begin('user-a');

      expect(AuthTransitionGuard.shouldDeferAuthEvent('google-user'), isTrue);
      expect(AuthTransitionGuard.shouldDeferAuthEvent('user-a'), isFalse);
    });

    test('also defers a sign-out event, unlike shouldIgnoreSessionFor', () {
      AuthTransitionGuard.begin('user-a');

      // shouldIgnoreSessionFor deliberately ignores null so the auth router can
      // keep rendering; a side-effecting listener must not act on it either.
      expect(AuthTransitionGuard.shouldIgnoreSessionFor(null), isFalse);
      expect(AuthTransitionGuard.shouldDeferAuthEvent(null), isTrue);
    });

    test('stops deferring once the transition ends', () {
      AuthTransitionGuard.begin('user-a');
      AuthTransitionGuard.end();

      expect(AuthTransitionGuard.shouldDeferAuthEvent('google-user'), isFalse);
      expect(AuthTransitionGuard.shouldDeferAuthEvent(null), isFalse);
    });
  });

  group('shouldPreserveVisibleUserDuringLoading', () {
    test('preserves the visible account while its session is active', () {
      expect(
        AuthTransitionGuard.shouldPreserveVisibleUserDuringLoading(
          visibleUserId: 'user-a',
          currentUserId: 'user-a',
        ),
        isTrue,
      );
    });

    test('does not preserve a previous account after a user switch', () {
      expect(
        AuthTransitionGuard.shouldPreserveVisibleUserDuringLoading(
          visibleUserId: 'user-a',
          currentUserId: 'user-b',
        ),
        isFalse,
      );
    });

    test('preserves the anchor during guarded OAuth auth churn', () {
      AuthTransitionGuard.begin('user-a');

      expect(
        AuthTransitionGuard.shouldPreserveVisibleUserDuringLoading(
          visibleUserId: 'user-a',
          currentUserId: 'provider-user',
        ),
        isTrue,
      );
      expect(
        AuthTransitionGuard.shouldPreserveVisibleUserDuringLoading(
          visibleUserId: 'user-a',
          currentUserId: null,
        ),
        isTrue,
      );
    });

    test('shows startup for cold start or without a matching anchor', () {
      expect(
        AuthTransitionGuard.shouldPreserveVisibleUserDuringLoading(
          visibleUserId: null,
          currentUserId: null,
        ),
        isFalse,
      );

      AuthTransitionGuard.begin('user-b');
      expect(
        AuthTransitionGuard.shouldPreserveVisibleUserDuringLoading(
          visibleUserId: 'user-a',
          currentUserId: null,
        ),
        isFalse,
      );
    });
  });
}
