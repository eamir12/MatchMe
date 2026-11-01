import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _userId = 'wizard-draft-user';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalDbService db;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('matchme_wizard_draft');
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
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('draft selections and page index survive a restart', () async {
    await db.saveLocalProfile(_userId, {
      'id': _userId,
      'name': 'Unnamed',
      'isProfileComplete': false,
      'photos': <String>[],
    });

    // ── Session 1: user fills part of the wizard, then the app shuts down.
    {
      final container = ProviderContainer(
        overrides: [localDbProvider.overrideWithValue(db)],
      );
      // Keep the notifier alive, as the wizard screen does.
      final sub = container.listen(
        profileEditProvider(_userId),
        (_, _) {},
        fireImmediately: true,
      );
      final notifier = container.read(profileEditProvider(_userId).notifier);
      await notifier.loadInitialProfile(applyWizardDraft: true);

      notifier.toggleIntent('romantic');
      notifier.toggleSubIntent('romantic', 'long_term');
      notifier.updateName('Dana Levi');
      notifier.updateDob(DateTime(1995, 4, 12));
      notifier.updateGender('female');
      notifier.updateBio('Hello there');
      notifier.setWizardPageIndex(3);
      await notifier.saveWizardDraft();
      sub.close();
      container.dispose();
    }

    // ── Session 2: app restarted, wizard loads its initial profile.
    final container2 = ProviderContainer(
      overrides: [localDbProvider.overrideWithValue(db)],
    );
    final sub2 = container2.listen(
      profileEditProvider(_userId),
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(sub2.close);
    addTearDown(container2.dispose);
    final notifier2 = container2.read(profileEditProvider(_userId).notifier);
    await notifier2.loadInitialProfile(applyWizardDraft: true);

    final restored = container2.read(profileEditProvider(_userId)).value!;
    expect(restored.name, 'Dana Levi');
    expect(restored.gender, 'female');
    expect(restored.bio, 'Hello there');
    expect(restored.activeModes, contains('romantic'));
    expect(restored.subIntents['romantic'], contains('long_term'));
    expect(restored.dateOfBirth, DateTime(1995, 4, 12));
    expect(notifier2.wizardCurrentPageIndex, 3);
  });

  test('clearing an optional answer survives a draft restart', () async {
    const clearedUserId = 'wizard-draft-clear-user';
    await db.saveLocalProfile(clearedUserId, {
      'id': clearedUserId,
      'name': 'Dana Levi',
      'isProfileComplete': true,
      'photos': <String>[],
      'activeModes': <String>['romantic'],
      'religion': <String, dynamic>{
        'religion': 'Christianity',
        'denomination': 'christianity__catholic',
      },
      'lifestyle': <String, dynamic>{
        'smoking': 'never',
        'drinking': 'social',
      },
    });

    // ── Session 1: remove religion (and one lifestyle answer), save draft.
    {
      final container = ProviderContainer(
        overrides: [localDbProvider.overrideWithValue(db)],
      );
      final sub = container.listen(
        profileEditProvider(clearedUserId),
        (_, _) {},
        fireImmediately: true,
      );
      final notifier = container.read(
        profileEditProvider(clearedUserId).notifier,
      );
      await notifier.loadInitialProfile(applyWizardDraft: true);
      expect(container.read(profileEditProvider(clearedUserId)).value?.religion,
          isNotNull);

      notifier.updateReligionDraft(null);
      // The draft drops the drinking answer; a union merge would resurrect it.
      notifier.updateLifestyleDraft(const {'smoking': 'never'});
      await notifier.saveWizardDraft();
      sub.close();
      container.dispose();
    }

    // ── Session 2: the saved profile still has religion, but the draft (the
    // user's newer intent) must win when the wizard resumes.
    final container2 = ProviderContainer(
      overrides: [localDbProvider.overrideWithValue(db)],
    );
    final sub2 = container2.listen(
      profileEditProvider(clearedUserId),
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(sub2.close);
    addTearDown(container2.dispose);
    await container2
        .read(profileEditProvider(clearedUserId).notifier)
        .loadInitialProfile(applyWizardDraft: true);

    final restored = container2.read(profileEditProvider(clearedUserId)).value!;
    expect(restored.religion, isNull);
    expect(restored.lifestyle, const {'smoking': 'never'});
  });
}
