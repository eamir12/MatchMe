import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';

void main() {
  test('retroactive trail deletion has a destructive confirmation fallback', () {
    final l10n = LocalizationState.loading();

    expect(
      l10n.getString('settingsRetroDeleteNowConfirm'),
      'This permanently deletes your saved places from this device and the server. You will not be able to recover them.',
    );
  });
}
