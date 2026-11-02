import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matchme/models/chat_model.dart';
import 'package:matchme/models/location_share_session.dart';
import 'package:matchme/models/meetup_models.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/location_share_provider.dart';
import 'package:matchme/providers/meetup_alerts_provider.dart';
import 'package:matchme/providers/meetup_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/screens/meetup/beacon_screen.dart';
import 'package:matchme/screens/meetup/meetup_hub_screen.dart';
import 'package:matchme/theme/app_theme_tokens.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _matchId = 'hub-match';
const _otherUserId = 'hub-partner';
const _name = 'Maya L.';

/// The relocated intro sentence: one reassurance, shown once, under the tiles.
const _footnote =
    'Choose what helps right now. Nothing is shared until you choose it.';

// The harness resolves every key through LocalizationState's built-in English
// defaults, so these tests read the copy that actually ships and a key that
// only exists in the screen (a typo, a key dropped from locale_provider.dart)
// shows up as "[key]" — which the placeholder guard below fails on.
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

class _FakeMeetupNotifier extends MeetupNotifier {
  _FakeMeetupNotifier(super.matchId, this._state);

  final MeetupState _state;

  @override
  MeetupState build() => _state;

  @override
  Future<String?> clearSignal(MeetupSignalType type) async {
    state = state.copyWith(
      signals: state.signals
          .where(
            (signal) =>
                !(signal.senderId == state.currentUserId &&
                    signal.type == type),
          )
          .toList(growable: false),
    );
    return null;
  }
}

class _FakeLocationShareNotifier extends LocationShareNotifier {
  _FakeLocationShareNotifier(this._session);

  final LocationShareSession? _session;

  @override
  LocationShareSession? build() => _session;
}

class _FakeSurfacesNotifier extends MeetupSurfacesNotifier {
  @override
  Map<String, int> build() => const {};

  @override
  void enter(String matchId) {}

  @override
  void exit(String matchId) {}
}

MeetupState _plannedState({
  bool active = true,
  bool withPlace = true,
  bool withBeacon = false,
  bool withSignal = false,
  Duration signalLeft = const Duration(seconds: 45),
  bool withEarlierSignal = false,
}) {
  final now = DateTime.now();
  const sessionId = 'plan-session';
  return MeetupState(
    loading: false,
    currentUserId: 'hub-viewer',
    session: MeetupSession(
      id: sessionId,
      matchId: _matchId,
      createdBy: 'hub-viewer',
      status: active ? MeetupStatus.active : MeetupStatus.proposed,
      origin: MeetupOrigin.proximity,
      proposedBy: active ? 'hub-viewer' : _otherUserId,
      proposalRound: 1,
      createdAt: now.subtract(const Duration(minutes: 5)),
      updatedAt: now,
      expiresAt: now.add(const Duration(hours: 4)),
      chosenLandmarkId: withPlace && active ? 'lm-1' : null,
    ),
    landmarks: withPlace
        ? [
            MeetupLandmark(
              id: 'lm-1',
              sessionId: sessionId,
              proposerId: 'hub-viewer',
              round: 1,
              label: 'Central Station',
              category: 'transit',
              createdAt: now.subtract(const Duration(minutes: 4)),
              distanceMeters: 140,
            ),
          ]
        : const [],
    signals: [
      if (withBeacon)
        MeetupSignal(
          id: 'beacon-1',
          sessionId: null,
          senderId: 'hub-viewer',
          type: MeetupSignalType.beacon,
          payload: const <String, dynamic>{},
          createdAt: now,
          expiresAt: now.add(const Duration(minutes: 2)),
        ),
      // Sent 15 seconds ago, so a 45-second window left is the server's
      // default 60-second one; a longer signalLeft simulates a retuned
      // meetup.wave_expiry_seconds.
      if (withSignal && withEarlierSignal)
        MeetupSignal(
          id: 'wave-0',
          sessionId: null,
          senderId: 'hub-viewer',
          type: MeetupSignalType.wave,
          payload: const <String, dynamic>{'gesture': kMeetupGestureJumping},
          createdAt: now.subtract(const Duration(seconds: 40)),
          expiresAt: now.add(const Duration(seconds: 20)),
        ),
      if (withSignal)
        MeetupSignal(
          id: 'wave-1',
          sessionId: null,
          senderId: 'hub-viewer',
          type: MeetupSignalType.wave,
          payload: const <String, dynamic>{'gesture': kMeetupGestureHandsUp},
          createdAt: now.subtract(const Duration(seconds: 15)),
          expiresAt: now.add(signalLeft),
        ),
    ],
  );
}

