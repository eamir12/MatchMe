import 'dart:convert';

import 'package:crypto/crypto.dart';

String hashGoogleSignInNonce(String rawNonce) =>
    sha256.convert(utf8.encode(rawNonce)).toString();
