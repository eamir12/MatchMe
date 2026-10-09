import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/utils/google_sign_in_nonce.dart';

void main() {
  test('hashes the raw nonce as lowercase hexadecimal SHA-256', () {
    expect(
      hashGoogleSignInNonce('abc'),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });
}
