// Spot me card: age label, newness window, gender mapping and the incoming
// hero's text content. The figure itself is decorative and draws the same
// values the rows state, so the rows are what these tests assert.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/models/meetup_models.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/screens/meetup/meetup_coordination_widgets.dart';
import 'package:matchme/screens/meetup/meetup_outfit_figure.dart';
import 'package:matchme/services/offline_image_cache.dart';
import 'package:matchme/widgets/signed_image.dart';

// 1x1 transparent PNG, served from the cache override so the photo hero
// mounts without touching Supabase.
final Uint8List _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
  '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

LocalizationState _l10n({String code = 'en'}) => LocalizationState(
  currentLocale: Locale(code),
  textDirection: code == 'he' ? TextDirection.rtl : TextDirection.ltr,
  strings: const {},
  supportedLanguages: const [],
  contentLanguageCode: code,
);

MeetupSpotCard _card({
  required DateTime createdAt,
  Map<String, dynamic> outfit = const <String, dynamic>{},
  String? note,
  String storagePath = '',
}) {
  final now = DateTime.now().toUtc();
  return MeetupSpotCard(
    id: 'spot-1',
    sessionId: null,
    senderId: 'other-user',
    kind: 'self',
    storagePath: storagePath,
    outfit: outfit,
    note: note,
    createdAt: createdAt.toUtc(),
    expiresAt: now.add(const Duration(hours: 2)),
  );
}

