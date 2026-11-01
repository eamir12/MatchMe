import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:matchme/services/offline_image_cache.dart';
import 'package:matchme/services/storage_helper.dart';

/// The avatar slot a card gives the sender's face, and the budget one mirrored
/// file may take. Top-level because the isolate that resizes needs them too.
const int _maxEdgePx = 128;
const int _maxFileBytes = 32 * 1024;
const int _maxEntries = 64;

/// Keeps the avatar a notification card draws - the sender's face beside their
/// name - in a small plaintext mirror the OS can open.
///
/// The app's only other copy of these bytes is OfflineImageCache, an encrypted
/// Hive box keyed by a device code. Neither Android's Kotlin service nor a
/// Windows toast XML can read it: Kotlin would have to reimplement the Hive
/// file format and hold the key natively, and the toast renderer only takes a
/// URI it can resolve by itself. So the card gets its own copy: one square JPEG
/// per conversation, at most 128px and 32KB, 64 conversations.
///
/// The two stores differ only in who writes them. Android hands bytes over the
/// background-service channel and Kotlin owns the files, under
/// `noBackupFilesDir` and excluded again in both Android rules files. Windows
/// has no such channel, so Dart writes to `%LOCALAPPDATA%\MatchMe` - a path
/// that is not one of the folders sync or backup tools are pointed at.
///
/// This runs **regardless of the "show message previews" setting**. That
/// setting hides message text, not the sender's face or name - a card with
/// previews off still says who is writing.
class NotificationAvatarService {
  NotificationAvatarService._();

  static final NotificationAvatarService instance =
      NotificationAvatarService._();

  static const MethodChannel _channel =
      MethodChannel('matchme/background_service');

  /// The avatar source this process has already dealt with for a conversation.
  /// A different source for the same conversation is a new member picture and
  /// has to be re-mirrored, so the value is the source key, not a bool.
  final Map<String, String> _handed = {};

  /// Windows mirrors written or found by this process, so a toast never walks
  /// the directory to look one up.
  final Map<String, String> _diskPaths = {};

  /// Android draws its card in Kotlin, which cannot read the encrypted cache,
  /// so the bytes go over the channel and Kotlin owns the file.
  static bool get _usesNativeStore => !kIsWeb && Platform.isAndroid;

  /// A Windows toast takes an image URI and nothing else, so Dart writes the
  /// file itself.
  static bool get _usesDiskStore => !kIsWeb && Platform.isWindows;

  static bool get _supported => _usesNativeStore || _usesDiskStore;

  /// Mirrors the first photo of every chat row, from bytes the app already has.
  ///
  /// Never downloads: the avatars worth mirroring are the ones Home or the chat
  /// list has already painted, and the startup warm prefetches them. A chat
  /// whose picture was never loaded simply posts its card without one.
  Future<void> syncFromChats(List<Map<String, dynamic>> chats) async {
    if (!_supported) return;
    for (final chat in chats) {
      final matchId = (chat['match_id'] ?? '').toString().trim();
      final source = _firstPhoto(chat['other_user_photos']);
      if (matchId.isEmpty || source.isEmpty) continue;
      try {
        await mirrorFor(matchId: matchId, photoSource: source);
      } catch (_) {}
    }
  }

  Future<void> mirrorFor({
    required String matchId,
    required String photoSource,
    String? bucket,
  }) async {
    if (!_supported) return;
    final id = matchId.trim();
    final source = photoSource.trim();
    if (id.isEmpty || source.isEmpty) return;
    final cacheKey = StorageHelper.cacheKeyForSource(source, bucket: bucket);
    if (cacheKey.isEmpty) return;
    if (_handed[id] == cacheKey) return;

    // Asking the store before loading the bytes is what keeps a warm relaunch
    // cheap: the avatars it already has never leave Dart again.
    if (_usesNativeStore) {
      final present = await _channel.invokeMethod<bool>(
        'isNotificationAvatarMirrored',
        {'matchId': id, 'cacheKey': cacheKey},
      );
      if (present == true) {
        _handed[id] = cacheKey;
        return;
      }
    } else {
      final existing = _existingDiskMirror(id);
      if (existing != null) {
        _handed[id] = cacheKey;
        return;
      }
    }

    final bytes = await OfflineImageCache.instance.read(cacheKey);
    if (bytes == null || bytes.isEmpty) return;

    if (_usesNativeStore) {
      await _channel.invokeMethod<bool>('mirrorNotificationAvatar', {
        'matchId': id,
        'cacheKey': cacheKey,
        'bytes': bytes,
      });
    } else {
      await _writeDiskMirror(id, cacheKey, bytes);
    }
    _handed[id] = cacheKey;
  }

  /// The Windows mirror for [matchId], or null when this conversation has none.
  ///
  /// Synchronous on purpose: it is called while building a toast, and a card
  /// waits for nothing - a missing avatar is a card without a face.
  String? filePathFor(String matchId) {
    if (!_usesDiskStore) return null;
    final id = matchId.trim();
    if (id.isEmpty) return null;
    final known = _diskPaths[id];
    if (known != null && File(known).existsSync()) return known;
    return _existingDiskMirror(id);
  }

  /// A chat that is gone takes its face with it.
  Future<void> evict(String matchId) async {
    final id = matchId.trim();
    if (id.isEmpty) return;
    _handed.remove(id);
    _diskPaths.remove(id);
    if (_usesDiskStore) {
      _deleteDiskMirrors(id);
      return;
    }
    if (!_supported) return;
    try {
      await _channel.invokeMethod<bool>(
        'evictNotificationAvatar',
        {'matchId': id},
      );
    } catch (_) {}
  }

