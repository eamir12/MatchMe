// test/navigation_context_init_test.dart
//
// MainNavigationScreen resets the selected tab to Home in initState, because its
// State is destroyed and recreated whenever ProfileCheckScreen re-renders it
// from a different position in the tree (emitted both as a direct child of the
// screen switch and nested inside a FutureBuilder fallback). That happens on
// every profile re-resolution - including the transient session churn of a
// calendar OAuth - which threw the user back to the Home tab mid-task.
//
// NavigationContextInitNotifier makes the reset once-per-user-per-process
// instead of once-per-State-instance.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/home_providers.dart';

void main() {
  late ProviderContainer container;
  late NavigationContextInitNotifier notifier;

  setUp(() {
    container = ProviderContainer();
    notifier = container.read(navigationContextInitProvider.notifier);
  });

  tearDown(() => container.dispose());

  test('is not initialised for anyone before the first mark', () {
    expect(notifier.state, isNull);
    expect(notifier.isInitialisedFor('user-a'), isFalse);
    expect(notifier.isInitialisedFor(null), isFalse);
    expect(notifier.isInitialisedFor(''), isFalse);
  });

  test('is initialised for the user it was marked for', () {
    notifier.markInitialisedFor('user-a');

    expect(container.read(navigationContextInitProvider), 'user-a');
    expect(notifier.isInitialisedFor('user-a'), isTrue);
  });

  test('a State recreation for the same user does not re-initialise', () {
    // Stands in for: shell State built -> marked -> State destroyed and rebuilt
    // by ProfileCheckScreen re-emitting it from the other tree position.
    notifier.markInitialisedFor('user-a');
    expect(notifier.isInitialisedFor('user-a'), isTrue);
    expect(notifier.isInitialisedFor('user-a'), isTrue);
  });

  test('an account switch re-initialises for the new user', () {
    notifier.markInitialisedFor('user-a');

    expect(notifier.isInitialisedFor('user-b'), isFalse);
    notifier.markInitialisedFor('user-b');
    expect(notifier.isInitialisedFor('user-b'), isTrue);
    expect(notifier.isInitialisedFor('user-a'), isFalse);
  });

  test('reset clears the marker so a fresh sign-in starts on Home', () {
    notifier.markInitialisedFor('user-a');
    notifier.reset();

    expect(container.read(navigationContextInitProvider), isNull);
    expect(notifier.isInitialisedFor('user-a'), isFalse);
  });

  test('a null or empty user id is never treated as initialised', () {
    notifier.markInitialisedFor('');

    expect(notifier.isInitialisedFor(''), isFalse);
    expect(notifier.isInitialisedFor(null), isFalse);
  });
}
