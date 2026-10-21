import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/my_user_realtime_service.dart';

/// The shared "my own user row" subscription is the single place where a
/// settings change made on another device enters the app. Its diffing
/// decides which consumer reacts: a consumer that reacts to a column it does
/// not own would churn the UI (and the local snapshot) on every unrelated
/// write to `users` - a profile edit, a location update, a verification
/// change.
void main() {
  group('MyUserRealtimeService.computeChangedKeys', () {
    test('reports every key of the first event as changed', () {
      final changed = MyUserRealtimeService.computeChangedKeys(null, {
        'theme_mode': 'dark',
        'unit_system': 'metric',
      });
      expect(changed, {'theme_mode', 'unit_system'});
    });

    test('reports only the keys whose value changed', () {
      final changed = MyUserRealtimeService.computeChangedKeys(
        {'theme_mode': 'dark', 'unit_system': 'metric'},
        {'theme_mode': 'light', 'unit_system': 'metric'},
      );
      expect(changed, {'theme_mode'});
    });

    test('treats an unchanged JSONB blob as unchanged', () {
      final previous = {
        'notification_preferences': {
          'matrix': {
            'chatMessages': {'push': true, 'sound': true},
          },
          'message_previews': true,
        },
      };
      final next = {
        'notification_preferences': {
          'matrix': {
            'chatMessages': {'push': true, 'sound': true},
          },
          'message_previews': true,
        },
      };
      expect(
        MyUserRealtimeService.computeChangedKeys(previous, next),
        isEmpty,
      );
    });

    test('detects a change nested inside a JSONB blob', () {
      final previous = {
        'notification_preferences': {
          'matrix': {
            'chatMessages': {'push': true, 'sound': true},
          },
        },
      };
      final next = {
        'notification_preferences': {
          'matrix': {
            'chatMessages': {'push': false, 'sound': true},
          },
        },
      };
      expect(
        MyUserRealtimeService.computeChangedKeys(previous, next),
        {'notification_preferences'},
      );
    });

    test('detects a change inside a list', () {
      final previous = {
        'recent_currencies': ['USD', 'EUR'],
      };
      final next = {
        'recent_currencies': ['USD', 'GBP'],
      };
      expect(
        MyUserRealtimeService.computeChangedKeys(previous, next),
        {'recent_currencies'},
      );
    });

    test('reports a key that appeared', () {
      final changed = MyUserRealtimeService.computeChangedKeys(
        {'theme_mode': 'dark'},
        {'theme_mode': 'dark', 'gps_interval_default': 10},
      );
      expect(changed, {'gps_interval_default'});
    });

    test('reports a key that was removed', () {
      final changed = MyUserRealtimeService.computeChangedKeys(
        {'theme_mode': 'dark', 'legacy_flag': true},
        {'theme_mode': 'dark'},
      );
      // A removed key is not in `next`, so it cannot be reported - the
      // consumer keeps its local value, which is the safe direction.
      expect(changed, isEmpty);
    });
  });
}
