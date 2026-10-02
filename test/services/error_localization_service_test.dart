import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/error_localization_service.dart';

void main() {
  test('map errors preserve localized network explanations', () {
    expect(
      ErrorLocalizationService.getMapErrorTranslationKey(
        Exception('SocketException: failed host lookup'),
      ),
      'networkErrorNoInternet',
    );
    expect(
      ErrorLocalizationService.getMapErrorTranslationKey(
        Exception('The request timed out'),
      ),
      'networkErrorTimeout',
    );
  });

  test('map errors hide unexpected exception details', () {
    expect(
      ErrorLocalizationService.getMapErrorTranslationKey(
        Exception('server exploded with internal details'),
      ),
      'generalError',
    );
  });
}
