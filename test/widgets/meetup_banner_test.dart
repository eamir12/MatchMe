import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/models/meetup_models.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/meetup_provider.dart';
import 'package:matchme/screens/meetup/beacon_screen.dart';
import 'package:matchme/widgets/meetup_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _matchId = 'beacon-match';

class _TestLocalization extends Localization {
  @override
  LocalizationState build() => LocalizationState(
    currentLocale: const Locale('en'),
    textDirection: TextDirection.ltr,
    supportedLanguages: const [],
    strings: const {
      'meetupBannerBeacon': '{name} sent a beacon',
      'meetupBeaconIncomingBody': 'Look for the beacon.',
      'meetupOpen': 'Open',
    },
  );

  @override
  Future<void> syncLanguageAfterLogin() async {}
}

class _FixedMeetupNotifier extends MeetupNotifier {
  _FixedMeetupNotifier(super.matchId, this._state);

  final MeetupState _state;

  @override
  MeetupState build() => _state;
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

  testWidgets('beacon banner shows the exact beacon graphic', (tester) async {
    final now = DateTime.now().toUtc();
    final state = MeetupState(
      loading: false,
      currentUserId: 'viewer',
      signals: [
        MeetupSignal(
          id: 'beacon-signal',
          sessionId: null,
          senderId: 'partner',
          type: MeetupSignalType.beacon,
          payload: const {},
          createdAt: now,
          expiresAt: now.add(const Duration(minutes: 2)),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWith(_TestLocalization.new),
          meetupProvider(_matchId).overrideWith(
            () => _FixedMeetupNotifier(_matchId, state),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: MeetupBanner(
              matchId: _matchId,
              otherUserId: 'partner',
              otherUserName: 'Maya',
            ),
          ),
        ),
      ),
    );

    expect(find.byType(MeetupBeaconShape), findsOneWidget);
    expect(find.byIcon(Icons.sensors), findsNothing);
    expect(find.text('Maya sent a beacon'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
