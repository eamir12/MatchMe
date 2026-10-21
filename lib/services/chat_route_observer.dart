// lib/services/chat_route_observer.dart
//
// Helpers for the `/chat/<matchId>` deep link that a notification tap opens.
//
// A single notification tap can reach the app through more than one channel
// at the same time:
//
//   * the FCM `onMessageOpenedApp` callback (warm start) and
//     `getInitialMessage()` (cold start) in lib/main.dart,
//   * the Android `onNotificationRoute` intent channel, fed by
//     `MainActivity.onNewIntent`,
//   * the native launch intent, re-read by `ProfileCheckScreen` on a cold
//     start.
//
// Each of those pushed its own `/chat/<matchId>` route. Every one of those
// routes paints the pulsing startup logo while it resolves the match, and
// each of them used to replace the *top-most* route of the navigator with
// the chat screen instead of replacing itself. The route that lost the race
// therefore survived underneath the chat with its resolve already finished
// and its safety timer already cancelled: pressing back revealed that
// frozen splash, and it never navigated away again - a white screen with the
// MatchMe logo pulsing forever.
//
// [ChatRouteObserver] lets the deep-link route see that the conversation it
// is about to open is already being opened, so the duplicate stands down
// instead of racing the first one, and [replaceOwnRoute] / [removeOwnRoute]
// make sure a route always removes *itself* rather than whatever happens to
// be on top of the stack.

import 'package:flutter/widgets.dart';

/// Route-name prefix of the deep-link route that resolves a chat
/// conversation from a notification tap (`/chat/<matchId>`).
const String kChatDeepLinkRoutePrefix = '/chat/';

/// Route-name prefix of the resolved conversation screen that the deep-link
/// route pushes once the match has been resolved (`/conversation/<matchId>`).
const String kChatConversationRoutePrefix = '/conversation/';

/// Tracks the chat conversations the app is currently routing to and
/// collapses duplicate deep links for the same conversation.
class ChatRouteObserver extends NavigatorObserver {
  final Set<String> _claimed = <String>{};

  /// Claims [matchId] for the route that is about to resolve it.
  ///
  /// Returns false when another route already claimed the same
  /// conversation. The first claimant wins; the caller must stand down
  /// instead of opening a second copy of the same chat.
  bool claimConversation(String matchId) => _claimed.add(matchId);

  /// Releases the claim held for [matchId].
  void releaseConversation(String matchId) => _claimed.remove(matchId);

  /// Whether [matchId] is currently claimed by a deep-link route.
  bool isConversationClaimed(String matchId) => _claimed.contains(matchId);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _releaseForRoute(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _releaseForRoute(route);
  }

  void _releaseForRoute(Route<dynamic> route) {
    final name = route.settings.name;
    if (name == null || !name.startsWith(kChatConversationRoutePrefix)) {
      return;
    }
    final matchId = name.substring(kChatConversationRoutePrefix.length).trim();
    if (matchId.isNotEmpty) _claimed.remove(matchId);
  }
}

/// Replaces the route that owns [context] with [newRoute].
///
/// [NavigatorState.pushReplacement] replaces the *top-most* route of the
/// navigator, not the caller's own route. When the calling route was not
/// the top-most one - a duplicate deep link for the same notification had
/// been pushed on top of it - the replacement silently removed that other
/// route and left the calling route (the pulsing startup logo) stranded
/// underneath the chat, where it stayed forever because its resolve had
/// already finished.
///
/// Replacing the caller's own route works no matter what else is on the
/// stack, so the splash can never survive the navigation.
void replaceOwnRoute(BuildContext context, Route<dynamic> newRoute) {
  final route = ModalRoute.of(context);
  final navigator = route?.navigator;
  if (route == null || navigator == null) {
    Navigator.of(context, rootNavigator: true).push(newRoute);
    return;
  }
  if (route.isCurrent) {
    // We are the top-most route: a plain replacement keeps the cross-fade.
    navigator.pushReplacement(newRoute);
    return;
  }
  navigator.removeRoute(route);
  navigator.push(newRoute);
}

/// Removes the route that owns [context] from the navigator stack.
///
/// [NavigatorState.pop] removes the *top-most* route, which is not
/// necessarily the caller's own route. Removing the route by identity is the
/// only way to guarantee that this screen - and only this screen - goes
/// away.
void removeOwnRoute(BuildContext context) {
  final route = ModalRoute.of(context);
  final navigator = route?.navigator;
  if (route == null || navigator == null) return;
  if (route.isCurrent) {
    if (navigator.canPop()) {
      navigator.pop();
    }
    // When this is the navigator's only route there is nothing to go back
    // to: popping it would empty the navigator and leave a blank window, so
    // the route is left in place instead.
    return;
  }
  navigator.removeRoute(route);
}
