import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart' show Locale, TextDirection;
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/utils/passkey_device_capability.dart';
import 'package:matchme/utils/passkey_suggestion.dart';

void main() {
  group('passkey setup text fallback', () {
    test('uses bundled English copy when no database translations are loaded', () {
      final localization = LocalizationState(
        currentLocale: const Locale('en'),
        textDirection: TextDirection.ltr,
        strings: const {},
        supportedLanguages: const [],
      );

      for (final key in [
        'authPasskeySetupIosTitle',
        'authPasskeySetupIosBody',
        'authPasskeySetupIosButton',
        'authPasskeySetupIosInstructionsTitle',
        'authPasskeySetupIosInstructionsBody',
        'authPasskeySetupAndroidTitle',
        'authPasskeySetupWindowsTitle',
      ]) {
        expect(localization.getString(key), isNot(key));
        expect(localization.getString(key), isNotEmpty);
      }
    });
  });

  group('resolvePasskeyDeviceCapability', () {
    test('maps the two reported flags onto a capability', () {
      expect(
        resolvePasskeyDeviceCapability(
          hasPasskeySupport: false,
          hasPlatformAuthenticator: false,
        ),
        PasskeyDeviceCapability.unsupported,
      );
      expect(
        resolvePasskeyDeviceCapability(
          hasPasskeySupport: true,
          hasPlatformAuthenticator: true,
        ),
        PasskeyDeviceCapability.platformAuthenticatorReady,
      );
      expect(
        resolvePasskeyDeviceCapability(
          hasPasskeySupport: true,
          hasPlatformAuthenticator: false,
        ),
        PasskeyDeviceCapability.noPlatformAuthenticator,
      );
    });

    test('a WebAuthn-capable device with no platform authenticator is not '
        'unsupported, because a roaming authenticator can still work', () {
      // The regression this guards: treating "no Windows Hello enrolled" as
      // "unsupported" hid the passkey card from users who do have a USB
      // security key, and hid any explanation of the real reason.
      const availability = PasskeyDeviceAvailability(
        hasPasskeySupport: true,
        hasPlatformAuthenticator: false,
      );
      expect(
        availability.capability,
        PasskeyDeviceCapability.noPlatformAuthenticator,
      );
      expect(
        availability.capability,
        isNot(PasskeyDeviceCapability.unsupported),
      );
    });
  });

  group('resolvePasskeyCardPresentation', () {
    test(
      'offers no passkey action when there is no platform authenticator',
      () {
        // The regression this guards: the card used to say "use the passkey
        // button below" and show that button, on a device that cannot run a
        // passkey ceremony at all.
        final presentation = resolvePasskeyCardPresentation(
          PasskeyDeviceCapability.noPlatformAuthenticator,
          platform: TargetPlatform.windows,
        );
        expect(presentation.showActionButton, isFalse);
        expect(presentation.titleKey, 'authPasskeySetupWindowsTitle');
        expect(presentation.bodyKey, 'authPasskeySetupWindowsBody');
        expect(
          presentation.setupAction,
          PasskeySetupAction.openWindowsSignInOptions,
        );
        expect(
          presentation.setupButtonLabelKey,
          'authPasskeySetupWindowsButton',
        );
      },
    );

    test('uses iPhone-specific setup guidance and an instructions action', () {
      final presentation = resolvePasskeyCardPresentation(
        PasskeyDeviceCapability.noPlatformAuthenticator,
        platform: TargetPlatform.iOS,
      );
      expect(presentation.titleKey, isNot('authPasskeyInlineHintTitle'));
      expect(presentation.bodyKey, isNot('authPasskeyInlineHintBody'));
      expect(presentation.titleKey, 'authPasskeySetupIosTitle');
      expect(presentation.setupAction, PasskeySetupAction.showInstructions);
      expect(presentation.setupButtonLabelKey, 'authPasskeySetupIosButton');
      expect(
        presentation.setupInstructionsBodyKey,
        'authPasskeySetupIosInstructionsBody',
      );
    });

    test('opens Android security settings when setup is needed', () {
      final presentation = resolvePasskeyCardPresentation(
        PasskeyDeviceCapability.noPlatformAuthenticator,
        platform: TargetPlatform.android,
      );
      expect(presentation.titleKey, 'authPasskeySetupAndroidTitle');
      expect(
        presentation.setupAction,
        PasskeySetupAction.openAndroidSecuritySettings,
      );
    });

    test('offers the passkey action when an authenticator is ready', () {
      final presentation = resolvePasskeyCardPresentation(
        PasskeyDeviceCapability.platformAuthenticatorReady,
        platform: TargetPlatform.iOS,
      );
      expect(presentation.showActionButton, isTrue);
      expect(presentation.setupAction, isNull);
      expect(presentation.titleKey, 'authPasskeyInlineHintTitle');
      expect(presentation.bodyKey, 'authPasskeyInlineHintBody');
    });
  });

  group('shouldSuggestPasskey', () {
    const email = 'eran@example.com';

    bool suggest({
      bool isSignUp = false,
      bool hasPasskey = true,
      PasskeyDeviceCapability? capability =
          PasskeyDeviceCapability.platformAuthenticatorReady,
      String normalizedEmail = email,
      String lastChecked = email,
    }) {
      return shouldSuggestPasskey(
        isSignUp: isSignUp,
        hasPasskeyForEmail: hasPasskey,
        capability: capability,
        normalizedEmail: normalizedEmail,
        lastCheckedEmail: lastChecked,
      );
    }

    test('suggests when the account has a passkey and the device is ready', () {
      expect(suggest(), isTrue);
    });

    test(
      'suggests with an explanation when no platform authenticator exists',
      () {
        // Offered, not hidden: a USB security key can still complete the
        // ceremony, and the card explains why a phone-registered passkey may
        // not work here.
        expect(
          suggest(capability: PasskeyDeviceCapability.noPlatformAuthenticator),
          isTrue,
        );
      },
    );

    test('never suggests when the platform has no WebAuthn support', () {
      expect(suggest(capability: PasskeyDeviceCapability.unsupported), isFalse);
    });

    test('never suggests during sign-up', () {
      expect(suggest(isSignUp: true), isFalse);
    });

    test('never suggests when the account has no passkey on file', () {
      expect(suggest(hasPasskey: false), isFalse);
    });

    test('never suggests while the capability probe is pending', () {
      expect(suggest(capability: null), isFalse);
    });

    test('requires the typed email to match the checked email', () {
      expect(suggest(normalizedEmail: ''), isFalse);
      expect(suggest(normalizedEmail: 'other@example.com'), isFalse);
    });
  });
}
