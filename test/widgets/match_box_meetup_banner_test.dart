import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matchme/models/chat_model.dart';
import 'package:matchme/models/match_model.dart';
import 'package:matchme/models/meetup_activity.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/match_rating_provider.dart';
import 'package:matchme/providers/meetup_activity_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/screens/matches/match_profile_screen.dart';
import 'package:matchme/screens/meetup/meetup_hub_screen.dart';
import 'package:matchme/screens/meetup/meetup_screen.dart';
import 'package:matchme/services/match_rating_service.dart';
import 'package:matchme/widgets/match_box.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _currentUserId = 'banner-viewer';
const _otherUserId = 'banner-partner';
const _matchId = 'banner-match';
const _partnerName = 'Maya L.';

String _accessToken() {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String encode(Map<String, dynamic> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode({'alg': 'HS256', 'typ': 'JWT'})}.'
      '${encode({'sub': _currentUserId, 'iat': now, 'exp': now + 3600})}.sig';
}

UserProfile _profile(String id, String name) {
  return UserProfile.fromMap({
    'id': id,
    'name': name,
    'photos': <String>[],
    'personal_interests': <String, List<String>>{},
  });
}

class _TestLocalization extends Localization {
  _TestLocalization(this.testState);

  final LocalizationState testState;

  @override
  LocalizationState build() => testState;

  @override
  Future<void> syncLanguageAfterLogin() async {}
}

const _strings = {
  'generalUnknown': 'Unknown',
  'viewMatch': 'View match',
  'meetupBannerProposedByOther': '{name} suggested a meeting point',
  'meetupActivityHintProposal': 'Choose a place together',
  'meetupBannerActive': 'Meet-up active — {place}',
  'meetupActivityHintActive': 'Open the meet-up for the tools',
  'meetupActivityOneMoreTool': '1 more meet-up tool is active',
  'meetupActivityMoreTools': '{count} more meet-up tools are active',
  'meetupBeaconActiveTitle': 'Beacon on',
  'meetupBeaconActiveBody':
      'Hold up your screen. {name} is looking for this shape.',
  'meetupBannerWave': '{name} waved at you',
  'meetupWaveIncomingBody': 'Raise your hand so they can see you.',
  'meetupBannerGesture': '{name} is signaling: {gesture}',
  'meetupGestureIncomingBody': 'Look for this gesture so you can spot each other.',
  'meetupGestureWave': 'Wave',
  'meetupGestureHandsUp': 'Both hands up',
  'meetupGestureJumping': 'Jumping',
  'meetupGestureArmsWide': 'Arms wide',
  'meetupActivityYourWave': 'You waved',
  'meetupActivityYourGesture': 'You sent {gesture}',
  'meetupActivityHintWaveMine': 'They can wave back',
};

LocalizationState _l10n({TextDirection direction = TextDirection.ltr}) =>
    LocalizationState(
      currentLocale: Locale(direction == TextDirection.rtl ? 'he' : 'en'),
      textDirection: direction,
      strings: _strings,
      supportedLanguages: const [],
    );

Widget _harness({
  required MeetupActivity? activity,
  TextDirection direction = TextDirection.ltr,
}) {
  final now = DateTime.now();
  final match = MatchModel(
    id: _matchId,
    userAId: _currentUserId,
    userBId: _otherUserId,
    otherUserId: _otherUserId,
    matchedIntent: 'friendship',
    matchType: 'manual_test',
    createdAt: now,
  );

  return ProviderScope(
    overrides: [
      localizationProvider.overrideWith(
        () => _TestLocalization(_l10n(direction: direction)),
      ),
      meetupActivityForMatchProvider(_matchId).overrideWith((ref) => activity),
      otherUserProfileProvider(_otherUserId).overrideWith(
        (ref) => Future.value(_profile(_otherUserId, _partnerName)),
      ),
      userProfileProvider(
        _currentUserId,
      ).overrideWith((ref) => Stream.value(_profile(_currentUserId, 'Viewer'))),
      userChatIdsProvider(
        _currentUserId,
      ).overrideWith((ref) => Stream.value(<String>{})),
      recentChatsProvider(_currentUserId).overrideWith(
        (ref) => Stream.value([
          ChatModel.fromJsonRpc({
            'match_id': _matchId,
            'other_user_id': _otherUserId,
            'other_user_name': _partnerName,
            'other_user_photos': <String>[],
            'last_message_at': now.toIso8601String(),
          }),
        ]),
      ),
      matchExpiryNowProvider.overrideWith((ref) => Stream.value(now)),
      userRatingSummaryProvider(_otherUserId).overrideWith(
        (ref) async => const UserRatingSummary(
          ratedByCount: 0,
          q1Avg: null,
          q2Avg: null,
          q3Avg: null,
          q4Avg: null,
          q5Avg: null,
          overallAvg: null,
        ),
      ),
    ],
    child: MaterialApp(
      home: Directionality(
        textDirection: direction,
        child: Scaffold(body: MatchBox(match: match)),
      ),
    ),
  );
}

Text _textOf(WidgetTester tester, String data) {
  return tester.widget<Text>(
    find.byWidgetPredicate((w) => w is Text && w.data == data),
  );
}

