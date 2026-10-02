// lib/services/oauth_loopback_server.dart
//
// Barrel: desktop OAuth loopback callback listener. Resolves to the dart:io
// implementation on Android, iOS, Windows, macOS and Linux, and to the
// unsupported stub on web.
export 'oauth_loopback_server_stub.dart'
    if (dart.library.io) 'oauth_loopback_server_io.dart';
