import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/session_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _refreshTokenKey = 'flutter.refresh_token';
const _userTokenKey = 'flutter.user_token';
const _userIdKey = 'flutter.user_id';
const _snapshotKey = 'persisted_supabase_session';
const _legacySdkTokenKey = 'sb-abc123-auth-token';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'explicit sign-out wipe clears every recoverable auth credential',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      // Written through the same facade the app uses, so the assertions are
      // independent of the mock store's key-prefix handling.
      await prefs.setString(_refreshTokenKey, 'stale-refresh-token');
      await prefs.setString(_userTokenKey, 'stale-access-token');
      await prefs.setString(_userIdKey, 'user-1');
      await prefs.setString(_snapshotKey, '{"currentSession":{}}');
      await prefs.setString(_legacySdkTokenKey, '{"currentSession":{}}');

      await SessionService.clearPersistedSupabaseSessionSnapshot();

      expect(
        prefs.getString(_refreshTokenKey),
        isNull,
        reason: 'a leftover refresh token re-authenticates on the next launch',
      );
      expect(prefs.getString(_userTokenKey), isNull);
      expect(prefs.getString(_userIdKey), isNull);
      expect(prefs.getString(_snapshotKey), isNull);
      expect(prefs.getString(_legacySdkTokenKey), isNull);
    },
  );
}