/// The display name carries invisible bidi marks, so name-bearing sentences
/// are matched by their stable tail.
Finder _sentenceContaining(String tail) =>
    find.byWidgetPredicate((w) => w is Text && (w.data ?? '').contains(tail));

/// Let the pinned-partner chip's auth warm-up timer fire before teardown.
Future<void> _drainTimers(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 11));
  await tester.pump(const Duration(seconds: 51));
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
              'id': _currentUserId,
              'aud': 'authenticated',
              'role': 'authenticated',
              'email': 'test@example.com',
              'app_metadata': <String, dynamic>{},
              'user_metadata': <String, dynamic>{},
              'created_at': '2026-01-01T00:00:00Z',
            }),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('[]', 200, request: request);
      }),
      debug: false,
    );
    await Supabase.instance.client.auth.setSession(
      'test-refresh-token',
      accessToken: _accessToken(),
    );
  });

  testWidgets('their meeting-point suggestion names them and the next step', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        activity: const MeetupActivity(
          topKind: MeetupActivityKind.proposal,
          topOwn: false,
          toolCount: 1,
        ),
      ),
    );
    await tester.pump();

    expect(_sentenceContaining('suggested a meeting point'), findsOneWidget);
    expect(find.text('Choose a place together'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _drainTimers(tester);
  });

  testWidgets('tapping a proposal banner opens the planning screen', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        activity: const MeetupActivity(
          topKind: MeetupActivityKind.proposal,
          topOwn: false,
          toolCount: 1,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Choose a place together'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(MeetupScreen), findsOneWidget);
    expect(find.byType(MeetupHubScreen), findsNothing);
    expect(find.byType(MatchProfileScreen), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await _drainTimers(tester);
  });

  testWidgets('tapping a live-tool banner still opens the hub', (tester) async {
    await tester.pumpWidget(
      _harness(
        activity: const MeetupActivity(
          topKind: MeetupActivityKind.beacon,
          topOwn: true,
          toolCount: 1,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Beacon on'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(MeetupHubScreen), findsOneWidget);
    expect(find.byType(MeetupScreen), findsNothing);
    expect(find.byType(MatchProfileScreen), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await _drainTimers(tester);
  });

  testWidgets('an active meet-up names the place and counts other tools', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        activity: const MeetupActivity(
          topKind: MeetupActivityKind.active,
          topOwn: false,
          toolCount: 2,
          topLabel: 'Dizengoff Square',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Meet-up active — Dizengoff Square'), findsOneWidget);
    expect(find.text('1 more meet-up tool is active'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _drainTimers(tester);
  });

  testWidgets('own beacon is a muted reminder, not an accent', (tester) async {
    await tester.pumpWidget(
      _harness(
        activity: const MeetupActivity(
          topKind: MeetupActivityKind.beacon,
          topOwn: true,
          toolCount: 1,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Beacon on'), findsOneWidget);
    expect(_sentenceContaining('is looking for this shape'), findsOneWidget);

    final context = tester.element(find.byType(MatchBox));
    final expected = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.58);
    expect(_textOf(tester, 'Beacon on').style?.color, expected);
    expect(tester.takeException(), isNull);
    await _drainTimers(tester);
  });

  testWidgets('the banner lays out in RTL without mirroring twice', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        direction: TextDirection.rtl,
        activity: const MeetupActivity(
          topKind: MeetupActivityKind.beacon,
          topOwn: true,
          toolCount: 1,
        ),
      ),
    );
    await tester.pump();

    // One banner chevron; it is `chevron_right`, whose glyph the framework
    // mirrors in RTL. A manual chevron_left here would point the wrong way.
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsNothing);
    expect(find.text('Beacon on'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _drainTimers(tester);
  });

  testWidgets('no live activity leaves the card unchanged', (tester) async {
    await tester.pumpWidget(_harness(activity: null));
    await tester.pump();

    expect(_sentenceContaining('suggested a meeting point'), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(tester.takeException(), isNull);
    await _drainTimers(tester);
  });

  testWidgets('their wave is named by gesture, not called a wave', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        activity: const MeetupActivity(
          topKind: MeetupActivityKind.wave,
          topOwn: false,
          toolCount: 1,
          topGesture: 'jumping',
        ),
      ),
    );
    await tester.pump();

    expect(_sentenceContaining('is signaling: Jumping'), findsOneWidget);
    expect(_sentenceContaining('waved at you'), findsNothing);
    expect(
      find.text('Look for this gesture so you can spot each other.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await _drainTimers(tester);
  });

  testWidgets('your own wave says which gesture you sent', (tester) async {
    await tester.pumpWidget(
      _harness(
        activity: const MeetupActivity(
          topKind: MeetupActivityKind.wave,
          topOwn: true,
          toolCount: 1,
          topGesture: 'arms_wide',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('You sent Arms wide'), findsOneWidget);
    expect(find.text('You waved'), findsNothing);
    expect(tester.takeException(), isNull);
    await _drainTimers(tester);
  });

  testWidgets('a wave recorded without a gesture keeps the generic copy', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        activity: const MeetupActivity(
          topKind: MeetupActivityKind.wave,
          topOwn: false,
          toolCount: 1,
        ),
      ),
    );
    await tester.pump();

    expect(_sentenceContaining('waved at you'), findsOneWidget);
    expect(find.text('Raise your hand so they can see you.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _drainTimers(tester);
  });
}
