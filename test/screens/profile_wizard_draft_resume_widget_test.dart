import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/screens/profile/profile_wizard_screen.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/offline_cache_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _setupUserId = 'wizard-setup-user';
const _editUserId = 'wizard-edit-user';

User _fakeUser(String id) => User(
  id: id,
  appMetadata: const {},
  userMetadata: const {},
  aud: 'authenticated',
  createdAt: DateTime(2026, 1, 1).toIso8601String(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalDbService db;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('matchme_wizard_widget');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://test-project.supabase.co',
      publishableKey: 'test-publishable-key',
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({}),
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
      debug: false,
    );
    db = LocalDbService();
    await db.init();
    // Keep all Supabase-touching services inert in these tests: no config
    // fetch (which would create a 10 s timeout timer), no profile syncs.
    OfflineCacheManager.instance.setSupabaseAvailability(false, force: true);
  });

  tearDownAll(() async {
    // Hive.close() can stall when a debounced draft write is still awaiting a
    // timer that the fake-async test clock will never fire; bound both steps
    // so the suite can exit instead of hitting the runner timeout.
    try {
      await Hive.close().timeout(const Duration(seconds: 10));
    } catch (_) {}
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  ProviderContainer makeContainer() => ProviderContainer(
    overrides: [
      localDbProvider.overrideWithValue(db),
      localizationProvider.overrideWithValue(LocalizationState.loading()),
      connectivityHealthProvider.overrideWith(
        (ref) => Stream.value(
          const ConnectivityHealth(
            status: ConnectivityHealthStatus.online,
            backendReachable: true,
          ),
        ),
      ),
      // The wizard watches this realtime stream; stubbing it keeps a
      // Supabase Realtime channel (and its 50 s pending-disconnect timer)
      // out of the test.
      basicFieldAdminReviewsProvider.overrideWith(
        (ref, userId) =>
            Stream.value(const <String, BasicFieldAdminReview>{}),
      ),
    ],
  );

  Future<void> mountWizard(
    WidgetTester tester,
    ProviderContainer container,
    String userId, {
    bool isEditing = false,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: ProfileWizardScreen(
            user: _fakeUser(userId),
            isEditing: isEditing,
          ),
        ),
      ),
    );
  }

  /// Pumps a fresh app shell whose home pushes the wizard as a route, then
  /// taps the button so the wizard is on the navigation stack (needed to
  /// simulate "user goes back" through a real route pop → PopScope).
  Future<void> pushWizard(
    WidgetTester tester,
    ProviderContainer container,
    String userId, {
    bool isEditing = false,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ProfileWizardScreen(
                        user: _fakeUser(userId),
                        isEditing: isEditing,
                      ),
                    ),
                  ),
                  child: const Text('open-wizard'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-wizard'));
    await tester.pump();
  }

  /// Lets fire-and-forget persistence work (Hive put/flush) complete inside
  /// the fake-async test zone: real I/O finishes during runAsync, and the
  /// continuations that were scheduled in the fake zone run on the pumps.
  Future<void> drainIo(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
  }

  /// Pumps enough frames for the wizard to load its profile and build, and
  /// advances past the 1 s user-exists check so no timer is left pending.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    await tester.pump(const Duration(seconds: 2));
    await drainIo(tester);
  }

  testWidgets(
    'setup wizard resumes on the last screen after a mid-wizard kill',
    (tester) async {
      await tester.runAsync(
        () => db.saveCachedAppIntents([
          {
            'id': 1,
            'key': 'romantic',
            'translation_key': 'intentRomantic',
            'parent_id': null,
            'sort_order': 1,
            'is_social': true,
            'is_business': false,
          },
        ]),
      );
      await tester.runAsync(
        () => db.saveLocalProfile(_setupUserId, {
          'id': _setupUserId,
          'name': 'Unnamed',
          'isProfileComplete': false,
          'photos': <String>[],
          'subscription_expires_at': '2027-01-01T00:00:00.000Z',
        }),
      );

      // ── Session 1: user fills the first screens, then the OS kills the
      // app before the debounced draft save (350 ms) has fired.
      final container1 = makeContainer();
      await mountWizard(tester, container1, _setupUserId);
      await settle(tester);

      final notifier1 =
          container1.read(profileEditProvider(_setupUserId).notifier);
      notifier1.toggleIntent('romantic');
      notifier1.toggleSubIntent('romantic', 'long_term');
      notifier1.updateName('Dana Levi');
      notifier1.updateDob(DateTime(1995, 4, 12));
      notifier1.updateGender('female');
      notifier1.updateBio('Hello there');
      notifier1.setWizardPageIndex(3);
      await tester.pump();

      // Process death from the background: no dispose() runs, only the
      // lifecycle flush can persist the draft.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await drainIo(tester);

      final draftOnDisk = await tester.runAsync(
        () => db.loadProfileWizardDraft(_setupUserId),
      );
      expect(draftOnDisk, isNotNull, reason: 'lifecycle flush must persist');
      expect(draftOnDisk!['_wizard_current_page_index'], 3);
      expect(draftOnDisk['name'], 'Dana Levi');
      expect(draftOnDisk['bio'], 'Hello there');

      // Tear the killed process down and restore the lifecycle. Restoring
      // first is required: while the lifecycle is paused, pumps do not
      // process frames, so the unmount below would be skipped and session 2
      // would silently reuse the stale wizard element (no initState).
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
      await drainIo(tester);
      container1.dispose();

      // ── Session 2: fresh app process, wizard re-opened for the
      // still-incomplete profile. It must resume with the saved data on the
      // exact screen the user left (page 3).
      final container2 = makeContainer();
      await mountWizard(tester, container2, _setupUserId);
      await settle(tester);

      final restored = container2
          .read(profileEditProvider(_setupUserId))
          .value!;
      expect(restored.name, 'Dana Levi');
      expect(restored.gender, 'female');
      expect(restored.bio, 'Hello there');
      expect(restored.activeModes, contains('romantic'));
      expect(restored.subIntents['romantic'], contains('long_term'));
      expect(restored.dateOfBirth, DateTime(1995, 4, 12));
      expect(
        container2
            .read(profileEditProvider(_setupUserId).notifier)
            .wizardCurrentPageIndex,
        3,
      );
      final pageView = tester.widget<PageView>(find.byType(PageView).first);
      expect(pageView.controller!.page, closeTo(3, 0.01));

      // Leaving `resumed` stops Supabase auth's periodic auto-refresh timer
      // that the resumed transition started.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'edit-after-complete wizard resumes on the last visited screen',
    (tester) async {
      await tester.runAsync(
        () => db.saveLocalProfile(_editUserId, {
          'id': _editUserId,
          'name': 'Dana Levi',
          'dateOfBirth': '1995-04-12T00:00:00.000',
          'gender': 'female',
          'bio': 'Hello there',
          'activeModes': ['romantic'],
          'subIntents': {
            'romantic': ['long_term'],
          },
          'photos': <String>[],
          'isProfileComplete': true,
          'subscription_expires_at': '2027-01-01T00:00:00.000Z',
        }),
      );

      // ── Session 1: user opens Edit, browses to screen 5, then goes back
      // out of the wizard through the app bar (route pop → PopScope saves
      // the draft).
      final container1 = makeContainer();
      await pushWizard(tester, container1, _editUserId, isEditing: true);
      await settle(tester);

      final notifier1 =
          container1.read(profileEditProvider(_editUserId).notifier);
      notifier1.updateBio('Edited bio v2');
      notifier1.setWizardPageIndex(5);
      await tester.pump();

      final backButton = find.descendant(
        of: find.byType(AppBar),
        matching: find.byIcon(Icons.arrow_back),
      );
      await tester.tap(backButton.first);
      await tester.pump(const Duration(milliseconds: 500));
      await drainIo(tester);

      final draftOnDisk = await tester.runAsync(
        () => db.loadProfileWizardDraft(_editUserId),
      );
      expect(draftOnDisk, isNotNull, reason: 'pop must save the draft');
      expect(draftOnDisk!['_wizard_current_page_index'], 5);
      expect(draftOnDisk['bio'], 'Edited bio v2');

      await tester.pumpWidget(const SizedBox.shrink());
      await drainIo(tester);
      container1.dispose();

      // ── Session 2: fresh app process, user re-opens Edit and must land
      // back on screen 5 with the edit preserved.
      final container2 = makeContainer();
      await pushWizard(tester, container2, _editUserId, isEditing: true);
      await settle(tester);

      final restored = container2.read(profileEditProvider(_editUserId)).value!;
      expect(restored.bio, 'Edited bio v2');
      expect(restored.isProfileComplete, isTrue);
      expect(
        container2
            .read(profileEditProvider(_editUserId).notifier)
            .wizardCurrentPageIndex,
        5,
      );
      final pageView = tester.widget<PageView>(find.byType(PageView).first);
      expect(pageView.controller!.page, closeTo(5, 0.01));

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'edit wizard on an unchanged complete profile shows no review page',
    (tester) async {
      const unchangedUserId = 'wizard-unchanged-user';
      await tester.runAsync(
        () => db.saveCachedAppIntents([
          {
            'id': 1,
            'key': 'romantic',
            'translation_key': 'intentRomantic',
            'parent_id': null,
            'sort_order': 1,
            'is_social': true,
            'is_business': false,
          },
        ]),
      );
      await tester.runAsync(
        () => db.saveLocalProfile(unchangedUserId, {
          'id': unchangedUserId,
          'name': 'Dana Levi',
          'dateOfBirth': '1995-04-12T00:00:00.000',
          'gender': 'female',
          'bio': 'Hello there',
          'activeModes': ['romantic'],
          'subIntents': {
            'romantic': ['long_term'],
          },
          'personalInterests': {
            'romantic': ['hiking'],
          },
          'photos': <String>['photo-1', 'photo-2'],
          'isProfileComplete': true,
          'subscription_expires_at': '2027-01-01T00:00:00.000Z',
        }),
      );

      final container = makeContainer();
      await mountWizard(tester, container, unchangedUserId, isEditing: true);
      await settle(tester);

      // 1 intent → main intents, sub-intents, basics, details, photos,
      // interests, lifestyle, family, religion, match prefs, social links.
      // A 12th page would be the review page, which must only exist once the
      // draft actually differs from the saved profile.
      final pageView = tester.widget<PageView>(find.byType(PageView).first);
      expect(pageView.childrenDelegate.estimatedChildCount, 11);

      await tester.pump(const Duration(seconds: 9));
      await tester.pumpWidget(const SizedBox.shrink());
      await drainIo(tester);
      container.dispose();
    },
  );
}
