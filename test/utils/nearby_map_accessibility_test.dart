import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';

void main() {
  test('Nearby map controls have built-in localized labels', () {
    final l10n = LocalizationState.loading();

    expect(l10n.getString('mapZoomIn'), 'Zoom in');
    expect(l10n.getString('mapZoomOut'), 'Zoom out');
    expect(
      l10n.getString('homeNearbyMapRadius', params: {'radius': '25 km'}),
      'Your currently selected radius: 25 km',
    );
  });
}