Widget _harness({
  TextDirection direction = TextDirection.ltr,
  Brightness brightness = Brightness.light,
  double scale = 1,
  MeetupState? state,
  LocationShareSession? share,
  List<String> profilePhotos = const [],
  List<String> cachedPhotos = const [],
}) {
  return ProviderScope(
    overrides: [
      localizationProvider.overrideWith(_TestLocalization.new),
      otherUserProfileProvider.overrideWith(
        (ref, userId) async => UserProfile.fromMap({
          'id': userId,
          'name': _name,
          'photos': profilePhotos,
        }),
      ),
      recentChatsProvider.overrideWith(
        (ref, userId) => Stream.value([
          if (cachedPhotos.isNotEmpty)
            ChatModel(
              matchId: _matchId,
              otherUserId: _otherUserId,
              otherUserName: _name,
              otherUserPhotos: cachedPhotos,
              lastMessage: '',
              lastMessageId: '',
              lastMessageAt: DateTime.utc(2024),
              unreadCount: 0,
            ),
        ]),
      ),
      meetupProvider(_matchId).overrideWith(
        () => _FakeMeetupNotifier(
          _matchId,
          state ??
              const MeetupState(loading: false, currentUserId: 'hub-viewer'),
        ),
      ),
      locationShareProvider.overrideWith(
        () => _FakeLocationShareNotifier(share),
      ),
      meetupSurfacesProvider.overrideWith(_FakeSurfacesNotifier.new),
    ],
    child: MaterialApp(
      // The group and tiles are built from surfaceContainerLow + outlineVariant
      // hairlines, which resolve very differently per brightness.
      theme: brightness == Brightness.dark
          ? AppThemeTokens.darkThemeData(textTheme: ThemeData.dark().textTheme)
          : AppThemeTokens.lightThemeData(
              textTheme: ThemeData.light().textTheme,
            ),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: Directionality(
            textDirection: direction,
            child: const MeetupHubScreen(
              matchId: _matchId,
              otherUserId: _otherUserId,
              otherUserName: _name,
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _usePhone(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

/// Bottom sheets animate in and out; the hub also rebuilds on a one-second
/// ticker, so the settling is pumped by hand instead of [WidgetTester
/// .pumpAndSettle].
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

Future<void> _openBeaconExplainer(WidgetTester tester) async {
  // The three tile explainers live in one fixed-height row, so bringing the
  // first one into view brings all three. On the narrow phone at large text
  // that row sits below the fold, and a tap on an unbuilt-but-scrolled-off
  // widget misses.
  await tester.scrollUntilVisible(
    find.text('How it works').first,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  // ensureVisible moves the scroll offset without laying out, so the tap
  // would otherwise be aimed at the pre-scroll coordinates.
  await tester.pump();
  await tester.tap(find.text('How it works').at(1));
  await _settle(tester);
}

Future<void> _closeSheet(WidgetTester tester) async {
  await tester.tapAt(const Offset(10, 10));
  await _settle(tester);
}

Future<void> _disposeHub(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

/// ShrinkText hands the string to AutoSizeText, which repaints it at the
/// largest size that fits its box, so the theme ramp alone proves nothing.
/// This reads the size actually rendered. It is also the pessimistic case:
/// the test font draws every glyph one em wide, roughly twice Roboto, so a
/// label that keeps 12 here has room on a real device.
void _expectAtLeast12(WidgetTester tester, List<String> labels) {
  for (final label in labels) {
    for (final element in find.text(label).evaluate()) {
      final widget = element.widget as Text;
      final rich = tester.widget<RichText>(
        find.descendant(
          of: find.byWidget(widget),
          matching: find.byType(RichText),
        ),
      );
      expect(
        rich.text.style?.fontSize,
        greaterThanOrEqualTo(12.0),
        reason: '"$label" rendered at ${rich.text.style?.fontSize}',
      );
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://test-project.supabase.co',
      publishableKey: 'test-publishable-key',
      httpClient: MockClient(
        (request) async => http.Response('{}', 200, request: request),
      ),
    );
  });

  testWidgets('the hub face carries names, states and actions only', (
    tester,
  ) async {
    await _usePhone(tester, const Size(360, 1200));
    await tester.pumpWidget(_harness());
    await tester.pump();

    // The old header block became the toolbar.
    expect(find.text('Meet up with $_name'), findsOneWidget);
    expect(find.text('Nothing set yet'), findsNWidgets(2));

    // Two state rows and three tiles, each naming its tool.
    expect(find.text('Meeting point'), findsOneWidget);
    expect(find.text('Live location'), findsOneWidget);
    expect(find.text('Not sharing'), findsOneWidget);
    expect(find.text('Suggest places'), findsOneWidget);
    expect(find.text('Start sharing'), findsOneWidget);
    expect(find.text('WHEN YOU ARE CLOSE'), findsOneWidget);
    expect(find.text('Signal'), findsOneWidget);
    expect(find.text('Beacon'), findsOneWidget);
    expect(find.text('Spot me'), findsOneWidget);
    expect(find.text('Compare these options'), findsOneWidget);
    // The idle hub is 524 dp of body and never scrolls on a 1200 dp viewport.
    // That is 51 dp more than the old 12/11 type cost (473), and it is the
    // price of the 16/14 ramp: a row title and a status line each carry two
    // more points, and the tile row grew to 132 so an explainer label can wrap
    // instead of shrinking below the floor.
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    expect(position.maxScrollExtent, 0.0);
    expect(
      tester.getBottomRight(find.text(_footnote)).dy -
          tester.getTopLeft(find.byType(ListView)).dy,
      lessThan(555),
    );
    expect(find.text(_footnote), findsOneWidget);

    // The tile verbs are the tap targets, not text competing with the names.
    expect(find.byTooltip('Send a signal'), findsOneWidget);
    expect(find.byTooltip('Show beacon'), findsOneWidget);
    expect(find.byTooltip('Send a Spot me'), findsOneWidget);

    expect(tester.takeException(), isNull);
    await _disposeHub(tester);
  });

  testWidgets('the matched profile photo appears in the hub header', (
    tester,
  ) async {
    await _usePhone(tester, const Size(360, 1200));
    await tester.pumpWidget(
      _harness(profilePhotos: const ['profiles/matched-user.jpg']),
    );
    await tester.pump();

    expect(find.byType(SignedImage), findsOneWidget);
    expect(
      tester.widget<SignedImage>(find.byType(SignedImage)).source,
      'profiles/matched-user.jpg',
    );
    expect(tester.getSize(find.byType(SignedImage)), const Size(44, 44));
    expect(tester.takeException(), isNull);
    await _disposeHub(tester);
  });

  testWidgets('the hub header name is larger than its supporting text', (
    tester,
  ) async {
    await _usePhone(tester, const Size(360, 1200));
    await tester.pumpWidget(_harness());
    await tester.pump();

    final titleRichText = tester.widget<RichText>(
      find.descendant(
        of: find.text('Meet up with $_name'),
        matching: find.byType(RichText),
      ),
    );
    final subtitleRichText = tester.widget<RichText>(
      find.descendant(
        of: find.text('Nothing set yet').first,
        matching: find.byType(RichText),
      ),
    );
    expect(
      titleRichText.text.style?.fontSize,
      greaterThan(subtitleRichText.text.style?.fontSize ?? 0),
    );
    expect(tester.takeException(), isNull);
    await _disposeHub(tester);
  });

  testWidgets('the cached chat photo fills in when profile photos are absent', (
    tester,
  ) async {
    await _usePhone(tester, const Size(360, 1200));
    await tester.pumpWidget(
      _harness(cachedPhotos: const ['profiles/cached-matched-user.jpg']),
    );
    await tester.pump();

    expect(find.byType(SignedImage), findsOneWidget);
    expect(
      tester.widget<SignedImage>(find.byType(SignedImage)).source,
      'profiles/cached-matched-user.jpg',
    );
    expect(tester.takeException(), isNull);
    await _disposeHub(tester);
  });

  testWidgets('explanations stay off the face until asked for', (tester) async {
    await _usePhone(tester, const Size(360, 1200));
    await tester.pumpWidget(_harness());
    await tester.pump();

    // One "How it works" per tile in the body, one info button per row.
    expect(find.text('How it works'), findsNWidgets(3));
    expect(find.byTooltip('How it works'), findsNWidgets(2));

    // None of the sentences the explainers carry.
    expect(
      find.text('Suggest public places nearby and agree on one together.'),
      findsNothing,
    );
    expect(
      find.text(
        'Maya L. sees your dot on a map. You see theirs if they share back.',
      ),
      findsNothing,
    );
    expect(
      find.text(
        'Wave, raise both hands, jump, or open your arms to catch their eye.',
      ),
      findsNothing,
    );
    expect(
      find.text('Hold up your phone with a bright shape they can look for.'),
      findsNothing,
    );
    expect(
      find.text(
        'Send a selfie and what you are wearing so they recognize you.',
      ),
      findsNothing,
    );

    // No timers anywhere on the hub.
    expect(find.text('60 seconds'), findsNothing);
    expect(find.text('2 minutes'), findsNothing);
    expect(find.textContaining('15 min'), findsNothing);

    // The grouping card, its details toggle and the removed paragraphs stay
    // removed.
    expect(find.text('Get noticed'), findsNothing);
    expect(find.byTooltip('Show details'), findsNothing);
    expect(
      find.text('Quick ways to catch their eye — no map needed.'),
      findsNothing,
    );
    expect(find.textContaining('These tools work only with'), findsNothing);

    expect(tester.takeException(), isNull);
    await _disposeHub(tester);
  });

  testWidgets('no unresolved translation key is shown to the user', (
    tester,
  ) async {
    await _usePhone(tester, const Size(360, 1200));
    await tester.pumpWidget(_harness(state: _plannedState()));
    await tester.pump();

    expect(find.textContaining('['), findsNothing);

    await _openBeaconExplainer(tester);
    expect(find.textContaining('['), findsNothing);
    await _closeSheet(tester);

    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byTooltip('How it works').at(i));
      await _settle(tester);
      expect(find.textContaining('['), findsNothing);
      await _closeSheet(tester);
    }

    expect(tester.takeException(), isNull);
    await _disposeHub(tester);
  });

  testWidgets(
    'the meeting point explainer explains and then offers the action',
    (tester) async {
      await _usePhone(tester, const Size(360, 1200));
      await tester.pumpWidget(_harness());
      await tester.pump();

      await tester.tap(find.byTooltip('How it works').first);
      await _settle(tester);

      expect(
        find.text('Your location is used once to find places · Not saved'),
        findsOneWidget,
      );
      expect(
        find.text('Suggest public places nearby and agree on one together.'),
        findsOneWidget,
      );
      expect(find.text('Agreeing where to meet'), findsOneWidget);
      expect(find.text('The public meeting point'), findsOneWidget);
      expect(find.text('Suggest places and pick one together'), findsOneWidget);
      expect(find.text('You end it'), findsOneWidget);
      expect(find.text('Used once to find places'), findsOneWidget);
      // The timer column is now a plain-language ending, and no duration.
      expect(find.text('How it ends'), findsOneWidget);
      expect(find.text('Lasts'), findsNothing);
      expect(find.text('Not now'), findsOneWidget);

      await _closeSheet(tester);
      expect(find.text('How it ends'), findsNothing);

      expect(tester.takeException(), isNull);
      await _disposeHub(tester);
    },
  );

  testWidgets('the Beacon explainer says what to do with the phone', (
    tester,
  ) async {
    await _usePhone(tester, const Size(360, 1200));
    await tester.pumpWidget(_harness());
    await tester.pump();

    await _openBeaconExplainer(tester);

    expect(
      find.text('Hold up your phone with a bright shape they can look for.'),
      findsOneWidget,
    );
    expect(
      find.text('They see a shape on your screen · No location'),
      findsOneWidget,
    );
    expect(find.text('Hold your phone up, screen facing them'), findsOneWidget);
    expect(find.text('Turns off on its own, or you hide it'), findsOneWidget);
    expect(find.text('Being seen in a crowd'), findsOneWidget);

    expect(tester.takeException(), isNull);
    await _disposeHub(tester);
  });

  testWidgets('the live location explainer keeps the duration the user chose', (
    tester,
  ) async {
    await _usePhone(tester, const Size(360, 1200));
    await tester.pumpWidget(_harness());
    await tester.pump();

    await tester.tap(find.byTooltip('How it works').last);
    await _settle(tester);

    expect(find.text('Stops at the time you chose'), findsOneWidget);
    expect(
      find.text('Tap "Start sharing" and choose how long'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Maya L. sees your dot on a map. You see theirs if they share back.',
      ),
      findsOneWidget,
    );

    expect(tester.takeException(), isNull);
    await _disposeHub(tester);
  });

  testWidgets('tapping a tile acts: Signal opens the gesture picker', (
    tester,
  ) async {
    await _usePhone(tester, const Size(360, 1200));
    await tester.pumpWidget(_harness());
    await tester.pump();

    await tester.tap(find.text('Signal'));
    await _settle(tester);

    expect(find.text('Choose a gesture'), findsOneWidget);
    expect(find.text('Wave'), findsOneWidget);
    expect(find.text('Arms wide'), findsOneWidget);

    await _closeSheet(tester);
    expect(find.text('Choose a gesture'), findsNothing);

    expect(tester.takeException(), isNull);
    await _disposeHub(tester);
  });

  testWidgets(
    'an agreed place and an active share show state, and live keeps its countdown',
    (tester) async {
      await _usePhone(tester, const Size(360, 1200));
      await tester.pumpWidget(
        _harness(
          state: _plannedState(),
          share: LocationShareSession(
            matchId: _matchId,
            myUserId: 'hub-viewer',
            otherUserId: _otherUserId,
            otherUserName: _name,
            myStatus: ShareStatus.sharing,
            otherStatus: ShareStatus.sharing,
            expiresAt: DateTime.now().add(
              const Duration(minutes: 42, seconds: 30),
            ),
          ),
        ),
      );
      await tester.pump();

      // The toolbar carries the place instead of the empty-state line.
      expect(find.text('Nothing set yet'), findsNothing);
      expect(find.textContaining('Central Station'), findsNWidgets(2));

      // The rows switch to status copy and their action becomes Manage.
      expect(find.text('Not sharing'), findsNothing);
      expect(find.text('View map'), findsOneWidget);
      expect(find.text('Manage'), findsOneWidget);

      // A chosen deadline is the user's own number, so it stays visible even
      // when both sides share — the bare status line means the time was dropped.
      expect(find.text('You are both sharing location'), findsNothing);
      expect(
        find.textContaining('You are both sharing location'),
        findsOneWidget,
      );
      expect(find.textContaining('You are sharing location'), findsNothing);
      // The deadline is spelled out: "for another 42 minutes", never "42m".
      expect(find.textContaining('for another 42 minutes'), findsOneWidget);

      expect(tester.takeException(), isNull);
      await _disposeHub(tester);
    },
  );

  testWidgets('a one-way share states the remaining time', (tester) async {
    await _usePhone(tester, const Size(360, 1200));
    await tester.pumpWidget(
      _harness(
        share: LocationShareSession(
          matchId: _matchId,
          myUserId: 'hub-viewer',
          otherUserId: _otherUserId,
          otherUserName: _name,
          myStatus: ShareStatus.sharing,
          expiresAt: DateTime.now().add(
            const Duration(minutes: 42, seconds: 30),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('You are sharing location'), findsOneWidget);
    expect(find.textContaining('for another 42 minutes'), findsOneWidget);
    expect(find.text('Start sharing'), findsNothing);
    expect(find.text('Manage'), findsOneWidget);

    expect(tester.takeException(), isNull);
    await _disposeHub(tester);
  });

  testWidgets('an active beacon marks its tile and retargets it', (
    tester,
  ) async {
    await _usePhone(tester, const Size(360, 1200));
    await tester.pumpWidget(
      _harness(state: _plannedState(withPlace: false, withBeacon: true)),
    );
    await tester.pump();

    expect(find.text('Beacon on'), findsOneWidget);
    expect(find.byType(MeetupBeaconShape), findsOneWidget);
    expect(find.byTooltip('Open beacon'), findsOneWidget);
    expect(find.byTooltip('Show beacon'), findsNothing);

    expect(tester.takeException(), isNull);
    await _disposeHub(tester);
  });

  testWidgets('a signal you sent stays on the hub', (tester) async {
    await _usePhone(tester, const Size(360, 1200));
    await tester.pumpWidget(_harness(state: _plannedState(withSignal: true)));
    await tester.pump();

    // Sending used to leave only a banner that vanished: the hub looked
    // exactly as before. Now the sender sees what went out, to whom, and for
    // how long the other device can still see it.
    expect(find.text('You sent $_name a signal'), findsOneWidget);
    expect(find.text('Both hands up'), findsOneWidget);
    expect(find.text('Still visible for another 45 seconds'), findsOneWidget);
    expect(find.text('Sent'), findsOneWidget);
    expect(find.byTooltip('Send again'), findsOneWidget);
    expect(find.byTooltip('Send a signal'), findsNothing);

    expect(tester.takeException(), isNull);
    await _disposeHub(tester);
  });

  testWidgets('a new gesture replaces the one sent before it', (tester) async {
    await _usePhone(tester, const Size(360, 1200));
    await tester.pumpWidget(
      _harness(state: _plannedState(withSignal: true, withEarlierSignal: true)),
    );
    await tester.pump();

    // Sending a second signal used to be refused until the first ran out, so
    // changing your mind was impossible for a minute. Now the server deletes
    // the row it replaces, and whichever device still holds both rows shows
    // only the newest: one card, one gesture, one countdown.
    expect(find.text('You sent $_name a signal'), findsOneWidget);
    expect(find.text('Both hands up'), findsOneWidget);
    expect(find.text('Jumping'), findsNothing);
    expect(find.text('Still visible for another 45 seconds'), findsOneWidget);

    expect(tester.takeException(), isNull);
    await _disposeHub(tester);
  });

  testWidgets('the sent signal carries the time the server gave it', (
    tester,
  ) async {
    await _usePhone(tester, const Size(360, 1200));
    await tester.pumpWidget(
      _harness(
        state: _plannedState(
          withSignal: true,
          signalLeft: const Duration(seconds: 7),
        ),
      ),
    );
    await tester.pump();

    // The countdown reads the row's own expiry, so an admin retuning
    // meetup.wave_expiry_seconds cannot make the app claim a longer life than
    // the server granted.
    expect(find.text('Still visible for another 7 seconds'), findsOneWidget);
    expect(find.text('Still visible for another 45 seconds'), findsNothing);

    // An admin can retune the window upward; the line switches to minutes.
    // A fresh scope, because Riverpod keeps the provider it already built.
    await _disposeHub(tester);
    await tester.pumpWidget(
      _harness(
        state: _plannedState(
          withSignal: true,
          signalLeft: const Duration(minutes: 2),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Still visible for another 2 minutes'), findsOneWidget);

    expect(tester.takeException(), isNull);
    await _disposeHub(tester);
  });

  testWidgets('a signal that ran out leaves no trace', (tester) async {
    await _usePhone(tester, const Size(360, 1200));
    await tester.pumpWidget(
      _harness(
        state: _plannedState(
          withSignal: true,
          signalLeft: const Duration(seconds: -20),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('You sent'), findsNothing);
    expect(find.text('Sent'), findsNothing);
    expect(find.byTooltip('Send a signal'), findsOneWidget);

    expect(tester.takeException(), isNull);
    await _disposeHub(tester);
  });

  testWidgets('dismissing your own signal clears it and re-arms the tile', (
    tester,
  ) async {
    await _usePhone(tester, const Size(360, 1200));
    await tester.pumpWidget(_harness(state: _plannedState(withSignal: true)));
    await tester.pump();

    await tester.tap(find.byTooltip('Close'));
    await tester.pump();

    expect(find.text('You sent $_name a signal'), findsNothing);
    expect(find.text('Sent'), findsNothing);
    expect(find.byTooltip('Send a signal'), findsOneWidget);

    expect(tester.takeException(), isNull);
    await _disposeHub(tester);
  });

  testWidgets('the hub lays out on a narrow phone with large text', (
    tester,
  ) async {
    await _usePhone(tester, const Size(320, 1200));
    await tester.pumpWidget(
      _harness(
        scale: 1.3,
        state: _plannedState(withBeacon: true),
        share: LocationShareSession(
          matchId: _matchId,
          myUserId: 'hub-viewer',
          otherUserId: _otherUserId,
          otherUserName: _name,
          myStatus: ShareStatus.sharing,
          otherStatus: ShareStatus.sharing,
          expiresAt: DateTime.now().add(
            const Duration(minutes: 42, seconds: 30),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Meeting point'), findsOneWidget);

    // The subtitles wrap instead of clipping, so at 1.3 scale on 320 dp the
    // tools section starts below the fold and the test scrolls to it the way a
    // user would.
    await tester.scrollUntilVisible(
      find.text('Spot me'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Spot me'), findsOneWidget);
    expect(find.text('Beacon on'), findsOneWidget);

    await _openBeaconExplainer(tester);
    expect(find.text('You do'), findsOneWidget);
    await _closeSheet(tester);

    await tester.scrollUntilVisible(
      find.text('Compare these options'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Compare these options'));
    await _settle(tester);
    // The compare sheet relabels its timer column for all five tools at once.
    expect(find.text('How it ends'), findsNWidgets(5));
    expect(find.text('Lasts'), findsNothing);

    expect(tester.takeException(), isNull);
    await _disposeHub(tester);
  });

  testWidgets('no label on the hub face renders below the 12 floor', (
    tester,
  ) async {
    await _usePhone(tester, const Size(360, 740));
    await tester.pumpWidget(_harness());
    await tester.pump();

    _expectAtLeast12(tester, <String>[
      'Signal',
      'Beacon',
      'Spot me',
      'How it works',
      'Meeting point',
      'Live location',
      'Suggest places',
      'Start sharing',
      'Compare these options',
      'WHEN YOU ARE CLOSE',
      'NEW',
    ]);

    expect(tester.takeException(), isNull);
    await _disposeHub(tester);
  });

  testWidgets('the sent signal card keeps the 12 floor', (tester) async {
    await _usePhone(tester, const Size(360, 740));
    await tester.pumpWidget(_harness(state: _plannedState(withSignal: true)));
    await tester.pump();

    // The tile pill sits in a third of the tool row and the card body in a
    // fixed-width column, the two places this copy could have been squeezed.
    _expectAtLeast12(tester, <String>[
      'Sent',
      'You sent $_name a signal',
      'Both hands up',
      'Still visible for another 45 seconds',
    ]);

    expect(tester.takeException(), isNull);
    await _disposeHub(tester);
  });

  testWidgets('the idle hub fits a small phone without scrolling', (
    tester,
  ) async {
    await _usePhone(tester, const Size(360, 740));
    await tester.pumpWidget(_harness(scale: 1.15));
    await tester.pump();

    // Everything, including the last line, is laid out on one screen.
    expect(find.text(_footnote), findsOneWidget);
    expect(
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .maxScrollExtent,
      0.0,
    );

    expect(tester.takeException(), isNull);
    await _disposeHub(tester);
  });

  testWidgets('the idle hub on a 16:9 phone scrolls a little and hides nothing', (
    tester,
  ) async {
    // 360x640 is the old 720p 16:9 class. At the 16/14 ramp the idle hub needs
    // 694 dp there, so it scrolls by 54 — which is what WhatsApp and Telegram
    // do on that hardware. What must not happen is content becoming unreachable
    // or clipped, so the guard is the last line being revealed, not a zero
    // scroll extent.
    await _usePhone(tester, const Size(360, 640));
    await tester.pumpWidget(_harness(scale: 1.15));
    await tester.pump();

    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    expect(position.maxScrollExtent, lessThan(80.0));

    await tester.scrollUntilVisible(
      find.text(_footnote).first,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(find.text(_footnote), findsOneWidget);
    expect(tester.getBottomRight(find.text(_footnote)).dy, lessThan(640.0));

    expect(tester.takeException(), isNull);
    await _disposeHub(tester);
  });

  testWidgets('the hub and its explainers keep their surfaces in dark mode', (
    tester,
  ) async {
    await _usePhone(tester, const Size(360, 1200));
    await tester.pumpWidget(
      _harness(
        brightness: Brightness.dark,
        state: _plannedState(withPlace: false, withBeacon: true),
      ),
    );
    await tester.pump();

    expect(find.text('Meeting point'), findsOneWidget);
    expect(find.text('Beacon on'), findsOneWidget);
    expect(find.text('How it works'), findsNWidgets(3));
    expect(find.textContaining('['), findsNothing);

    await _openBeaconExplainer(tester);
    expect(find.text('Hold your phone up, screen facing them'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);

    expect(tester.takeException(), isNull);
    await _disposeHub(tester);
  });

  testWidgets('the hub lays out in RTL', (tester) async {
    await _usePhone(tester, const Size(360, 1200));
    await tester.pumpWidget(
      _harness(
        direction: TextDirection.rtl,
        state: _plannedState(withSignal: true),
      ),
    );
    await tester.pump();

    expect(find.text('Meeting point'), findsOneWidget);
    expect(find.text('How it works'), findsNWidgets(3));
    expect(find.byTooltip('How it works'), findsNWidgets(2));
    // Hebrew names the tool תנועה and the countdown lands at the end of the
    // line; the card has to hold both without clipping in a mirrored row.
    expect(find.text('You sent $_name a signal'), findsOneWidget);
    expect(find.text('Sent'), findsOneWidget);

    await _openBeaconExplainer(tester);
    expect(find.text('You do'), findsOneWidget);

    expect(tester.takeException(), isNull);
    await _disposeHub(tester);
  });
}
