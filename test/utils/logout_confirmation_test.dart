import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';

void main() {
  test('main navigation logout has a confirmation fallback', () {
    final l10n = LocalizationState.loading();

    expect(l10n.getString('authLogoutConfirmTitle'), 'Log out?');
    expect(
      l10n.getString('authLogoutConfirmBody'),
      'You’ll need to sign in again to access your account.',
    );
  });
}
