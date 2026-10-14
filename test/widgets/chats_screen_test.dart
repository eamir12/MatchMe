import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:matchme/models/chat_model.dart';
import 'package:matchme/models/match_model.dart';
import 'package:matchme/providers/app_config_provider.dart';
import 'package:matchme/providers/external_ad_provider.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/typing_provider.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:matchme/screens/chats/chats_screen.dart';
import 'package:matchme/widgets/list_filter_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _TestUserPreferencesNotifier extends UserPreferencesNotifier {
  @override
  UserPreferencesState build() => UserPreferencesState.defaults();
}

class _StubAppConfigNotifier extends AppConfigNotifier {
  @override
  Map<String, String> build() => const {
    'ads.external.enabled': 'false',
    'ads.internal.enabled': 'false',
    'ads.display_order': 'external_first',
  };
}

String _fakeAccessToken() {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String encode(Map<String, dynamic> value) {
    return base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  }

  final header = encode({'alg': 'HS256', 'typ': 'JWT'});
  final payload = encode({'sub': 'test-user', 'iat': now, 'exp': now + 3600});
  return '$header.$payload.c2ln';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initializeDateFormatting('en');
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://test-project.supabase.co',
      publishableKey: 'test-publishable-key',
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/auth/v1/user')) {
          return http.Response(
            jsonEncode({
              'id': 'test-user',
              'aud': 'authenticated',
              'role': 'authenticated',
              'email': 'test@example.com',
              'app_metadata': <String, dynamic>{},
              'user_metadata': <String, dynamic>{},
              'created_at': '2026-01-01T00:00:00Z',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('[]', 200);
      }),
      debug: false,
    );
    await Supabase.instance.client.auth.setSession(
      'test-refresh-token',
      accessToken: _fakeAccessToken(),
    );
  });

  testWidgets('chats inbox renders cached conversations', (tester) async {
    const userId = 'test-user';
    final chat = ChatModel(
      matchId: 'match-1',
      otherUserId: 'other-user',
      otherUserName: 'Alex M.',
      lastMessage: 'Hello there',
      lastMessageId: 'message-1',
      lastMessageAt: DateTime(2026, 1, 1),
      unreadCount: 2,
    );
    final l10n = LocalizationState.loading();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWithValue(l10n),
          recentChatsProvider(
            userId,
          ).overrideWith((ref) => Stream.value([chat])),
          initialHomeSyncProvider(userId).overrideWith((ref) async {}),
          recentMatchesProvider(
            userId,
          ).overrideWith((ref) => Stream.value(const <MatchModel>[])),
          allIntentsProvider.overrideWith((ref) async => const []),
          externalAdsRealtimeProvider.overrideWith((ref) {}),
          externalAdsEnabledProvider.overrideWithValue(false),
          internalAdsEnabledProvider.overrideWithValue(false),
          adDisplayOrderProvider.overrideWithValue('external_first'),
          appConfigProvider.overrideWith(_StubAppConfigNotifier.new),
          userPreferencesProvider.overrideWith(
            _TestUserPreferencesNotifier.new,
          ),
          userUnitSystemProvider.overrideWithValue(UnitSystemPreference.metric),
          isOtherTypingProvider(
            TypingParams(
              matchId: chat.matchId,
              selfUserId: userId,
              otherUserId: chat.otherUserId,
            ),
          ).overrideWith((ref) => Stream.value(false)),
          userProfileProvider(
            chat.otherUserId,
          ).overrideWith((ref) => Stream.value(null)),
        ],
        child: MaterialApp(home: Scaffold(body: ChatsScreen())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Alex M.'), findsOneWidget);
    expect(find.text('Hello there'), findsOneWidget);
    // The unread toggle is no longer a chip in a horizontal scroller — it is a
    // switch inside the filter sheet, so the assertion moved with it.
    expect(find.byType(ListSearchBar), findsOneWidget);
    expect(find.text('1 conversations'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'chats match-type filter resolves from the underlying match before the '
    'server column exists',
    (tester) async {
      const userId = 'test-user';

      // Two chats whose ChatModel carries no matchType — the state the app is
      // in until migration 20262076000000 is applied. The type has to be
      // recovered from the matches list, which the screen already loads.
      final proximityChat = ChatModel(
        matchId: 'match-prox',
        otherUserId: 'near-user',
        otherUserName: 'Near Sam',
        lastMessage: 'Hi',
        lastMessageId: 'm1',
        lastMessageAt: DateTime(2026, 1, 2),
        unreadCount: 0,
      );
      final eventChat = ChatModel(
        matchId: 'match-evt',
        otherUserId: 'event-user',
        otherUserName: 'Event Eve',
        lastMessage: 'Hello',
        lastMessageId: 'm2',
        lastMessageAt: DateTime(2026, 1, 1),
        unreadCount: 0,
      );
      final l10n = LocalizationState.loading();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localizationProvider.overrideWithValue(l10n),
            recentChatsProvider(
              userId,
            ).overrideWith((ref) => Stream.value([proximityChat, eventChat])),
            initialHomeSyncProvider(userId).overrideWith((ref) async {}),
            recentMatchesProvider(userId).overrideWith(
              (ref) => Stream.value([
                MatchModel(
                  id: 'match-prox',
                  userAId: 'test-user',
                  userBId: 'near-user',
                  otherUserId: 'near-user',
                  matchedIntent: 'activity_partner',
                  matchType: 'proximity',
                  createdAt: DateTime(2026, 1, 2),
                ),
                MatchModel(
                  id: 'match-evt',
                  userAId: 'test-user',
                  userBId: 'event-user',
                  otherUserId: 'event-user',
                  matchedIntent: 'activity_partner',
                  matchType: 'event',
                  createdAt: DateTime(2026, 1, 1),
                ),
              ]),
            ),
            allIntentsProvider.overrideWith((ref) async => const []),
            externalAdsRealtimeProvider.overrideWith((ref) {}),
            externalAdsEnabledProvider.overrideWithValue(false),
            internalAdsEnabledProvider.overrideWithValue(false),
            adDisplayOrderProvider.overrideWithValue('external_first'),
          appConfigProvider.overrideWith(_StubAppConfigNotifier.new),
            userPreferencesProvider.overrideWith(
              _TestUserPreferencesNotifier.new,
            ),
            userUnitSystemProvider.overrideWithValue(
              UnitSystemPreference.metric,
            ),
            userProfileProvider(
              'near-user',
            ).overrideWith((ref) => Stream.value(null)),
            userProfileProvider(
              'event-user',
            ).overrideWith((ref) => Stream.value(null)),
          ],
          child: MaterialApp(home: Scaffold(body: ChatsScreen())),
        ),
      );
      await tester.pumpAndSettle();

      // Both rows render before filtering.
      expect(find.text('Near Sam'), findsOneWidget);
      expect(find.text('Event Eve'), findsOneWidget);

      // Open the sheet: the match-type section must be offered, because a type
      // was resolved even though no chat carried one. Section labels render
      // uppercase.
      await tester.tap(find.byIcon(Icons.tune_rounded).first);
      await tester.pumpAndSettle();
      expect(find.text('HOW YOU MET'), findsOneWidget);

      // Selecting Event narrows the live count to the one event conversation.
      await tester.tap(find.text('Event').last);
      await tester.pumpAndSettle();
      expect(find.text('Show 1 results'), findsOneWidget);

      await tester.tap(find.text('Show 1 results'));
      await tester.pumpAndSettle();

      expect(find.text('Near Sam'), findsNothing);
      expect(find.text('Event Eve'), findsOneWidget);

      // Unmount so provider-owned periodic timers are cancelled, then let the
      // clock run past the longest outstanding one-shot timer so teardown is
      // clean. The screen starts 1 Hz "now" and a 50 s revalidation timer.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 60));
    },
  );

  testWidgets('chats filter sheet exposes unread, intent and match type', (
    tester,
  ) async {
    const userId = 'test-user';
    final chat = ChatModel(
      matchId: 'match-1',
      otherUserId: 'other-user',
      otherUserName: 'Alex M.',
      lastMessage: 'Hello there',
      lastMessageId: 'message-1',
      lastMessageAt: DateTime(2026, 1, 1),
      unreadCount: 2,
    );
    final l10n = LocalizationState.loading();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWithValue(l10n),
          recentChatsProvider(
            userId,
          ).overrideWith((ref) => Stream.value([chat])),
          initialHomeSyncProvider(userId).overrideWith((ref) async {}),
          recentMatchesProvider(
            userId,
          ).overrideWith((ref) => Stream.value(const <MatchModel>[])),
          allIntentsProvider.overrideWith((ref) async => const []),
          externalAdsRealtimeProvider.overrideWith((ref) {}),
          externalAdsEnabledProvider.overrideWithValue(false),
          internalAdsEnabledProvider.overrideWithValue(false),
          adDisplayOrderProvider.overrideWithValue('external_first'),
          appConfigProvider.overrideWith(_StubAppConfigNotifier.new),
          userPreferencesProvider.overrideWith(
            _TestUserPreferencesNotifier.new,
          ),
          userUnitSystemProvider.overrideWithValue(UnitSystemPreference.metric),
          isOtherTypingProvider(
            TypingParams(
              matchId: chat.matchId,
              selfUserId: userId,
              otherUserId: chat.otherUserId,
            ),
          ).overrideWith((ref) => Stream.value(false)),
          userProfileProvider(
            chat.otherUserId,
          ).overrideWith((ref) => Stream.value(null)),
        ],
        child: MaterialApp(home: Scaffold(body: ChatsScreen())),
      ),
    );
    await tester.pumpAndSettle();

    // Open the sheet via the filter button next to the search field.
    await tester.tap(find.byIcon(Icons.tune_rounded).first);
    await tester.pumpAndSettle();

    // The unread toggle label carries the number of unread CONVERSATIONS
    // (1 chat has unread messages), not the message count.
    expect(find.text('Unread only (1)'), findsOneWidget);
    expect(find.text('Show 1 results'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty chats remain announced while initial sync is pending', (
    tester,
  ) async {
    const userId = 'test-user';
    final syncCompleter = Completer<void>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWithValue(LocalizationState.loading()),
          recentChatsProvider(
            userId,
          ).overrideWith((ref) => Stream.value(const <ChatModel>[])),
          initialHomeSyncProvider(
            userId,
          ).overrideWith((ref) => syncCompleter.future),
          recentMatchesProvider(
            userId,
          ).overrideWith((ref) => Stream.value(const <MatchModel>[])),
          allIntentsProvider.overrideWith((ref) async => const []),
          externalAdsRealtimeProvider.overrideWith((ref) {}),
          externalAdsEnabledProvider.overrideWithValue(false),
          internalAdsEnabledProvider.overrideWithValue(false),
          adDisplayOrderProvider.overrideWithValue('external_first'),
          appConfigProvider.overrideWith(_StubAppConfigNotifier.new),
          userPreferencesProvider.overrideWith(
            _TestUserPreferencesNotifier.new,
          ),
          userUnitSystemProvider.overrideWithValue(UnitSystemPreference.metric),
        ],
        child: const MaterialApp(home: Scaffold(body: ChatsScreen())),
      ),
    );
    await tester.pump();

    expect(find.bySemanticsLabel('Loading…'), findsOneWidget);
    expect(find.text('No recent chats'), findsNothing);

    syncCompleter.complete();
    await tester.pump();

    expect(find.bySemanticsLabel('Loading…'), findsNothing);
    expect(find.text('No recent chats'), findsOneWidget);
  });
}
