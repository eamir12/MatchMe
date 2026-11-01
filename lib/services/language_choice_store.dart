import 'package:shared_preferences/shared_preferences.dart';

/// Persists language choices that have not been confirmed by the server yet.
///
/// A pick made on the login screen is stored for the next sign-in. A pick made
/// while signed in is scoped to that account so an offline write can be
/// replayed later without leaking into another account's session. Both markers
/// are consumed once the server row confirms the value. This replaces the old
/// `user_language_picked` flag, which was device-wide and never cleared, so one
/// pick on a device made every later account's login look like an explicit
/// choice.
class LanguageChoiceStore {
  static const String pendingLoginKey = 'user_language_pending_login';
  static const String legacyPickedKey = 'user_language_picked';

  static String pendingUserKey(String userId) =>
      'user_language_pending_$userId';

  Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  Future<String?> readLoginPick() async {
    try {
      return _normalise((await _prefs()).getString(pendingLoginKey));
    } catch (_) {
      return null;
    }
  }

  Future<String?> readUserPick(String userId) async {
    try {
      return _normalise((await _prefs()).getString(pendingUserKey(userId)));
    } catch (_) {
      return null;
    }
  }

  Future<void> writeLoginPick(String languageCode) async {
    try {
      await (await _prefs()).setString(pendingLoginKey, languageCode);
    } catch (_) {}
  }

  /// A signed-in pick is newer than any pick left on the login screen, so it
  /// supersedes that marker.
  Future<void> writeUserPick(String userId, String languageCode) async {
    try {
      final prefs = await _prefs();
      await prefs.setString(pendingUserKey(userId), languageCode);
      await prefs.remove(pendingLoginKey);
    } catch (_) {}
  }

  Future<void> clearLoginPick({String? ifMatches}) async {
    try {
      final prefs = await _prefs();
      if (ifMatches == null || prefs.getString(pendingLoginKey) == ifMatches) {
        await prefs.remove(pendingLoginKey);
      }
    } catch (_) {}
  }

  Future<void> clearUserPick(String userId, {String? ifMatches}) async {
    try {
      final prefs = await _prefs();
      final key = pendingUserKey(userId);
      if (ifMatches == null || prefs.getString(key) == ifMatches) {
        await prefs.remove(key);
      }
    } catch (_) {}
  }

  /// Clears whichever marker still holds [languageCode]; a newer pending pick
  /// is left untouched so it cannot be lost by a slower, older push.
  Future<void> clearConfirmed(String userId, String languageCode) async {
    await clearLoginPick(ifMatches: languageCode);
    await clearUserPick(userId, ifMatches: languageCode);
  }

  /// The flag carried no account identity and cannot be attributed safely any
  /// more. Existing online picks are already `preferred_language_explicit` on
  /// the server row.
  Future<void> removeLegacyPickedFlag() async {
    try {
      await (await _prefs()).remove(legacyPickedKey);
    } catch (_) {}
  }

  String? _normalise(String? code) {
    final trimmed = code?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}
