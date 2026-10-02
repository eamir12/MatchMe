import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';

void main() {
  test('Profile social-link failure has a built-in localized fallback', () {
    final l10n = LocalizationState.loading();

    expect(
      l10n.getString('profileSocialLinkOpenFailed'),
      'Could not open this link. Check your connection and try again.',
    );
  });
}
