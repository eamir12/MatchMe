import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:matchme/services/offline_image_cache.dart';
import 'package:matchme/services/storage_helper.dart';
import 'package:path_provider/path_provider.dart';

import 'notification_avatar_store_stub.dart'
    if (dart.library.html) 'notification_avatar_store_web.dart';

/// The avatar slot a card gives the sender's face, and the budget one mirrored
/// file may take. Top-level because the isolate that resizes needs them too.
const int _maxEdgePx = 128;
const int _maxFileBytes = 32 * 1024;
const int _maxEntries = 64;

/// Name of the mirror folder, shared by the native and browser stores.
const String _dirName = 'notification_avatars';

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
/// The stores differ by platform. Android hands bytes over the
/// background-service channel and Kotlin owns the files under `noBackupFilesDir`.
/// Windows stores them under `%LOCALAPPDATA%\MatchMe`; iOS and macOS use the
/// operating system's temporary directory because their notification APIs copy
/// attachments when the notification is scheduled. iOS also mirrors the
/// resized file into the app's App Group container for the notification
/// extension. Web writes to Cache Storage, which the page and service worker
/// can both reach.
///
/// **Reading never uses the channel.** The FCM background isolate registers real
/// plugin classes only, so `matchme/background_service` has no handler there, and
/// a read that went over it would find no face at all - which is exactly the card
/// a member sees when the app is backgrounded. Every store is a plain location
/// this process can walk itself.
///
/// This runs **regardless of the "show message previews" setting**. That
/// setting hides message text, not the sender's face or name - a card with
/// previews off still says who is writing.
class NotificationAvatarService {
  NotificationAvatarService._();

  static final NotificationAvatarService instance =
      NotificationAvatarService._();

  static const MethodChannel _channel = MethodChannel(
    'matchme/background_service',
  );

  /// The avatar source this process has already dealt with for a conversation.
  /// A different source for the same conversation is a new member picture and
  /// has to be re-mirrored, so the value is the source key, not a bool.
  final Map<String, String> _handed = {};
  final Map<String, String> _sharedHanded = {};

  /// Mirrored faces this process can point a card at, by conversation, so
  /// neither a toast's image URI nor Android's `largeIcon` path is looked up
  /// while a card is being built. On web the value is the conversation's Cache
  /// Storage key, which is one list away from the `data:` URL itself.
  final Map<String, String> _diskPaths = {};

  /// Which photo each conversation's face comes from, collected from the chat
  /// rows that fill the mirror. A card that finds its mirror empty needs this to
  /// know what to go and get.
  final Map<String, String> _sources = {};

  /// The one recovery attempt made for a conversation, so several cards for the
  /// same face share it and a picture already fetched is never fetched twice.
  final Map<String, Future<String?>> _recoveries = {};

  /// The picture [_recoveries] holds an attempt for. A member's new photo is a
  /// different picture, so it re-arms the attempt.
  final Map<String, String> _recoverySources = {};

  /// How long a card waits for a recovery before posting without a face.
  static const Duration _recoveryCap = Duration(milliseconds: 1500);

  /// Android draws its card in Kotlin, which cannot read the encrypted cache,
  /// so the bytes go over the channel and Kotlin owns the file.
  static bool get _usesNativeStore => !kIsWeb && Platform.isAndroid;

  /// These notification APIs consume a local image path, so Dart owns the
  /// mirror file on platforms without Android's native store.
  static bool get _usesDiskStore =>
      !kIsWeb && (Platform.isWindows || Platform.isIOS || Platform.isMacOS);

  /// A browser card takes an image URL the notification API can fetch, and the
  /// service worker that posts the background ones is a separate process that
  /// must find the face on its own — so web mirrors into Cache Storage.
  static bool get _usesWebStore => kIsWeb;

  static bool get _supported =>
      _usesNativeStore || _usesDiskStore || _usesWebStore;

  /// Mirrors the first photo of every chat row, from bytes the app already has.
  ///
  /// Never downloads: the avatars worth mirroring are the ones Home or the chat
  /// list has already painted, and the startup warm prefetches them. A row whose
  /// picture was never loaded is remembered anyway, because a card that later
  /// finds nothing for it goes and gets that picture once - see [_recoverFace].
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
    _sources[id] = source;
    if (_handed[id] == cacheKey) {
      await _syncIosSharedMirror(id, cacheKey);
      return;
    }

