import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/meetup_provider.dart';
import 'package:matchme/screens/meetup/beacon_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _matchId = 'beacon-expiry-match';

class _TestLocalization extends Localization {
  @override
  LocalizationState build() => LocalizationState(
    currentLocale: const Locale('en'),
    textDirection: TextDirection.ltr,
    supportedLanguages: const [],
    strings: const {},
  );

  @override
  Future<void> syncLanguageAfterLogin() async {}
}

class _EmptyMeetupNotifier extends MeetupNotifier {
  _EmptyMeetupNotifier(super.matchId);

  @override
  MeetupState build() =>
      const MeetupState(loading: false, currentUserId: 'viewer');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://test-project.supabase.co',
      publishableKey: 'test-publishable-key',
      debug: false,
    );
  });

  testWidgets('sender returns to the hub when their beacon is no longer live', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWith(_TestLocalization.new),
          meetupProvider(
            _matchId,
          ).overrideWith(() => _EmptyMeetupNotifier(_matchId)),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Meet-up hub'),
                    TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const MeetupBeaconScreen(
                            matchId: _matchId,
                            otherUserName: 'Maya',
                            mine: true,
                          ),
                        ),
                      ),
                      child: const Text('Open beacon'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open beacon'));
    await tester.pumpAndSettle();

    expect(find.text('Meet-up hub'), findsOneWidget);
    expect(find.byType(MeetupBeaconScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
