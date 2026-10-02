import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/utils/matching_background_status.dart';

void main() {
  test('web always reports background matching as unavailable', () {
    expect(
      resolveMatchingBackgroundStatus(
        isWeb: true,
        isAndroid: false,
        preferenceEnabled: true,
        permissionCheckComplete: true,
        permissionGranted: true,
      ),
      MatchingBackgroundStatus.webUnavailable,
    );
  });

  test('disabled preference reports off', () {
    expect(
      resolveMatchingBackgroundStatus(
        isWeb: false,
        isAndroid: true,
        preferenceEnabled: false,
        permissionCheckComplete: true,
        permissionGranted: true,
      ),
      MatchingBackgroundStatus.off,
    );
  });

  test('Android permission states are distinguished from on', () {
    expect(
      resolveMatchingBackgroundStatus(
        isWeb: false,
        isAndroid: true,
        preferenceEnabled: true,
        permissionCheckComplete: false,
        permissionGranted: null,
      ),
      MatchingBackgroundStatus.checking,
    );
    expect(
      resolveMatchingBackgroundStatus(
        isWeb: false,
        isAndroid: true,
        preferenceEnabled: true,
        permissionCheckComplete: true,
        permissionGranted: false,
      ),
      MatchingBackgroundStatus.permissionNeeded,
    );
    expect(
      resolveMatchingBackgroundStatus(
        isWeb: false,
        isAndroid: true,
        preferenceEnabled: true,
        permissionCheckComplete: true,
        permissionGranted: true,
      ),
      MatchingBackgroundStatus.on,
    );
  });
}
