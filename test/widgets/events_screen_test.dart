import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matchme/models/event_model.dart';
import 'package:matchme/providers/app_config_provider.dart';
import 'package:matchme/providers/event_provider.dart';
import 'package:matchme/providers/external_ad_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:matchme/screens/events/events_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _fakeAccessToken() {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String encode(Map<String, dynamic> value) {
    return base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  }

  final header = encode({'alg': 'HS256', 'typ': 'JWT'});
  final payload = encode({'sub': 'test-user', 'iat': now, 'exp': now + 3600});
  return '$header.$payload.c2ln';
}

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

class _LeaveEventManager extends EventManager {
  static int leaveCalls = 0;
  static bool result = false;

  @override
  AsyncValue<List<EventModel>> build() => AsyncData([
    EventModel(
      id: 'event-1',
      eventName: 'Rooftop Mixer',
      eventVenue: 'Community Hall',
      startTime: DateTime.now().add(const Duration(days: 1)),
      endTime: DateTime.now().add(const Duration(days: 1, hours: 3)),
      attendeeCount: 3,
    ),
  ]);

  @override
  Future<bool> leaveEvent(String eventId) async {
    leaveCalls++;
    return result;
  }
}

class _FakeEventManager extends EventManager {
  static bool? lastForceRemote;

  @override
  AsyncValue<List<EventModel>> build() => const AsyncData([]);

  @override
  Future<void> fetchUserEvents({bool forceRemote = false}) async {
    lastForceRemote = forceRemote;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
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

  testWidgets('Events pull-to-refresh requests authoritative remote data', (
    tester,
  ) async {
    _FakeEventManager.lastForceRemote = null;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWithValue(LocalizationState.loading()),
          eventManagerProvider.overrideWith(_FakeEventManager.new),
          profileEditProvider(
            'test-user',
          ).overrideWithValue(const AsyncData<UserProfile?>(null)),
          externalAdsRealtimeProvider.overrideWith((ref) {}),
          externalAdsEnabledProvider.overrideWithValue(false),
          internalAdsEnabledProvider.overrideWithValue(false),
          adDisplayOrderProvider.overrideWithValue('external_first'),
          appConfigProvider.overrideWith(_StubAppConfigNotifier.new),
          userPreferencesProvider.overrideWith(
            _TestUserPreferencesNotifier.new,
          ),
        ],
        child: const MaterialApp(home: EventsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, 320),
      1000,
    );
    await tester.pumpAndSettle();

    expect(_FakeEventManager.lastForceRemote, isTrue);
  });

  testWidgets('failed event leave reports the error and offers retry', (
    tester,
  ) async {
    _LeaveEventManager.leaveCalls = 0;
    _LeaveEventManager.result = false;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWithValue(LocalizationState.loading()),
          eventManagerProvider.overrideWith(_LeaveEventManager.new),
          profileEditProvider(
            'test-user',
          ).overrideWithValue(const AsyncData<UserProfile?>(null)),
          externalAdsRealtimeProvider.overrideWith((ref) {}),
          externalAdsEnabledProvider.overrideWithValue(false),
          internalAdsEnabledProvider.overrideWithValue(false),
          adDisplayOrderProvider.overrideWithValue('external_first'),
          appConfigProvider.overrideWith(_StubAppConfigNotifier.new),
          userPreferencesProvider.overrideWith(
            _TestUserPreferencesNotifier.new,
          ),
        ],
        child: const MaterialApp(home: EventsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Leave event'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Leave "Rooftop Mixer"?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Leave event'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Could not leave this event. You are still listed as attending.',
      ),
      findsOneWidget,
    );
    expect(find.text('You left the event'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(_LeaveEventManager.leaveCalls, 2);
  });
}
