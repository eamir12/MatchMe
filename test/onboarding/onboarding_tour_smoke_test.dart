// Onboarding tour smoke + parity tests.
//
// 1. Full core-tour replay (en) driven through the real player controls: the
//    Step counter, subtitle narration, and chapter frame must all track the
//    tour, and reaching the last beat must switch Next -> Get Started.
// 2. Every tour (the 7-beat core tour plus all section tours) rendered in
//    en / es / he inside the phone frame on a phone surface: any RenderFlex
//    overflow, missing narration translation, or unexpected exception fails
//    the test. Real shipped strings (from the onboarding SQL migrations) are
//    used for subtitles, so these tests check the actual translated content,
//    not the English fallbacks.
//
// Aggression: TTS is not available in widget tests, so the autoplay loop
// resolves quickly and falls back to its reading-pace timer. Playback here is
// user-driven via the Next control; leftover autoplay timers are drained with
// a final elapse before each test ends.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/screens/onboarding/onboarding_content.dart';
import 'package:matchme/screens/onboarding/onboarding_intro_screen.dart';
import 'package:matchme/screens/onboarding/onboarding_scenes.dart';
import 'package:matchme/services/voice_guidance_service.dart';

/// Mirrors scripts/check_onboarding_translations.js: merges every
/// migrations/*onboarding* file, later wins, deletes applied per file.
Map<String, Map<String, String>> loadMergedSql() {
  final root = Directory('supabase/migrations');
  if (!root.existsSync()) {
    throw StateError(
      'supabase/migrations not found from ${Directory.current.path}',
    );
  }
  final files =
      root
          .listSync()
          .whereType<File>()
          .where(
            (f) => RegExp(
              r'onboarding',
              caseSensitive: false,
            ).hasMatch(f.uri.pathSegments.last),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  final sql = {
    'en': <String, String>{},
    'es': <String, String>{},
    'he': <String, String>{},
  };
  final insertRe = RegExp(
    r"\('(\w{2})',\s*'(onboarding[^']*|demo[^']*|settingsAppTour[^']*)',\s*'((?:[^']|'')*)'\)",
  );
  final deleteRe = RegExp(r"\bkey\s+IN\s*\(([^)]*)\)");
  for (final f in files) {
    final text = f.readAsStringSync();
    for (final d in deleteRe.allMatches(text)) {
      for (final k in RegExp("'([^']*)'").allMatches(d.group(1)!)) {
        for (final locale in sql.keys) {
          sql[locale]!.remove(k.group(1));
        }
      }
    }
    for (final m in insertRe.allMatches(text)) {
      sql[m.group(1)]![m.group(2)!] = m.group(3)!.replaceAll("''", "'");
    }
  }
  return sql;
}

String resolveParams(String template, Map<String, String> params) {
  var out = template;
  params.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

void usePhoneSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 860);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

typedef BeatRef = ({int chapter, int beat, String bodyKey});

/// Flattens a tour into global beat indices with their chapter position
/// relative to that tour (the player's chapter-frame keys are tour-local).
List<BeatRef> tourBeats(OnboardingTour tour) {
  final out = <BeatRef>[];
  for (var c = 0; c < tour.chapters.length; c++) {
    for (var b = 0; b < tour.chapters[c].beats.length; b++) {
      out.add((
        chapter: c,
        beat: b,
        bodyKey: tour.chapters[c].beats[b].bodyKey,
      ));
    }
  }
  return out;
}

Future<void> pumpTour(
  WidgetTester tester,
  String locale,
  Map<String, String> overrides, {
  OnboardingTour? tour,
}) async {
  final resolvedTour = tour ?? kOnboardingCoreTour;
  final state = LocalizationState(
    currentLocale: Locale(locale),
    textDirection: locale == 'he' ? TextDirection.rtl : TextDirection.ltr,
    strings: overrides,
    supportedLanguages: const [],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [localizationProvider.overrideWithValue(state)],
      child: MaterialApp(
        locale: Locale(locale),
        supportedLocales: const [Locale('en'), Locale('es'), Locale('he')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: OnboardingIntroScreen(
          key: ValueKey('tour-${resolvedTour.id}'),
          tour: resolvedTour,
        ),
      ),
    ),
  );
  // Let the post-frame autoplay start and its speakAndWait resolve (it fails
  // fast without a TTS engine), so the first reading-pace timer exists.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  final g = loadMergedSql();
  final masterBeats = <({int chapter, int beat, String bodyKey})>[];
  for (var c = 0; c < kOnboardingChapters.length; c++) {
    for (var b = 0; b < kOnboardingChapters[c].beats.length; b++) {
      masterBeats.add((
        chapter: c,
        beat: b,
        bodyKey: kOnboardingChapters[c].beats[b].bodyKey,
      ));
    }
  }

  group('onboarding tour', () {
    test(
      'content model: core tour + section tours fit the master chapters',
      () {
        // The auto-run tour is short: 7 beats across 5 chapters.
        expect(kOnboardingCoreTour.totalBeats, 7);
        expect(kOnboardingCoreTour.chapters.length, 5);
        expect(kOnboardingCoreTour.isCore, isTrue);
        expect(kOnboardingCoreTour.id, kOnboardingCoreTourId);

        // Master list keeps the full narratives for the audit + replays.
        expect(kOnboardingChapters.length, 10);
        expect(masterBeats.length, 33);

        // Every beat in every tour comes from the master list.
        final allTourBeats = [
          ...tourBeats(kOnboardingCoreTour),
          for (final t in kOnboardingSectionTours) ...tourBeats(t),
        ];
        final masterKeys = masterBeats.map((b) => b.bodyKey).toSet();
        for (final b in allTourBeats) {
          expect(
            masterKeys.contains(b.bodyKey),
            isTrue,
            reason: '${b.bodyKey} is not a master chapter beat',
          );
        }

        // Section tours: unique ids, non-empty, replay-only except the five
        // first-visit offers.
        expect(kOnboardingSectionTours.map((t) => t.id).toList(), [
          'home',
          'matches',
          'chats',
          'nearby',
          'worldmap',
          'events',
          'profile',
          'settings',
        ]);
        for (final t in kOnboardingSectionTours) {
          expect(t.totalBeats, greaterThan(0), reason: 'tour ${t.id} empty');
          expect(t.isCore, isFalse);
        }
        expect(
          [
            for (final t in kOnboardingSectionTours)
              if (t.promptOnFirstVisit) t.id,
          ],
          ['nearby', 'worldmap', 'events', 'profile', 'settings'],
        );
        // Section lookups resolve consistently.
        for (final t in kOnboardingSectionTours) {
          expect(onboardingSectionTourById(t.id), same(t));
        }
        expect(onboardingSectionTourById('nope'), isNull);
      },
    );

    testWidgets('migrations contain narration for every beat in all locales', (
      tester,
    ) async {
      for (final locale in ['en', 'es', 'he']) {
        for (final b in masterBeats) {
          expect(
            g[locale]![b.bodyKey],
            isNotNull,
            reason: '$locale missing narration for ${b.bodyKey}',
          );
        }
      }
    });

    testWidgets('full core-tour replay in en lands on the finish step', (
      tester,
    ) async {
      usePhoneSurface(tester);
      final beats = tourBeats(kOnboardingCoreTour);
      await pumpTour(tester, 'en', const {});

      final stepTemplate = g['en']!['onboardingStepOf']!;
      for (var i = 0; i < beats.length; i++) {
        final expectedStep = resolveParams(stepTemplate, {
          'current': '${i + 1}',
          'total': '${kOnboardingCoreTour.totalBeats}',
        });
        expect(
          find.text(expectedStep),
          findsOneWidget,
          reason: 'step label at global beat $i',
        );

        final expectedSubtitle = g['en']![beats[i].bodyKey];
        expect(
          expectedSubtitle,
          isNotNull,
          reason: 'en narration missing for ${beats[i].bodyKey}',
        );
        final subFinder = find.byKey(ValueKey('subtitle-$i'));
        expect(
          subFinder,
          findsOneWidget,
          reason: 'subtitle text present at beat $i',
        );
        expect(
          tester.widget<Text>(subFinder).data,
          expectedSubtitle,
          reason: 'en subtitle equals shipped narration at beat $i',
        );

        expect(
          find.byKey(ValueKey('onboarding-chapter-${beats[i].chapter}')),
          findsOneWidget,
          reason: 'chapter frame for beat $i',
        );

        if (i < beats.length - 1) {
          await tester.tap(find.byKey(const ValueKey('next-button')));
          await tester.pump();
          await tester.pump(const Duration(seconds: 16));
        }
      }

      expect(
        find.widgetWithIcon(FilledButton, Icons.celebration),
        findsOneWidget,
        reason: 'finish button replaces Next on the last beat',
      );
      // Drain any pending autoplay timers before the test tears down.
      await tester.pump(const Duration(seconds: 20));
    });

    for (final locale in ['en', 'es', 'he']) {
      testWidgets(
        'renders every tour in $locale inside the phone frame without overflow',
        (tester) async {
          usePhoneSurface(tester);
          final overrides = locale == 'en'
              ? const <String, String>{}
              : g[locale]!;

          for (final tour in [
            kOnboardingCoreTour,
            ...kOnboardingSectionTours,
          ]) {
            await pumpTour(tester, locale, overrides, tour: tour);
            final beats = tourBeats(tour);

            for (var i = 0; i < beats.length; i++) {
              final expected = g[locale]![beats[i].bodyKey];
              expect(
                expected,
                isNotNull,
                reason: '$locale narration missing for ${beats[i].bodyKey}',
              );
              final subFinder = find.byKey(ValueKey('subtitle-$i'));
              expect(
                subFinder,
                findsOneWidget,
                reason: '$locale subtitle present at beat $i of ${tour.id}',
              );
              expect(
                tester.widget<Text>(subFinder).data,
                expected,
                reason:
                    '$locale subtitle equals shipped narration at beat $i '
                    'of ${tour.id}',
              );

              expect(
                find.byKey(ValueKey('onboarding-chapter-${beats[i].chapter}')),
                findsOneWidget,
                reason: '$locale chapter frame at beat $i of ${tour.id}',
              );

              if (i < beats.length - 1) {
                await tester.tap(find.byKey(const ValueKey('next-button')));
                await tester.pump();
                await tester.pump(const Duration(milliseconds: 500));
              }
            }
            // Drain this tour's autoplay timers before pumping the next one.
            await tester.pump(const Duration(seconds: 20));
          }
        },
      );
    }

    testWidgets(
      'landscape shows phone, wording and controls side by side without overflow',
      (tester) async {
        // Tablet-landscape surface: widget tests render with the Ahem font,
        // whose glyphs are ~2x wider than production fonts, so a phone-sized
        // landscape frame (151px wide) starves its own mock app bar far beyond
        // what real devices experience. The tablet frame keeps replica content
        // at portrait-like widths while still exercising the landscape Row
        // (phone + wording side by side, controls pinned in the bottom bar).
        tester.view.physicalSize = const Size(1180, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final beats = tourBeats(kOnboardingCoreTour);
        await pumpTour(tester, 'en', const {});

        for (var i = 0; i < beats.length; i++) {
          // Phone mock keeps a visible size next to the wording.
          final phone = find.byType(PhoneFrame);
          expect(
            phone,
            findsOneWidget,
            reason: 'phone frame present at beat $i',
          );
          expect(
            tester.getSize(phone).height,
            greaterThan(100),
            reason: 'phone frame visible at beat $i',
          );
          // Narration wording is present and laid out.
          final subFinder = find.byKey(ValueKey('subtitle-$i'));
          expect(
            subFinder,
            findsOneWidget,
            reason: 'subtitle present at beat $i',
          );
          expect(
            tester.getSize(subFinder).height,
            greaterThan(0),
            reason: 'subtitle visible at beat $i',
          );

          if (i < beats.length - 1) {
            await tester.tap(find.byKey(const ValueKey('next-button')));
            await tester.pump();
            // Settle the 420ms chapter cross-fade before asserting the next
            // beat: mid-transition frames stack two replicas and can report
            // transient overflow on already-disposed subtrees.
            await tester.pump(const Duration(milliseconds: 800));
          }
        }

        // Controls stay pinned and usable: Next became Get Started at the end.
        expect(
          find.widgetWithIcon(FilledButton, Icons.celebration),
          findsOneWidget,
          reason: 'finish button replaces Next on the last beat in landscape',
        );
        await tester.pump(const Duration(seconds: 20));
      },
    );

    group('toggle demo follows the narration', () {
      const shortNarration =
          'Watch the demo switch here now go invisible soon then back online again end';
      late Duration estimate;
      late Duration offlineAt;
      late Duration onlineAt;

      String resolve(String key, {Map<String, String>? params}) =>
          key == 'onboardingBeatHome1' ? shortNarration : key;

      Future<void> pumpStrip(WidgetTester tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 240,
                  height: 445,
                  child: PhoneFrame(
                    child: buildOnboardingReplica(
                      OnboardingScene.home,
                      OnboardingSceneData(text: resolve, highlight: 'status'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
      }

      setUp(() {
        estimate = estimateSpokenDuration(shortNarration);
        offlineAt = Duration(
          milliseconds: (estimate.inMilliseconds * 0.60).round(),
        );
        onlineAt = Duration(
          milliseconds: (estimate.inMilliseconds * 0.90).round(),
        );
        VoiceGuidanceService.instance.spokenText.value = null;
      });

      tearDown(() {
        VoiceGuidanceService.instance.spokenText.value = null;
      });

      testWidgets('flips land on the narration clock when audible', (
        tester,
      ) async {
        usePhoneSurface(tester);
        await pumpStrip(tester);

        // Speech starts now: flips must track fractions of the utterance,
        // not the old fixed wall-clock delays.
        VoiceGuidanceService.instance.spokenText.value = shortNarration;
        await tester.pump(offlineAt - const Duration(milliseconds: 500));
        expect(
          find.textContaining('AndVisible'),
          findsOneWidget,
          reason: 'still online before the offline clause',
        );
        await tester.pump(const Duration(milliseconds: 700));
        expect(
          find.textContaining('andInvisible'),
          findsOneWidget,
          reason: 'invisible once the offline clause is spoken',
        );
        await tester.pump(onlineAt - offlineAt);
        expect(
          find.textContaining('AndVisible'),
          findsOneWidget,
          reason: 'back online for the closing clause',
        );
        await tester.pump(const Duration(seconds: 5));
      });

      testWidgets('falls back to subtitle pace when muted', (tester) async {
        usePhoneSurface(tester);
        await pumpStrip(tester);

        // No utterance ever starts: same fractions, paced from activation.
        await tester.pump(offlineAt - const Duration(milliseconds: 500));
        expect(
          find.textContaining('AndVisible'),
          findsOneWidget,
          reason: 'still online before the offline clause',
        );
        await tester.pump(const Duration(milliseconds: 700));
        expect(
          find.textContaining('andInvisible'),
          findsOneWidget,
          reason: 'invisible on subtitle pace',
        );
        await tester.pump(onlineAt - offlineAt);
        expect(
          find.textContaining('AndVisible'),
          findsOneWidget,
          reason: 'back online on subtitle pace',
        );
        await tester.pump(const Duration(seconds: 5));
      });
    });
  });
}
