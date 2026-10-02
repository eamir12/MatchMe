import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';

void main() {
  test('Profile Wizard photo actions have localized fallback labels', () {
    final l10n = LocalizationState.loading();

    expect(l10n.getString('profileWizardAddPhotoTooltip'), 'Add a photo');
    expect(l10n.getString('profileWizardEditPhotoAction'), 'Edit photo');
    expect(l10n.getString('profileWizardRemovePhotoAction'), 'Remove photo');
    expect(
      l10n.getString('profileWizardMovePhotoEarlier'),
      'Move photo earlier',
    );
    expect(l10n.getString('profileWizardMovePhotoLater'), 'Move photo later');
    expect(
      l10n.getString('profilePhotoPreviewLabel', params: {'index': '1'}),
      'Photo 1',
    );
  });
}