  /// Logout / account deletion: no mirrored avatar may outlive the session.
  Future<void> clearAll() async {
    _handed.clear();
    _diskPaths.clear();
    if (_usesDiskStore) {
      _deleteAllDiskMirrors();
      return;
    }
    if (!_supported) return;
    try {
      await _channel.invokeMethod<bool>('clearNotificationAvatars');
    } catch (_) {}
  }

  // --- Windows mirror -----------------------------------------------------

  static String _diskDirPath() {
    final localAppData = (Platform.environment['LOCALAPPDATA'] ?? '').trim();
    if (localAppData.isEmpty) return '';
    return '$localAppData${Platform.pathSeparator}MatchMe'
        '${Platform.pathSeparator}notification_avatars';
  }

  static Directory? _diskDir() {
    final path = _diskDirPath();
    if (path.isEmpty) return null;
    return Directory(path);
  }

  /// `<sha(matchId)>-<sha(cacheKey) prefix>.jpg`, so a member who changes their
  /// picture gets a new file and the old one is dropped, and a face is never
  /// stored under a readable conversation id.
  static String _diskFileName(String matchId, String cacheKey) {
    final idHash = sha256.convert(utf8.encode(matchId)).toString();
    final keyHash = sha256.convert(utf8.encode(cacheKey)).toString();
    return '$idHash-${keyHash.substring(0, 16)}.jpg';
  }

  static String _diskIdPrefix(String matchId) =>
      sha256.convert(utf8.encode(matchId)).toString();

  /// The mirrored face this process can show for [matchId], already resized and
  /// capped, or null when the source is not a picture this build can decode.
  ///
  /// Runs in a background isolate: the stored bytes are the member's real
  /// photo, and decoding several megabytes in pure Dart is far too much work to
  /// take from the thread painting the tray card.
  static Future<Uint8List?> _encodeAvatar(Uint8List bytes) =>
      compute(_encodeAvatarInIsolate, bytes);

  String? _existingDiskMirror(String matchId) {
    final dir = _diskDir();
    if (dir == null || !dir.existsSync()) return null;
    final prefix = _diskIdPrefix(matchId);
    try {
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final name = _basename(entity.path);
        if (!name.startsWith('$prefix-') || !name.endsWith('.jpg')) continue;
        if (!entity.existsSync()) continue;
        _diskPaths[matchId] = entity.path;
        return entity.path;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _writeDiskMirror(
    String matchId,
    String cacheKey,
    Uint8List bytes,
  ) async {
    final dir = _diskDir();
    if (dir == null) return;
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final avatar = await _encodeAvatar(bytes);
      if (avatar == null) return;
      final target = File(
        '${dir.path}${Platform.pathSeparator}'
        '${_diskFileName(matchId, cacheKey)}',
      );
      // A different file for the same conversation is the member's new
      // picture: the old face goes, so a deleted photo cannot outlive it.
      _deleteDiskMirrors(matchId);
      final staged = File('${target.path}.tmp');
      await staged.writeAsBytes(avatar, flush: true);
      await staged.rename(target.path);
      _diskPaths[matchId] = target.path;
      _pruneDiskDir(dir);
    } catch (_) {}
  }

  void _deleteDiskMirrors(String matchId) {
    final dir = _diskDir();
    if (dir == null || !dir.existsSync()) return;
    final prefix = _diskIdPrefix(matchId);
    try {
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final name = _basename(entity.path);
        if (!name.startsWith('$prefix-')) continue;
        try {
          entity.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }

  void _deleteAllDiskMirrors() {
    final dir = _diskDir();
    if (dir == null || !dir.existsSync()) return;
    try {
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        try {
          entity.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Keeps the mirror inside its budget by dropping the oldest faces.
  void _pruneDiskDir(Directory dir) {
    try {
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.jpg'))
          .toList();
      if (files.length <= _maxEntries) return;
      files.sort((a, b) {
        try {
          return a.lastModifiedSync().compareTo(b.lastModifiedSync());
        } catch (_) {
          return 0;
        }
      });
      for (final file in files.take(files.length - _maxEntries)) {
        try {
          file.deleteSync();
          _diskPaths.removeWhere((_, value) => value == file.path);
        } catch (_) {}
      }
    } catch (_) {}
  }

  static String _basename(String path) {
    final index = path.lastIndexOf(Platform.pathSeparator);
    return index < 0 ? path : path.substring(index + 1);
  }

  static String _firstPhoto(Object? photos) {
    if (photos is List && photos.isNotEmpty) {
      return photos.first.toString().trim();
    }
    if (photos is String) return photos.trim();
    return '';
  }
}

/// Center-crops [data] to a square, shrinks it to the card's avatar slot and
/// returns JPEG bytes inside the mirror's size budget, or null when the source
/// is not an image this build can decode.
///
/// Top-level and dependency-free so it can run in an isolate.
Uint8List? _encodeAvatarInIsolate(Uint8List data) {
  final img.Image? source;
  try {
    source = img.decodeImage(data);
  } catch (_) {
    return null;
  }
  if (source == null) return null;
  final side = math.min(source.width, source.height);
  if (side <= 0) return null;

  final img.Image square;
  try {
    square = img.copyCrop(
      source,
      x: (source.width - side) ~/ 2,
      y: (source.height - side) ~/ 2,
      width: side,
      height: side,
    );
  } catch (_) {
    return null;
  }

  final img.Image avatar;
  try {
    avatar = img.copyResize(
      square,
      width: _maxEdgePx,
      interpolation: img.Interpolation.average,
    );
  } catch (_) {
    return null;
  }

  for (var quality = 90; quality >= 35; quality -= 15) {
    try {
      final encoded = img.encodeJpg(avatar, quality: quality);
      if (encoded.length <= _maxFileBytes) {
        return encoded;
      }
    } catch (_) {
      return null;
    }
  }
  return null;
}
