import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/map_tile_cache_service.dart';

void main() {
  test('CachedMapTileProvider builds a cache-backed image for a tile', () {
    final provider = CachedMapTileProvider();
    final layer = TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    );

    final image = provider.getImage(const TileCoordinates(1, 2, 3), layer);

    expect(image, isA<ImageProvider>());
  });

  test('CachedMapTileProvider resolves the standard OSM url', () {
    final provider = CachedMapTileProvider();
    final layer = TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    );

    final url = provider.getTileUrl(const TileCoordinates(4, 5, 6), layer);

    expect(url, 'https://tile.openstreetmap.org/6/4/5.png');
  });
}
