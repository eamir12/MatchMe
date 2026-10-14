// lib/services/map_tile_cache_service.dart
//
// Disk cache for OpenStreetMap raster tiles used by flutter_map TileLayers.
//
// The public OSM tile servers are slow and rate-limit mobile apps, so every
// cold open of the nearby/location-share maps used to sit on a grey grid
// while dozens of tiles downloaded. This keeps a small FIFO disk cache
// (Hive, bounded entry count) so repeat visits paint instantly — including
// offline — and only tiles missing from the cache hit the network.
//
// Tiles are public map data; the box is still opened through the app's
// encrypted-box helper for init consistency.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

import 'package:matchme/models/match_model.dart';
import 'package:matchme/services/hive_encryption_service.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/utils/offline_utils.dart';

/// Drop-in [TileProvider] for flutter_map [TileLayer]s that serves tiles
/// from the local disk cache first and falls back to the network.
///
/// Usage: `TileLayer(urlTemplate: ..., tileProvider: CachedMapTileProvider())`.
class CachedMapTileProvider extends TileProvider {
  CachedMapTileProvider({super.headers});

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return _CachedTileImage(url: getTileUrl(coordinates, options));
  }
}

class _CachedTileImage extends ImageProvider<_CachedTileImage> {
  _CachedTileImage({required this.url});

  final String url;

  @override
  Future<_CachedTileImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<_CachedTileImage>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    _CachedTileImage key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1.0,
      debugLabel: key.url,
    );
  }

  Future<ui.Codec> _loadAsync(
    _CachedTileImage key,
    ImageDecoderCallback decode,
  ) async {
    var bytes = await MapTileCacheService.instance.getTileBytes(key.url);
    if (bytes == null || bytes.isEmpty) {
      // Graceful fallback: return a synthesized cartographic offline map tile
      // so the minimap never shows an empty gray hole when offline.
      try {
        bytes =
            await MapTileCacheService.instance.getOfflineFallbackTileBytes();
      } catch (_) {}
    }
    if (bytes == null || bytes.isEmpty) {
      throw StateError('Map tile unavailable: ${key.url}');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is _CachedTileImage && other.url == url);

  @override
  int get hashCode => url.hashCode;
}

class MapTileCacheService {
  MapTileCacheService._();
  static final MapTileCacheService instance = MapTileCacheService._();

  static const String _boxName = 'map_tiles';

  /// Max cached tiles. At ~20–60 KB per PNG tile this bounds the cache to
  /// roughly 10–30 MB.
  static const int _maxEntries = 500;

  /// Tiles older than this are re-fetched (served stale if offline).
  static const Duration _maxAge = Duration(days: 30);

  static const Duration _httpTimeout = Duration(seconds: 12);

  Future<Box>? _boxFuture;

  Future<Box?> _getBox() async {
    try {
      _boxFuture ??= HiveEncryptionService.instance.openEncryptedBoxDynamic(
        _boxName,
      );
      return await _boxFuture!;
    } catch (_) {
      // Box unavailable (e.g. storage failure): run network-only rather
      // than breaking the map.
      _boxFuture = null;
      return null;
    }
  }

  /// Returns the tile bytes for [url] from disk, or fetches + caches them.
  /// Returns stale cached bytes when the network fails, null when nothing
  /// is available.
  Future<Uint8List?> getTileBytes(String url) async {
    final key = url;
    Uint8List? stale;
    final box = await _getBox();
    if (box == null && kDebugMode && !_boxWarned) {
      _boxWarned = true;
      print(
        '[MapTiles] ⚠️ tile cache box unavailable — tiles will NOT render '
        'offline. Check HiveEncryptionService logs.',
      );
    }
    try {
      if (box != null) {
        final entry = box.get(key);
        final bytes = _bytesFromEntry(entry);
        if (bytes != null) {
          if (!_isExpired(entry)) {
            // Refresh recency so frequently viewed areas survive eviction
            // (approximate LRU over Hive's insertion-ordered keys). Awaited
            // and bounded: the delete+put pair must not be torn by an early
            // process death, which would lose the tile.
            try {
              await _touch(box, key, entry).timeout(const Duration(seconds: 2));
            } catch (_) {}
            return bytes;
          }
          stale = bytes;
        }
      }
    } catch (_) {}

    try {
      final resp = await http
          .get(Uri.parse(url), headers: const {'User-Agent': 'matchme.app'})
          .timeout(_httpTimeout);
      if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
        final bytes = Uint8List.fromList(resp.bodyBytes);
        // Await the disk write (bounded) instead of fire-and-forget: the
        // in-session Flutter image cache masks a failed store, so a tile
        // fetched online would silently vanish after a process restart.
        try {
          await _store(key, bytes).timeout(const Duration(seconds: 2));
        } catch (_) {}
        return bytes;
      }
      if (kDebugMode) {
        print('[MapTiles] tile fetch HTTP ${resp.statusCode}: $key');
      }
    } catch (_) {}