    // Asking the store before loading the bytes is what keeps a warm relaunch
    // cheap: the avatars it already has never leave Dart again.
    if (_usesWebStore) {
      if (await avatarWebMirrorLookup(_webKey(id, cacheKey)) != null) {
        _handed[id] = cacheKey;
        return;
      }
    } else if (await _mirrorPath(id, cacheKey: cacheKey) != null) {
      _handed[id] = cacheKey;
      await _syncIosSharedMirror(id, cacheKey);
      return;
    }

    final bytes = await OfflineImageCache.instance.read(cacheKey);
    if (bytes == null || bytes.isEmpty) return;

    if (_usesNativeStore) {
      try {
        await _channel.invokeMethod<void>('mirrorNotificationAvatar', {
          'matchId': id,
          'cacheKey': cacheKey,
          'bytes': bytes,
        });
      } catch (_) {
        return;
      }
      // Kotlin resizes on its own schedule. Remembering where the face lands is
      // what lets a card built a moment later find it without another walk.
      final dir = await _mirrorDir();
      if (dir != null) _diskPaths[id] = _filePath(dir, id, cacheKey);
    } else if (_usesWebStore) {
      await _writeWebMirror(id, cacheKey, bytes);
    } else {
      await _writeDiskMirror(id, cacheKey, bytes);
    }
    _handed[id] = cacheKey;
    await _syncIosSharedMirror(id, cacheKey);
  }

  /// The mirrored face for [matchId] as something a card can show — a path this
  /// process can open on Android and Windows, a `data:` URL on web — or null
  /// when the conversation has none.
  ///
  /// A warm cache costs nothing. A miss costs one directory walk, because the
  /// FCM background isolate starts empty and still has to put a face on the first
  /// card it posts. Only when that walk comes back empty does the card take one
  /// bounded shot at the photo itself, so a face the member has not looked at
  /// yet still ends up beside their name.
  Future<String?> resolvePath(String matchId) async {
    if (!_supported) return null;
    final id = matchId.trim();
    if (id.isEmpty) return null;
    if (_usesWebStore) {
      final mirrored = await _webFace(id);
      return mirrored ?? await _recoverFace(id);
    }
    final known = _diskPaths[id];
    if (known != null) {
      if (File(known).existsSync()) return known;
      _diskPaths.remove(id);
    }
    final mirrored = await _mirrorPath(id);
    return mirrored ?? await _recoverFace(id);
  }

  /// Goes and gets the conversation's picture once, for a card the mirror has
  /// nothing for, and returns the face the moment it is mirrored.
  ///
  /// The card waits [_recoveryCap] and then posts without a face; the attempt
  /// itself is not cancelled, so a slow download still lands in the mirror and
  /// answers the next card - and, on web, the service worker's cards. One
  /// attempt per picture per process: a photo the bucket does not have is not
  /// worth a request and a wait on every card.
  ///
  /// A remembered answer is only worth handing over while its file is still
  /// there. The mirror is outside this process's control - the budget prunes it,
  /// a cleaner can empty the folder - and a toast pointed at a path that no
  /// longer exists draws an empty avatar slot, which looks exactly like the
  /// missing face this whole service exists to prevent. So a stale answer
  /// re-arms the attempt instead of being believed, for one more bounded shot.
  Future<String?> _recoverFace(String matchId) async {
    for (var shot = 0; shot < 2; shot++) {
      final source = _sources[matchId];
      if (source == null || source.isEmpty) return null;
      if (_recoverySources[matchId] != source) {
        _recoverySources[matchId] = source;
        _recoveries[matchId] = _mirrorFromBucket(matchId, source);
      }
      final attempt = _recoveries[matchId];
      if (attempt == null) return null;
      final face = await _waitedFace(attempt);
      if (face == null) return null;
      if (_usesWebStore || File(face).existsSync()) return face;
      _recoverySources.remove(matchId);
      _recoveries.remove(matchId);
    }
    return null;
  }

  /// The recovery's answer, or null when it outstays [_recoveryCap]. The timeout
  /// is on the wait, never on the attempt: a card that gave up still gets its
  /// face from the download that keeps going.
  Future<String?> _waitedFace(Future<String?> attempt) async {
    try {
      return await attempt.timeout(_recoveryCap);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _mirrorFromBucket(String matchId, String source) async {
    final bytes = await StorageHelper.loadImageBytes(source);
    if (bytes == null || bytes.isEmpty) return null;
    // The download outlived its conversation: a member who deleted their photo
    // or left the match must not get their face mirrored now.
    if (_sources[matchId] != source) return null;
    // The store just answered nothing for this conversation, so whatever the
    // latch remembers about it - a file since pruned, a Cache Storage entry the
    // browser evicted - is stale. Dropping it is what lets the write below
    // happen instead of returning early.
    _handed.remove(matchId);
    await mirrorFor(matchId: matchId, photoSource: source);
    return _usesWebStore ? _webFace(matchId) : _mirrorPath(matchId);
  }

  /// The browser half of [resolvePath]. The remembered key answers a warm lookup
  /// from the list this page already holds; a miss costs one pass over that same
  /// list, because a card that arrives after a reload knows the conversation and
  /// nothing else.
  Future<String?> _webFace(String matchId) async {
    final known = _diskPaths[matchId];
    if (known != null) {
      final face = await avatarWebMirrorLookup(known);
      if (face != null) return face;
      _diskPaths.remove(matchId);
    }
    return avatarWebMirrorFindByPrefix(_webKeyPrefix(matchId));
  }

  /// A chat that is gone takes its face with it.
  Future<void> evict(String matchId) async {
    final id = matchId.trim();
    if (id.isEmpty) return;
    _handed.remove(id);
    _sharedHanded.remove(id);
    _diskPaths.remove(id);
    _sources.remove(id);
    _recoveries.remove(id);
    _recoverySources.remove(id);
    if (_usesWebStore) {
      await avatarWebMirrorDrop(_webKeyPrefix(id));
      return;
    }
    if (_usesDiskStore) {
      await _deleteMirrors(id);
      await _deleteIosSharedMirror(id);
      return;
    }
    if (!_supported) return;
    try {
      await _channel.invokeMethod<bool>('evictNotificationAvatar', {
        'matchId': id,
      });
    } catch (_) {}
  }

  /// Logout / account deletion: no mirrored avatar may outlive the session.
  Future<void> clearAll() async {
    _handed.clear();
    _sharedHanded.clear();
    _diskPaths.clear();
    if (_usesWebStore) {
      await avatarWebMirrorWipe();
      return;
    }
    if (_usesDiskStore) {
      await _deleteAllMirrors();
      await _clearIosSharedMirrors();
      return;
    }
    if (!_supported) return;
    try {
      await _channel.invokeMethod<bool>('clearNotificationAvatars');
    } catch (_) {}
  }

  // --- the mirror in the browser --------------------------------------------

  /// The Cache Storage key a mirrored face lives under: the same filename the
  /// native mirror writes, in the folder the service worker reads.
  static String _webKey(String matchId, String cacheKey) =>
      '/$_dirName/${_fileName(matchId, cacheKey)}';

  static String _webKeyPrefix(String matchId) =>
      '/$_dirName/${_idHash(matchId)}-';

  Future<void> _writeWebMirror(
    String matchId,
    String cacheKey,
    Uint8List bytes,
  ) async {
    // A different file for the same conversation is the member's new picture:
    // the old face goes first, so a deleted photo cannot outlive it.
    await avatarWebMirrorDrop(_webKeyPrefix(matchId));
    final key = _webKey(matchId, cacheKey);
    // The browser does the decoding here: Dart has no isolate to hand it to on
    // web, and a multi-megabyte photo must not be decoded on the thread that is
    // about to paint the card.
    if (await avatarWebMirrorPut(
      key: key,
      bytes: bytes,
      maxEdgePx: _maxEdgePx,
      maxFileBytes: _maxFileBytes,
      maxEntries: _maxEntries,
    )) {
      _diskPaths[matchId] = key;
    }
  }

  // --- the mirror on disk ---------------------------------------------------

  /// The directory this platform's mirrored faces live in, or null when it has
  /// none.
  ///
  /// Android's store is Kotlin's, under `no_backup`: the sibling of the directory
  /// `getApplicationSupportDirectory()` returns, which is Android's own
  /// `Context.getFilesDir()`. Both names come from the framework, so the one hop
  /// is as good as asking Kotlin - and it works from an isolate that has no
  /// handler on our channel.
  static Future<Directory?> _mirrorDir() async {
    if (kIsWeb) return null;
    if (Platform.isWindows) return _windowsDir();
    if (Platform.isAndroid) {
      try {
        final filesDir = await getApplicationSupportDirectory();
        return Directory(
          '${filesDir.parent.path}${Platform.pathSeparator}no_backup'
          '${Platform.pathSeparator}$_dirName',
        );
      } catch (_) {
        return null;
      }
    }
    if (Platform.isIOS || Platform.isMacOS) {
      try {
        final tempDir = await getTemporaryDirectory();
        return Directory('${tempDir.path}${Platform.pathSeparator}$_dirName');
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// The conversation's mirrored face: [cacheKey]'s exactly when a key is given,
  /// otherwise whichever avatar of it is on disk.
  Future<String?> _mirrorPath(String matchId, {String? cacheKey}) async {
    final dir = await _mirrorDir();
    if (dir == null) return null;
    if (cacheKey != null) {
      final exact = File(_filePath(dir, matchId, cacheKey));
      if (!exact.existsSync()) return null;
      _diskPaths[matchId] = exact.path;
      return exact.path;
    }
    final prefix = _idHash(matchId);
    try {
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final name = _basename(entity.path);
        if (!name.startsWith('$prefix-') || !name.endsWith('.jpg')) continue;
        _diskPaths[matchId] = entity.path;
        return entity.path;
      }
    } catch (_) {}
    return null;
  }

  /// `<sha(matchId)>-<sha(cacheKey) prefix>.jpg`, so a member who changes their
  /// picture gets a new file and the old one is dropped, and a face is never
  /// stored under a readable conversation id. Kotlin's `fileNameFor` and
  /// `web/firebase-messaging-sw.js` build the same name from the same two
  /// hashes.
  static String _fileName(String matchId, String cacheKey) =>
      '${_idHash(matchId)}-${_cacheKeyHash(cacheKey)}.jpg';

  static String _cacheKeyHash(String cacheKey) =>
      sha256.convert(utf8.encode(cacheKey)).toString().substring(0, 16);

  static String _filePath(Directory dir, String matchId, String cacheKey) =>
      '${dir.path}${Platform.pathSeparator}${_fileName(matchId, cacheKey)}';

  static String _idHash(String matchId) =>
      sha256.convert(utf8.encode(matchId)).toString();

  /// The stored bytes are the member's real photo, and decoding several
  /// megabytes in pure Dart is far too much work to take from the thread
  /// painting the tray card, so the resize runs in an isolate.
  static Future<Uint8List?> _encodeAvatar(Uint8List bytes) =>
      compute(_encodeAvatarInIsolate, bytes);

  Future<void> _deleteMirrors(String matchId, {Directory? directory}) async {
    final dir = directory ?? await _mirrorDir();
    if (dir == null || !dir.existsSync()) return;
    final prefix = _idHash(matchId);
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

  Future<void> _deleteAllMirrors() async {
    final dir = await _mirrorDir();
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
  void _pruneDir(Directory dir) {
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

  // --- the Windows store, written by Dart -----------------------------------

  static Directory? _windowsDir() {
    final localAppData = (Platform.environment['LOCALAPPDATA'] ?? '').trim();
    if (localAppData.isEmpty) return null;
    return Directory(
      '$localAppData${Platform.pathSeparator}MatchMe'
      '${Platform.pathSeparator}$_dirName',
    );
  }

  Future<void> _writeDiskMirror(
    String matchId,
    String cacheKey,
    Uint8List bytes,
  ) async {
    final dir = await _mirrorDir();
    if (dir == null) return;
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final avatar = await _encodeAvatar(bytes);
      if (avatar == null) return;
      final target = File(_filePath(dir, matchId, cacheKey));
      // A different file for the same conversation is the member's new
      // picture: the old face goes, so a deleted photo cannot outlive it.
      await _deleteMirrors(matchId, directory: dir);
      final staged = File('${target.path}.tmp');
      await staged.writeAsBytes(avatar, flush: true);
      await staged.rename(target.path);
      _diskPaths[matchId] = target.path;
      _pruneDir(dir);
    } catch (_) {}
  }

  /// Copy the already-resized local mirror into the App Group for the iOS
  /// notification service extension. The extension never fetches a photo URL.
  Future<void> _syncIosSharedMirror(String matchId, String cacheKey) async {
    if (!Platform.isIOS || _sharedHanded[matchId] == cacheKey) return;
    final path = await _mirrorPath(matchId, cacheKey: cacheKey);
    if (path == null) return;
    try {
      final bytes = await File(path).readAsBytes();
      await _channel.invokeMethod<void>('mirrorSharedNotificationAvatar', {
        'fileName': _basename(path),
        'bytes': bytes,
      });
      _sharedHanded[matchId] = cacheKey;
    } catch (error) {
      debugPrint(
        'Notification avatar: Could not mirror to iOS App Group: $error',
      );
    }
  }

  Future<void> _deleteIosSharedMirror(String matchId) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('evictSharedNotificationAvatar', {
        'matchId': matchId,
      });
    } catch (error) {
      debugPrint(
        'Notification avatar: Could not evict iOS shared mirror: $error',
      );
    }
  }

  Future<void> _clearIosSharedMirrors() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('clearSharedNotificationAvatars');
    } catch (error) {
      debugPrint(
        'Notification avatar: Could not clear iOS shared mirrors: $error',
      );
    }
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
