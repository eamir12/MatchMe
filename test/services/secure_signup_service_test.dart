import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/secure_signup_service.dart';

void main() {
  group('SecureSignupService.isDisposableEmail', () {
    test('flags the reported temp-mail domain', () {
      expect(
        SecureSignupService.isDisposableEmail('hoxog11372@jobscai.com'),
        isTrue,
      );
    });

    test('flags known disposable providers', () {
      expect(
        SecureSignupService.isDisposableEmail('user@mailinator.com'),
        isTrue,
      );
      expect(
        SecureSignupService.isDisposableEmail('user@10minutemail.com'),
        isTrue,
      );
      expect(SecureSignupService.isDisposableEmail('user@yopmail.com'), isTrue);
      expect(
        SecureSignupService.isDisposableEmail('user@guerrillamail.com'),
        isTrue,
      );
    });

    test('is case-insensitive and trims whitespace', () {
      expect(
        SecureSignupService.isDisposableEmail('  User@JOBSCAI.COM  '),
        isTrue,
      );
      expect(
        SecureSignupService.isDisposableEmail('User@Mailinator.Com'),
        isTrue,
      );
    });

    test('allows legitimate providers', () {
      expect(SecureSignupService.isDisposableEmail('user@gmail.com'), isFalse);
      expect(
        SecureSignupService.isDisposableEmail('user@outlook.com'),
        isFalse,
      );
      expect(
        SecureSignupService.isDisposableEmail('user@company.com'),
        isFalse,
      );
    });

    test('returns false for malformed input', () {
      expect(SecureSignupService.isDisposableEmail(''), isFalse);
      expect(SecureSignupService.isDisposableEmail('not-an-email'), isFalse);
      expect(SecureSignupService.isDisposableEmail('user@'), isFalse);
    });

    test('blocklist is comprehensively populated', () {
      expect(
        SecureSignupService.disposableEmailDomains.length,
        greaterThan(1000),
      );
    });

    test('flags newly-added community-list samples', () {
      expect(SecureSignupService.isDisposableEmail('user@0-mail.com'), isTrue);
      expect(SecureSignupService.isDisposableEmail('user@0box.eu'), isTrue);
      expect(
        SecureSignupService.isDisposableEmail('user@0clickemail.com'),
        isTrue,
      );
    });
  });

  group('SecureSignupService.normalizeBlocklistDomains', () {
    test('lowercases, trims, and dedupes', () {
      expect(
        SecureSignupService.normalizeBlocklistDomains([
          '  Mailinator.COM ',
          'mailinator.com',
          '  jobscai.com',
        ]),
        {'mailinator.com', 'jobscai.com'},
      );
    });

    test('drops invalid entries', () {
      expect(
        SecureSignupService.normalizeBlocklistDomains([
          '',
          '   ',
          'not-a-domain',
          'user@',
          '@nodomain',
          'a',
          'no-tld',
          'valid-temp-mail123.org',
        ]),
        {'valid-temp-mail123.org'},
      );
    });

    test('handles empty input', () {
      expect(SecureSignupService.normalizeBlocklistDomains([]), isEmpty);
    });
  });

  group('SecureSignupService disposable fast-reject', () {
    test(
      'screenEmail throws disposable_email_blocked without network',
      () async {
        expect(
          () =>
              SecureSignupService.screenEmail(email: 'hoxog11372@jobscai.com'),
          throwsA(
            isA<SecureSignUpException>().having(
              (e) => e.code,
              'code',
              'disposable_email_blocked',
            ),
          ),
        );
      },
    );

    test('signUp throws disposable_email_blocked without network', () async {
      expect(
        () => SecureSignupService.signUp(
          email: 'hoxog11372@jobscai.com',
          password: 'ValidPass1!',
          captchaToken: 'token',
        ),
        throwsA(
          isA<SecureSignUpException>().having(
            (e) => e.code,
            'code',
            'disposable_email_blocked',
          ),
        ),
      );
    });
  });
}
