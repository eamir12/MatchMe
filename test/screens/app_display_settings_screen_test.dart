import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matchme/providers/currency_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/main_intents_provider.dart';
import 'package:matchme/providers/theme_provider.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:matchme/providers/voice_guidance_provider.dart';
import 'package:matchme/screens/settings/app_display_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _userId = 'test-user';
const _amoledLabel = 'Pure black (AMOLED)';

String _fakeAccessToken() {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String encode(Map<String, dynamic> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final header = encode({'alg': 'HS256', 'typ': 'JWT'});
  final payload = encode({'sub': _userId, 'iat': now, 'exp': now + 3600});
  return '$header.$payload.c2ln';
}

class _StubThemeModeNotifier extends ThemeModeNotifier {
  _StubThemeModeNotifier(this.mode);

  final ThemeMode mode;

  @override
  ThemeMode build() => mode;
}

class _StubAmoledThemeNotifier extends AmoledThemeNotifier {
  _StubAmoledThemeNotifier(this.enabled);

  final bool enabled;

  @override
  bool build() => enabled;
}

class _StubVoiceGuidanceNotifier extends VoiceGuidanceEnabledNotifier {
  @override
  bool build() => false;
}

class _TestUserPreferencesNotifier extends UserPreferencesNotifier {
  @override
  UserPreferencesState build() => UserPreferencesState.defaults();
}

Widget _buildApp({required ThemeMode themeMode, bool amoledEnabled = false}) {
  return ProviderScope(
    overrides: [
      localizationProvider.overrideWithValue(LocalizationState.loading()),
      themeModeProvider.overrideWith(() => _StubThemeModeNotifier(themeMode)),
      amoledThemeProvider.overrideWith(
        () => _StubAmoledThemeNotifier(amoledEnabled),
      ),
      voiceGuidanceEnabledProvider.overrideWith(_StubVoiceGuidanceNotifier.new),
      userPreferencesProvider.overrideWith(_TestUserPreferencesNotifier.new),
      languageOptionsProvider.overrideWith(
        (ref) async => [
          {
            'code': 'en',
            'display': 'English',
            'cached': true,
            'availableOffline': true,
            'offline': false,
          },
        ],
      ),
      effectiveUserCurrencyProvider.overrideWith((ref) async => 'USD'),
      prioritizedCurrencyCodesProvider.overrideWith(
        (ref) async => const <String>[],
      ),
    ],
    child: MaterialApp(
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      themeMode: themeMode,
      home: const AppDisplaySettingsScreen(),
    ),
  );
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
              'id': _userId,
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

  testWidgets('AMOLED option is hidden while the light theme is active', (
    tester,
  ) async {
    await tester.pumpWidget(_buildApp(themeMode: ThemeMode.light));
    await tester.pump();

    expect(find.text(_amoledLabel), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AMOLED option is shown while the dark theme is active', (
    tester,
  ) async {
    await tester.pumpWidget(_buildApp(themeMode: ThemeMode.dark));
    await tester.pump();

    expect(find.text(_amoledLabel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AMOLED option follows the device brightness in system mode', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await tester.pumpWidget(_buildApp(themeMode: ThemeMode.system));
    await tester.pump();

    expect(find.text(_amoledLabel), findsOneWidget);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();

    expect(find.text(_amoledLabel), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