    if (stale == null && kDebugMode) {
      print(
        '[MapTiles] offline miss (tile not cached and network failed): $key',
      );
      if (!_missBoxCountLogged) {
        _missBoxCountLogged = true;
        try {
          final b = await _getBox();
          print(
            '[MapTiles] first miss context — tile cache holds '
            '${b?.length ?? 'UNAVAILABLE'} tiles',
          );
        } catch (_) {}
      }
    }
    return stale;
  }

  bool _boxWarned = false;
  bool _missBoxCountLogged = false;
  int _storeCount = 0;

  static Uint8List? _fallbackTilePngBytes;

  /// Returns a synthesized 256x256 PNG map tile with warm cartographic terrain
  /// and delicate street grid lines. Used as a graceful fallback when offline
  /// so a minimap NEVER renders as an empty gray void.
  Future<Uint8List> getOfflineFallbackTileBytes() async {
    if (_fallbackTilePngBytes != null && _fallbackTilePngBytes!.isNotEmpty) {
      return _fallbackTilePngBytes!;
    }
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, 256, 256));

      // Warm cartographic land base (never gloomy gray)
      final bgPaint = Paint()..color = const Color(0xFFF4F0E8);
      canvas.drawRect(const Rect.fromLTWH(0, 0, 256, 256), bgPaint);

      // Natural park/landscape patches
      final parkPaint = Paint()
        ..color = const Color(0xFFE9EEDD)
        ..style = PaintingStyle.fill;
      final parkPath = Path()
        ..moveTo(24, 48)
        ..cubicTo(70, 24, 120, 56, 100, 110)
        ..cubicTo(80, 150, 40, 130, 16, 90)
        ..close();
      canvas.drawPath(parkPath, parkPaint);

      final parkPath2 = Path()
        ..moveTo(160, 170)
        ..cubicTo(210, 140, 250, 180, 235, 230)
        ..cubicTo(195, 250, 165, 215, 160, 170)
        ..close();
      canvas.drawPath(parkPath2, parkPaint);

      // Street grid & arteries - seamlessly aligns at 64px boundaries
      final roadBorderPaint = Paint()
        ..color = const Color(0xFFE5E0D4)
        ..strokeWidth = 4.5
        ..style = PaintingStyle.stroke;
      final majorRoadPaint = Paint()
        ..color = const Color(0xFFFFFFFF)
        ..strokeWidth = 3.0
        ..style = PaintingStyle.stroke;
      final minorRoadPaint = Paint()
        ..color = const Color(0xFFFFFFFF)
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke;

      // Major road crossing
      final mainRoad = Path()
        ..moveTo(0, 128)
        ..cubicTo(80, 122, 176, 134, 256, 128);
      canvas.drawPath(mainRoad, roadBorderPaint);
      canvas.drawPath(mainRoad, majorRoadPaint);

      final crossRoad = Path()
        ..moveTo(128, 0)
        ..cubicTo(122, 80, 134, 176, 128, 256);
      canvas.drawPath(crossRoad, roadBorderPaint);
      canvas.drawPath(crossRoad, majorRoadPaint);

      // Minor streets at multiples of 64
      final minorRoads = Path()
        ..moveTo(0, 64)
        ..lineTo(256, 64)
        ..moveTo(0, 192)
        ..lineTo(256, 192)
        ..moveTo(64, 0)
        ..lineTo(64, 256)
        ..moveTo(192, 0)
        ..lineTo(192, 256);
      canvas.drawPath(minorRoads, minorRoadPaint);

      final picture = recorder.endRecording();
      final img = await picture.toImage(256, 256);
      final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
      _fallbackTilePngBytes = byteData!.buffer.asUint8List();
      return _fallbackTilePngBytes!;
    } catch (_) {
      return Uint8List(0);
    }
  }

  /// Pre-fetches the tiles covering [centerLat]/[centerLng] at [zoom]
  /// (including [radius] neighbours in each direction) into the disk cache so
  /// a map area viewed once while online renders completely when offline.
  /// Warms both rounded integer zoom (as requested by flutter_map TileLayer)
  /// and floor zoom to guarantee offline cache hits.
  Future<void> warmArea({
    required double centerLat,
    required double centerLng,
    required double zoom,
    int radius = 1,
  }) async {
    final targetZ = zoom.round().clamp(1, 19);
    final zoomsToWarm = <int>{targetZ};
    if (zoom.floor() != targetZ) {
      zoomsToWarm.add(zoom.floor().clamp(1, 19));
    }

    final urls = <String>[];
    for (final z in zoomsToWarm) {
      final n = 1 << z;
      final latRad = centerLat * math.pi / 180.0;
      final xf = (centerLng + 180.0) / 360.0 * n;
      final yf =
          (1.0 - math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi) /
          2.0 *
          n;
      final cx = xf.floor();
      final cy = yf.floor();
      for (var dx = -radius; dx <= radius; dx++) {
        for (var dy = -radius; dy <= radius; dy++) {
          final x = cx + dx;
          final y = cy + dy;
          if (x < 0 || x >= n || y < 0 || y >= n) continue;
          urls.add('https://tile.openstreetmap.org/$z/$x/$y.png');
        }
      }
    }

    // Await downloading in small batches of 3 so tiles are written to disk
    // without flooding the network or server.
    for (var i = 0; i < urls.length; i += 3) {
      final batch = urls.skip(i).take(3);
      await Future.wait(
        batch.map((url) => getTileBytes(url).catchError((_) => null)),
      );
    }
  }

  // Areas already queued for pre-warming in this session (dedupe key).
  final Set<String> _warmedAreas = {};
  bool _warmPassInFlight = false;

  /// Pre-warms tiles for every cached match minimap snapshot so a match
  /// whose location was ever synced renders offline even if its profile
  /// screen was last viewed before tile caching existed. No-op when offline.
  /// Budgeted per pass and de-duplicated per session, so calling this after
  /// every sync is cheap.
  Future<void> warmCachedMatchMinimaps() async {
    // Unconditional (debug): proves this build contains the tile-cache module.
    // A run with no such line means the build is stale.
    if (kDebugMode) {
      print(
        '[MapTiles] warmCachedMatchMinimaps called (online='
        '${!shouldSkipSupabaseCalls()})',
      );
    }
    if (shouldSkipSupabaseCalls()) {
      if (kDebugMode) {
        print('[MapTiles] warm pass skipped — offline');
      }
      return;
    }
    if (_warmPassInFlight) return;
    _warmPassInFlight = true;
    try {
      final db = await LocalDbService.instance;
      final snapshots = await db.getAllMatchMinimapSnapshots();
      var budget = 50; // max areas (x9 tiles) per pass
      for (final locations in snapshots.values) {
        for (final loc in locations) {
          if (budget <= 0) return;
          final area = _displayAreaFor(loc);
          if (area == null) continue;
          final key =
              '${area.$1.toStringAsFixed(5)},'
              '${area.$2.toStringAsFixed(5)},${area.$3}';
          if (_warmedAreas.contains(key)) continue;
          _warmedAreas.add(key);
          budget--;
          await warmArea(
            centerLat: area.$1,
            centerLng: area.$2,
            zoom: area.$3,
            radius: 1,
          );
        }
      }
    } catch (_) {
      // Pre-warming is best-effort; the map fetches on demand regardless.
    } finally {
      _warmPassInFlight = false;
      if (kDebugMode) {
        try {
          final box = await _getBox();
          print(
            '[MapTiles] warm pass done — tile cache now holds '
            '${box?.length ?? 'UNAVAILABLE'} tiles',
          );
        } catch (e) {
          print('[MapTiles] warm pass summary failed: $e');
        }
      }
    }
  }

  /// Display center/zoom for a serialized [MatchLocation] JSON map — delegates
  /// to [MatchLocation.displayView] so pre-warmed tiles always match what
  /// MatchLocationMiniMap actually renders (coverage-based zoom, coarse
  /// center, no precise pins).
  (double, double, double)? _displayAreaFor(Map<dynamic, dynamic> loc) {
    try {
      final view = MatchLocation.fromJson(
        Map<String, dynamic>.from(loc),
      ).displayView();
      if (view == null) return null;
      return (view.centerLat, view.centerLng, view.zoom);
    } catch (_) {
      return null;
    }
  }

  Uint8List? _bytesFromEntry(dynamic entry) {
    try {
      if (entry is Map) {
        final b = entry['b'];
        if (b is Uint8List && b.isNotEmpty) return b;
        if (b is List && b.isNotEmpty) {
          return Uint8List.fromList(b.cast<int>());
        }
      } else if (entry is Uint8List && entry.isNotEmpty) {
        // Legacy plain-bytes entry.
        return entry;
      }
    } catch (_) {}
    return null;
  }

  bool _isExpired(dynamic entry) {
    try {
      if (entry is Map) {
        final ts = entry['t'];
        if (ts is int) {
          return DateTime.now().millisecondsSinceEpoch - ts >
              _maxAge.inMilliseconds;
        }
      }
    } catch (_) {}
    return false;
  }

  Future<void> _touch(Box box, String key, dynamic entry) async {
    try {
      await box.delete(key);
      await box.put(key, entry);
    } catch (_) {}
  }

  Future<void> _store(String key, Uint8List bytes) async {
    try {
      final box = await _getBox();
      if (box == null) return;
      if (box.length >= _maxEntries) {
        // Evict the oldest ~20% (keys iterate in insertion order).
        final victims = box.keys.cast<String>().take(100).toList();
        for (final v in victims) {
          try {
            await box.delete(v);
          } catch (_) {}
        }
      }
      await box.put(key, {
        'b': bytes,
        't': DateTime.now().millisecondsSinceEpoch,
      });
      _storeCount++;
      if (kDebugMode && (_storeCount == 1 || _storeCount % 25 == 0)) {
        print(
          '[MapTiles] stored tile #$_storeCount (box now ${box.length} entries): $key',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        print('[MapTiles] ⚠️ failed to store tile ($key): $e');
      }
    }
  }
}
