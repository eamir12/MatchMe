import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/utils/map_theme_utils.dart';

void main() {
  test('light mode leaves raster map tiles unfiltered', () {
    expect(darkMapTileBuilderFor(Brightness.light), isNull);
  });

  test('dark mode delegates to the flutter_map dark tile builder', () {
    final builder = darkMapTileBuilderFor(Brightness.dark);
    expect(builder, isNotNull);
    expect(builder, same(darkModeTileBuilder));
  });
}
