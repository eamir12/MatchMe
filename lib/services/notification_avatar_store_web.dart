// lib/services/notification_avatar_store_web.dart
// The avatar mirror that lives inside the browser.
//
// Cache Storage is the one place this origin's page and its service worker can
// both reach, and nothing here ever leaves the device: the worker reads the
// same bucket to put a face on the cards the page did not post — backgrounded
// tab, closed browser, browser restart. `web/firebase-messaging-sw.js` opens
// [_bucket] and matches on the filename prefix, so the two sides must keep
// `_dirName`, [_bucket] and the key shape in step.
//
// The stored value is a `data:` URL rather than a `blob:` one. A blob URL dies
// with the tab that made it, and the worker would find a broken image in the
// slot the face belongs to; a data URL travels as the response body and goes to
// the notification API verbatim.
//
// Resizing happens in the browser, not in Dart. `compute` has no isolate to hand
// work to on web, so decoding a several-megabyte photo in pure Dart would stop
// the page mid-paint — which is exactly the moment a card is being posted.
// `createImageBitmap` and the canvas do the same work natively, off the main
// thread.

import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

/// The bucket the mirrored faces live in, shared with the service worker.
const String _bucket = 'matchme_notification_avatars';

/// Every key in the bucket, as a path, once this page has listed it. Cache
/// Storage keys come back as absolute URLs, so comparisons are always made on
/// the path a caller passed in.
///
/// A face another tab mirrors is not seen until this page reloads: acceptable,
/// because a card that finds no face posts the app icon instead of waiting.
Set<String>? _keys;

/// The mirrored face stored under [key], as a `data:` URL, or null when the
/// bucket has no readable image for it.
Future<String?> avatarWebMirrorLookup(String key) async {
  await _loadKeys();
  if (_keys?.contains(key) != true) return null;
  return _read(key);
}

/// The mirrored face of the conversation whose key prefix is [keyPrefix], or
/// null when it has none. One file per conversation is the invariant; the walk
/// only exists so a stale extra can never hide the current face.
Future<String?> avatarWebMirrorFindByPrefix(String keyPrefix) async {
  await _loadKeys();
  final matches = (_keys ?? const <String>{}).where((k) => k.startsWith(keyPrefix)).toList();
  for (final key in matches.reversed) {
    final face = await _read(key);
    if (face != null) return face;
  }
  return null;
}

/// Center-crops [bytes] to a square, shrinks it to the card's avatar slot and
/// stores the result under [key], dropping the oldest faces once the bucket is
/// full. Returns false when the source is not a picture this browser can decode
/// or nothing fits inside the size budget.
Future<bool> avatarWebMirrorPut({
  required String key,
  required Uint8List bytes,
  required int maxEdgePx,
  required int maxFileBytes,
  required int maxEntries,
}) async {
  final face = await _encodeDataUrl(
    bytes,
    maxEdgePx: maxEdgePx,
    maxFileBytes: maxFileBytes,
  );
  if (face == null) return false;
  try {
    final cache = await _open();
    await cache.put(key.toJS, web.Response(face.toJS)).toDart;
    _keys?.add(key);
    await _prune(cache, maxEntries);
    return true;
  } catch (_) {
    return false;
  }
}

/// Drops every face mirrored for one conversation — a new picture, or a chat
/// that is gone.
Future<void> avatarWebMirrorDrop(String keyPrefix) async {
  await _loadKeys();
  final stale = (_keys ?? const <String>{}).where((k) => k.startsWith(keyPrefix)).toList();
  if (stale.isEmpty) return;
  try {
    final cache = await _open();
    for (final key in stale) {
      await cache.delete(key.toJS).toDart;
      _keys?.remove(key);
    }
  } catch (_) {}
}

/// Logout / account deletion: no mirrored face may outlive the session.
Future<void> avatarWebMirrorWipe() async {
  _keys = null;
  try {
    await web.window.caches.delete(_bucket).toDart;
  } catch (_) {}
}

// --- internals -------------------------------------------------------------

Future<web.Cache> _open() async =>
    (await web.window.caches.open(_bucket).toDart);

Future<String?> _read(String key) async {
  try {
    final found = await (await _open()).match(key.toJS).toDart;
    if (found == null) return null;
    final text = (await found.text().toDart).toDart;
    return text.startsWith('data:image/') ? text : null;
  } catch (_) {
    return null;
  }
}

Future<void> _loadKeys() async {
  if (_keys != null) return;
  try {
    final requests = (await (await _open()).keys().toDart).toDart;
    _keys = <String>{for (final request in requests) Uri.parse(request.url).path};
  } catch (_) {
    _keys = <String>{};
  }
}

/// `keys()` returns entries in insertion order, so the front of the list is the
/// set of faces this member is least likely to see again.
Future<void> _prune(web.Cache cache, int maxEntries) async {
  try {
    final requests = (await cache.keys().toDart).toDart;
    if (requests.length <= maxEntries) return;
    for (final request in requests.take(requests.length - maxEntries)) {
      await cache.delete(request).toDart;
      _keys?.remove(Uri.parse(request.url).path);
    }
  } catch (_) {}
}

Future<String?> _encodeDataUrl(
  Uint8List bytes, {
  required int maxEdgePx,
  required int maxFileBytes,
}) async {
  web.ImageBitmap? bitmap;
  try {
    final source = web.Blob(
      <JSAny>[bytes.toJS].toJS,
      web.BlobPropertyBag(type: 'image/jpeg'),
    );
    bitmap = await web.window.createImageBitmap(source).toDart;
    final side = bitmap.width < bitmap.height ? bitmap.width : bitmap.height;
    if (side <= 0) return null;
    final canvas = web.document.createElement('canvas')
        as web.HTMLCanvasElement
      ..width = maxEdgePx
      ..height = maxEdgePx;
    final context = canvas.getContext('2d');
    if (context == null) return null;
    (context as web.CanvasRenderingContext2D).drawImage(
      bitmap,
      (bitmap.width - side) / 2,
      (bitmap.height - side) / 2,
      side,
      side,
      0,
      0,
      maxEdgePx,
      maxEdgePx,
    );
    for (var quality = 90; quality >= 35; quality -= 15) {
      final encoded = canvas.toDataURL('image/jpeg', quality.toJS);
      if (_jpegBytes(encoded) <= maxFileBytes) return encoded;
    }
    // Every quality is over budget: a face this browser cannot shrink is not
    // worth a card that arrives without one.
    return null;
  } catch (_) {
    return null;
  } finally {
    try {
      bitmap?.close();
    } catch (_) {}
  }
}

/// Approximate byte length of a `data:` URL's payload — a few bytes over the
/// real size, which is the safe direction for a budget.
int _jpegBytes(String dataUrl) {
  final comma = dataUrl.indexOf(',');
  if (comma < 0) return 1 << 30;
  return ((dataUrl.length - comma - 1) * 3) ~/ 4;
}