Future<void> _pumpCard(
  WidgetTester tester,
  MeetupSpotCard card, {
  LocalizationState? l10n,
  double scale = 1,
  TextDirection direction = TextDirection.ltr,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localizationProvider.overrideWithValue(l10n ?? _l10n()),
        otherUserProfileProvider(
          'other-user',
        ).overrideWith((ref) => Future<UserProfile?>.value(null)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: Directionality(
                  textDirection: direction,
                  child: MeetupIncomingSpotCard(
                    card: card,
                    matchId: 'match-1',
                    otherUserId: 'other-user',
                    otherUserName: 'Robin L.',
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('age label', () {
    final now = DateTime.utc(2026, 10, 27, 12);

    test('under a minute reads "just now"', () {
      expect(
        meetupSpotAgeLabel(
          now.subtract(const Duration(seconds: 40)),
          _l10n(),
          now: now,
        ),
        'just now',
      );
    });

    test('minutes and hours are spelled out, never abbreviated', () {
      expect(
        meetupSpotAgeLabel(
          now.subtract(const Duration(minutes: 5)),
          _l10n(),
          now: now,
        ),
        '5 minutes ago',
      );
      expect(
        meetupSpotAgeLabel(
          now.subtract(const Duration(minutes: 60)),
          _l10n(),
          now: now,
        ),
        '1 hour ago',
      );
      expect(
        meetupSpotAgeLabel(
          now.subtract(const Duration(minutes: 83)),
          _l10n(),
          now: now,
        ),
        '1 hour and 23 minutes ago',
      );
    });

    test('the new window ends at 30 minutes', () {
      expect(
        meetupSpotIsNew(now.subtract(const Duration(minutes: 29)), now: now),
        isTrue,
      );
      expect(
        meetupSpotIsNew(now.subtract(const Duration(minutes: 30)), now: now),
        isFalse,
      );
    });
  });

  group('gender and outfit mapping', () {
    test('profile genders collapse to three silhouettes', () {
      expect(
        meetupOutfitGenderFromProfile('female'),
        MeetupOutfitGender.female,
      );
      expect(
        meetupOutfitGenderFromProfile('gender_female'),
        MeetupOutfitGender.female,
      );
      expect(meetupOutfitGenderFromProfile('M'), MeetupOutfitGender.male);
      expect(
        meetupOutfitGenderFromProfile('non-binary'),
        MeetupOutfitGender.neutral,
      );
      expect(meetupOutfitGenderFromProfile(null), MeetupOutfitGender.neutral);
    });

    test('a dress hides pants unless they were explicitly shared', () {
      const dress = MeetupOutfitSpec(shirt: 'dress', shirtColor: 'burgundy');
      expect(dress.showsPants, isFalse);

      const dressWithLeggings = MeetupOutfitSpec(
        shirt: 'dress',
        pants: 'trousers',
      );
      expect(dressWithLeggings.showsPants, isTrue);
    });

    test('the stored map keeps only non-empty values', () {
      final spec = MeetupOutfitSpec.fromMap(const {
        'shirt': 'short_sleeve',
        'shirt_color': ' green ',
        'pants': '',
        'note': 'ignored',
      });
      expect(spec.shirt, 'short_sleeve');
      expect(spec.shirtColor, 'green');
      expect(spec.pants, isNull);
      expect(spec.shoes, isNull);
    });
  });

  group('incoming hero', () {
    setUp(() {
      OfflineImageCache.debugReadOverride = (_) async => _onePixelPng;
    });

    tearDown(() {
      OfflineImageCache.debugReadOverride = null;
    });

    testWidgets('shows the name, new pill, age, figure and outfit rows', (
      tester,
    ) async {
      final card = _card(
        createdAt: DateTime.now(),
        outfit: const {
          'shirt': 'short_sleeve',
          'shirt_color': 'green',
          'pants': 'trousers',
          'pants_color': 'olive',
          'shoes': 'sneakers',
          'shoes_color': 'white',
        },
        note: 'I am by the north entrance.',
      );

      await _pumpCard(tester, card);

      expect(find.text('NEW'), findsOneWidget);
      expect(find.text('just now'), findsOneWidget);
      expect(find.text('WHAT THEY’RE WEARING'), findsOneWidget);
      expect(find.text('Short sleeve, Green'), findsOneWidget);
      expect(find.text('Dress pants, Olive'), findsOneWidget);
      expect(find.text('Sneakers, White'), findsOneWidget);
      expect(find.text('No photo shared'), findsOneWidget);
      expect(find.byType(MeetupOutfitFigureStage), findsOneWidget);
      expect(find.byType(MeetupOutfitFigure), findsOneWidget);
      expect(find.textContaining('Robin L.', findRichText: true), findsWidgets);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an older card loses the pill and shows hours', (tester) async {
      final card = _card(
        createdAt: DateTime.now().subtract(const Duration(minutes: 125)),
        outfit: const {'shirt': 'long_sleeve', 'shirt_color': 'navy'},
      );

      await _pumpCard(tester, card);

      expect(find.text('NEW'), findsNothing);
      expect(find.text('2 hours and 5 minutes ago'), findsOneWidget);
      expect(find.text('Long sleeve, Navy'), findsOneWidget);
      expect(find.text('No outfit details shared'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the spelled-out age fits a narrow phone at large text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320 * 3, 640 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      final card = _card(
        createdAt: DateTime.now().subtract(const Duration(minutes: 125)),
        outfit: const {'shirt': 'long_sleeve', 'shirt_color': 'navy'},
      );

      await _pumpCard(
        tester,
        card,
        scale: 1.3,
        direction: TextDirection.rtl,
      );

      expect(find.text('2 hours and 5 minutes ago'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a photo-less card without outfit values shows only the line', (
      tester,
    ) async {
      await _pumpCard(tester, _card(createdAt: DateTime.now()));

      expect(find.text('No outfit details shared'), findsOneWidget);
      expect(find.text('WHAT THEY’RE WEARING'), findsNothing);
      expect(find.byType(MeetupOutfitFigureStage), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a photo card without outfit values drops the wearing block', (
      tester,
    ) async {
      final card = _card(
        createdAt: DateTime.now(),
        storagePath: 'other-user/spot-photo.jpg',
      );

      await _pumpCard(tester, card);

      expect(find.byType(SignedImage), findsOneWidget);
      expect(find.text('WHAT THEY’RE WEARING'), findsNothing);
      expect(find.text('No outfit details shared'), findsNothing);
      expect(find.byType(MeetupOutfitFigureStage), findsNothing);
      expect(find.byType(MeetupOutfitFigure), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a photo card without outfit values still shows the note', (
      tester,
    ) async {
      final card = _card(
        createdAt: DateTime.now(),
        storagePath: 'other-user/spot-photo.jpg',
        note: 'By the north entrance.',
      );

      await _pumpCard(tester, card);

      expect(find.text('WHAT THEY’RE WEARING'), findsNothing);
      expect(find.byType(MeetupOutfitFigureStage), findsNothing);
      expect(find.textContaining('By the north entrance.'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });
  });
}
