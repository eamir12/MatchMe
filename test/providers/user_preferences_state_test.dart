import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/user_preferences_provider.dart';

/// The `users` row is updated for many reasons - a profile edit, a location
/// update, a verification change - and every one of those fires a realtime
/// event on the shared "my own user row" channel.
///
/// Without value equality the merge would produce a "new" state each time,
/// which rebuilds the settings UI and rewrites the local snapshot for
/// changes that had nothing to do with the preferences.
void main() {
  group('UserPreferencesState equality', () {
    test('two states with the same values are equal', () {
      final a = UserPreferencesState.defaults().copyWith(
        unitSystem: UnitSystemPreference.metric,
        timeFormat: TimeFormatPreference.h24,
        preferredCurrency: 'USD',
        recentCurrencies: const ['USD', 'EUR'],
      );
      final b = UserPreferencesState.defaults().copyWith(
        unitSystem: UnitSystemPreference.metric,
        timeFormat: TimeFormatPreference.h24,
        preferredCurrency: 'USD',
        recentCurrencies: const ['USD', 'EUR'],
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('a different unit system is not equal', () {
      final a = UserPreferencesState.defaults().copyWith(
        unitSystem: UnitSystemPreference.metric,
      );
      final b = UserPreferencesState.defaults().copyWith(
        unitSystem: UnitSystemPreference.imperial,
      );
      expect(a, isNot(b));
    });

    test('a different currency list is not equal', () {
      final a = UserPreferencesState.defaults().copyWith(
        recentCurrencies: const ['USD'],
      );
      final b = UserPreferencesState.defaults().copyWith(
        recentCurrencies: const ['EUR'],
      );
      expect(a, isNot(b));
    });
  });

  group('NotificationPreferencesState equality', () {
    test('two states with the same matrix are equal', () {
      final matrix = <NotificationType, Map<NotificationMethod, bool>>{
        NotificationType.chatMessages: {
          NotificationMethod.push: true,
          NotificationMethod.sound: false,
        },
      };
      final a = NotificationPreferencesState.defaults().copyWith(matrix: matrix);
      final b = NotificationPreferencesState.defaults().copyWith(matrix: matrix);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('a changed matrix entry is not equal', () {
      final a = NotificationPreferencesState.defaults().copyWith(
        matrix: {
          NotificationType.chatMessages: {NotificationMethod.push: true},
        },
      );
      final b = NotificationPreferencesState.defaults().copyWith(
        matrix: {
          NotificationType.chatMessages: {NotificationMethod.push: false},
        },
      );
      expect(a, isNot(b));
    });

    test('a changed global method is not equal', () {
      final a = NotificationPreferencesState.defaults().copyWith(
        globalMethods: {
          NotificationMethod.push: true,
          NotificationMethod.sound: true,
          NotificationMethod.inApp: true,
          NotificationMethod.vibrate: true,
        },
      );
      final b = NotificationPreferencesState.defaults().copyWith(
        globalMethods: {
          NotificationMethod.push: true,
          NotificationMethod.sound: false,
          NotificationMethod.inApp: true,
          NotificationMethod.vibrate: true,
        },
      );
      expect(a, isNot(b));
    });
  });
}
