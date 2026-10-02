import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';

void main() {
  test('event link failure has a built-in localized fallback', () {
    final l10n = LocalizationState.loading();

    expect(
      l10n.getString('eventLinkOpenFailed'),
      'Could not open the event link. Please try again.',
    );
  });
}
