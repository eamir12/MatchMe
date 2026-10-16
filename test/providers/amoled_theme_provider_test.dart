import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults to disabled with no stored preference', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(amoledThemeProvider), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(container.read(amoledThemeProvider), isFalse);
  });

  test('restores a persisted enabled preference', () async {
    SharedPreferences.setMockInitialValues({
      AmoledThemeNotifier.prefsKey: true,
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // First read builds the notifier and schedules the prefs hydration.
    expect(container.read(amoledThemeProvider), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(container.read(amoledThemeProvider), isTrue);
  });

  test('setEnabled updates state immediately and persists it', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(amoledThemeProvider.notifier);
    expect(notifier.state, isFalse);

    await notifier.setEnabled(true);
    expect(container.read(amoledThemeProvider), isTrue);

    // The hydration microtask must not roll the user toggle back.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(container.read(amoledThemeProvider), isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(AmoledThemeNotifier.prefsKey), isTrue);

    await notifier.setEnabled(false);
    expect(container.read(amoledThemeProvider), isFalse);
    expect(prefs.getBool(AmoledThemeNotifier.prefsKey), isFalse);
  });
}
