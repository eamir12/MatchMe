import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/utils/otp_utils.dart';

void main() {
  group('OtpUtils.sanitizeCode', () {
    test('trims surrounding whitespace', () {
      expect(OtpUtils.sanitizeCode('  123456  '), '123456');
    });

    test('removes internal spaces pasted from email clients', () {
      expect(OtpUtils.sanitizeCode('123 456'), '123456');
    });

    test('removes dashes and underscores', () {
      expect(OtpUtils.sanitizeCode('123-456'), '123456');
      expect(OtpUtils.sanitizeCode('123_456'), '123456');
    });

    test('removes newlines/tabs', () {
      expect(OtpUtils.sanitizeCode('12\n34\t56'), '123456');
    });

    test('removes non-breaking spaces and RTL marks', () {
      expect(OtpUtils.sanitizeCode('12 3456'), '123456');
      expect(OtpUtils.sanitizeCode('‏123456'), '123456');
    });

    test('converts arabic-indic and fullwidth digits', () {
      expect(OtpUtils.sanitizeCode('١٢٣٤٥٦'), '123456');
      expect(OtpUtils.sanitizeCode('１２３４５６'), '123456');
    });

    test('empty input stays empty', () {
      expect(OtpUtils.sanitizeCode('   '), '');
    });
  });

  group('OtpUtils.normalizeEmail', () {
    test('trims and lowercases', () {
      expect(
        OtpUtils.normalizeEmail('  User@Example.COM '),
        'user@example.com',
      );
    });
  });
}
