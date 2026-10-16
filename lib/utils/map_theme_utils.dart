import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

/// Returns flutter_map's invert + hue-rotate tile builder in dark mode, or
/// null to render the raster tiles untouched in light mode.
///
/// Only the tile layer is filtered: markers, circles and the attribution
/// widget are separate layers, so pins and credit labels keep their theme
/// colors and stay legible on the darkened map.
TileBuilder? darkMapTileBuilderFor(Brightness brightness) =>
    brightness == Brightness.dark ? darkModeTileBuilder : null;
