// Regression tests for the rapid-toggle race: a delayed realtime echo of an
// earlier toggle must never revert a toggle the user pressed afterwards.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matchme/providers/chat_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _EnabledTranslationNotifier extends TranslationNotifier {
  @override
  TranslationStates build() => const {'match-1': 'en'};
}

ProviderContainer _container() {
  return ProviderContainer(
    overrides: [
      translationProvider.overrideWith(_EnabledTranslationNotifier.new),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://test-project.supabase.co',
      publishableKey: 'test-publishable-key',
      httpClient: MockClient((request) async => http.Response('{}', 200)),
    );
  });

  test(
    'a delayed older realtime event cannot revert a confirmed toggle',
    () async {
      final container = _container();
      addTearDown(container.dispose);
      final notifier = container.read(translationProvider.notifier);

      // The enable echo lands first. It matches the optimistic local state
      // (echo no-op) but must still advance the per-match event watermark.
      await notifier.applyRemoteTranslationUpdate(
        'match-1',
        'en',
        updatedAt: DateTime.utc(2026, 1, 1, 12, 0, 5),
      );
      expect(container.read(translationProvider), const {'match-1': 'en'});

      // The delayed echo of the earlier disable arrives last. Its server
      // timestamp predates the enable echo, so it is dropped instead of
      // flipping the toggle back off (observed as
      // `remote-update ... previous=en next=null` in Chat log4).
      await notifier.applyRemoteTranslationUpdate(
        'match-1',
        null,
        updatedAt: DateTime.utc(2026, 1, 1, 12, 0, 3),
      );
      expect(container.read(translationProvider), const {'match-1': 'en'});
    },
  );

  test(
    'a newer event still applies and later older events are dropped',
    () async {
      final container = _container();
      addTearDown(container.dispose);
      final notifier = container.read(translationProvider.notifier);

      await notifier.applyRemoteTranslationUpdate(
        'match-1',
        'en',
        updatedAt: DateTime.utc(2026, 1, 1, 12, 0, 5),
      );

      // Genuinely newer disable: must apply (this is a real cross-device or
      // post-commit update, not a stale echo).
      await notifier.applyRemoteTranslationUpdate(
        'match-1',
        null,
        updatedAt: DateTime.utc(2026, 1, 1, 12, 0, 6),
      );
      expect(container.read(translationProvider), isEmpty);

      // The enable echo of an earlier press is now stale and must not
      // resurrect the toggle.
      await notifier.applyRemoteTranslationUpdate(
        'match-1',
        'en',
        updatedAt: DateTime.utc(2026, 1, 1, 12, 0, 5, 500),
      );
      expect(container.read(translationProvider), isEmpty);
    },
  );
}
