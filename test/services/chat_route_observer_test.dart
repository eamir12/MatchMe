// test/services/chat_route_observer_test.dart
//
// Regression cover for the "notification -> chat -> back leaves a white
// screen with the pulsing MatchMe logo forever" bug.
//
// A notification tap can reach the app through more than one channel at the
// same time (the FCM callbacks, the Android intent channel and the native
// launch intent), and each channel pushed its own `/chat/<matchId>` route.
// Every one of those routes paints the startup logo while it resolves the
// match, and each of them replaced the *top-most* route with the chat
// instead of replacing itself. The route that lost the race was left
// stranded underneath the chat with its resolve already finished, so
// pressing back revealed a frozen splash that never navigated away.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/chat_route_observer.dart';

/// Stand-in for the startup splash the deep-link route paints while it
/// resolves the match. Deliberately not the real animated loader: an
/// infinitely repeating animation would stop `pumpAndSettle` from settling.
class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(child: Text('Splash')),
  );
}

class _Home extends StatelessWidget {
  const _Home();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(child: Text('Home')),
  );
}

class _Conversation extends StatelessWidget {
  const _Conversation();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(child: Text('Conversation')),
  );
}

/// Mirrors the deep-link route in lib/main.dart: it claims the
/// conversation, stands down when the claim is already taken, and replaces
/// *itself* with the conversation screen.
class _FakeDeepLink extends StatefulWidget {
  const _FakeDeepLink({required this.matchId, required this.observer});

  final String matchId;
  final ChatRouteObserver observer;

  @override
  State<_FakeDeepLink> createState() => _FakeDeepLinkState();
}

class _FakeDeepLinkState extends State<_FakeDeepLink> {
  bool _ownsClaim = false;
  bool _pushedConversation = false;

  @override
  void initState() {
    super.initState();
    _ownsClaim = widget.observer.claimConversation(widget.matchId);
    if (!_ownsClaim) {
      // A duplicate deep link for a conversation that is already being
      // opened: stand down instead of racing the first route.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        removeOwnRoute(context);
      });
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_ownsClaim) return;
      _pushedConversation = true;
      replaceOwnRoute(
        context,
        MaterialPageRoute(
          settings: RouteSettings(
            name: '$kChatConversationRoutePrefix${widget.matchId}',
          ),
          builder: (_) => const _Conversation(),
        ),
      );
    });
  }

  @override
  void dispose() {
    if (_ownsClaim && !_pushedConversation) {
      widget.observer.releaseConversation(widget.matchId);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const _Splash();
}

/// Builds an app whose `/chat/<matchId>` route behaves like the real
/// deep-link route.
Future<GlobalKey<NavigatorState>> pumpChatHost(
  WidgetTester tester,
  ChatRouteObserver observer,
) async {
  final key = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: key,
      navigatorObservers: [observer],
      onGenerateRoute: (settings) {
        final name = settings.name ?? '';
        if (!name.startsWith(kChatDeepLinkRoutePrefix)) return null;
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => _FakeDeepLink(
            matchId: name.substring(kChatDeepLinkRoutePrefix.length),
            observer: observer,
          ),
        );
      },
      home: const _Home(),
    ),
  );
  return key;
}

void main() {
  test('only the first deep link for a conversation may claim it', () {
    final observer = ChatRouteObserver();

    expect(observer.claimConversation('match-1'), isTrue);
    expect(observer.claimConversation('match-1'), isFalse);
    expect(observer.claimConversation('match-2'), isTrue);

    observer.releaseConversation('match-1');
    expect(observer.isConversationClaimed('match-1'), isFalse);
    expect(observer.claimConversation('match-1'), isTrue);
  });

  testWidgets(
    'a duplicate deep link does not strand the splash under the chat',
    (tester) async {
      final observer = ChatRouteObserver();
      final key = await pumpChatHost(tester, observer);

      // One notification tap that reaches the app through two channels.
      key.currentState!.pushNamed('/chat/match-1');
      key.currentState!.pushNamed('/chat/match-1');
      await tester.pumpAndSettle();

      // Exactly one conversation is open and no splash is left behind.
      expect(find.text('Conversation'), findsOneWidget);
      expect(find.text('Splash'), findsNothing);

      // Back must land on the home screen, never on a frozen splash.
      key.currentState!.pop();
      await tester.pumpAndSettle();

      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Splash'), findsNothing);
    },
  );

  testWidgets(
    'a single deep link opens the chat and back returns home',
    (tester) async {
      final observer = ChatRouteObserver();
      final key = await pumpChatHost(tester, observer);

      key.currentState!.pushNamed('/chat/match-1');
      await tester.pumpAndSettle();

      expect(find.text('Conversation'), findsOneWidget);
      expect(find.text('Splash'), findsNothing);

      key.currentState!.pop();
      await tester.pumpAndSettle();

      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Splash'), findsNothing);
    },
  );

  testWidgets(
    'the conversation claim is released once the chat is closed',
    (tester) async {
      final observer = ChatRouteObserver();
      final key = await pumpChatHost(tester, observer);

      key.currentState!.pushNamed('/chat/match-1');
      await tester.pumpAndSettle();
      expect(observer.isConversationClaimed('match-1'), isTrue);

      key.currentState!.pop();
      await tester.pumpAndSettle();
      expect(observer.isConversationClaimed('match-1'), isFalse);
    },
  );
}
