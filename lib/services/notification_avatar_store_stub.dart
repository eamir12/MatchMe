// lib/services/notification_avatar_store_stub.dart
// Non-web side of the avatar mirror.
//
// The browser APIs the web store uses only exist inside a page, and native has
// its own mirror already — Kotlin's directory on Android, a plain folder under
// `%LOCALAPPDATA%` on Windows — written inside `NotificationAvatarService`.
// Nothing here runs: every entry point is reached only under `kIsWeb`.

import 'dart:typed_data';

Future<String?> avatarWebMirrorLookup(String key) async => null;

Future<String?> avatarWebMirrorFindByPrefix(String keyPrefix) async => null;

Future<bool> avatarWebMirrorPut({
  required String key,
  required Uint8List bytes,
  required int maxEdgePx,
  required int maxFileBytes,
  required int maxEntries,
}) async => false;

Future<void> avatarWebMirrorDrop(String keyPrefix) async {}

Future<void> avatarWebMirrorWipe() async {}
