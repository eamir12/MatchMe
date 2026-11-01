import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/language_choice_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LanguageChoiceStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = LanguageChoiceStore();
  });

  test('a signed-in pick supersedes a leftover login-screen pick', () async {
    await store.writeLoginPick('es');
    expect(await store.readLoginPick(), 'es');

    await store.writeUserPick('user-a', 'fr');

    expect(await store.readLoginPick(), isNull);
    expect(await store.readUserPick('user-a'), 'fr');
    // Choices are account-scoped; a different account never inherits it.
    expect(await store.readUserPick('user-b'), isNull);
  });

  test('confirmation only clears the marker holding that language', () async {
    await store.writeUserPick('user-a', 'fr');

    await store.clearConfirmed('user-a', 'es');
    expect(await store.readUserPick('user-a'), 'fr');

    await store.clearConfirmed('user-a', 'fr');
    expect(await store.readUserPick('user-a'), isNull);
  });

  test('a login-screen pick outranks an older unsynced account pick', () async {
    await store.writeUserPick('user-a', 'de');
    await store.writeLoginPick('es');

    expect(await store.readLoginPick(), 'es');
    expect(await store.readUserPick('user-a'), 'de');

    // The provider clears the superseded account marker once it picks the
    // login-screen value.
    await store.clearUserPick('user-a');
    expect(await store.readUserPick('user-a'), isNull);
    expect(await store.readLoginPick(), 'es');
  });

  test('empty or whitespace values are ignored', () async {
    await store.writeLoginPick('   ');
    expect(await store.readLoginPick(), isNull);
  });

  test('the legacy device-wide picked flag is removed', () async {
    SharedPreferences.setMockInitialValues({'user_language_picked': true});

    await store.removeLegacyPickedFlag();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(LanguageChoiceStore.legacyPickedKey), isFalse);
  });
}
