// Regenerates the MatchMe launcher-icon sources WITHOUT the "MatchMe"
// wordmark (popular apps ship the bare logo inside the icon; the name is
// rendered by the OS under the icon).
//
// Source of truth: assets/images/logosmall.png (1024x1024 full lockup:
// rosette + wordmark on a light gradient background).
//
// Outputs:
//   tools/icons/app_icon.png            1024x1024, light background, rosette
//                                       centered  -> image_path (iOS, web,
//                                       macOS, Windows, Android legacy)
//   tools/icons/app_icon_foreground.png 1024x1024, transparent background,
//                                       rosette centered -> adaptive icon
//                                       foreground (Android)
//
// Run from the repo root:  dart run tools/generate_app_icon.dart
// Then:                    dart run flutter_launcher_icons

import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

const _srcPath = 'assets/images/logosmall.png';
const _outDir = 'tools/icons';
const _size = 1024;
// Rosette width as a fraction of the final canvas. Matches the optical size
// the rosette had in the old full-bleed icon (text removed, logo re-centered).
const _rosetteFraction = 0.68;

double _lum(num r, num g, num b) => 0.299 * r + 0.587 * g + 0.114 * b;

double _sat(num r, num g, num b) {
  final mx = math.max(r.toDouble(), math.max(g.toDouble(), b.toDouble()));
  if (mx <= 0) return 0;
  final mn = math.min(r.toDouble(), math.min(g.toDouble(), b.toDouble()));
  return (mx - mn) / mx;
}

void main() {
  final srcFile = File(_srcPath);
  if (!srcFile.existsSync()) {
    stderr.writeln('Missing $_srcPath');
    exit(1);
  }
  final src = img.decodeImage(srcFile.readAsBytesSync());
  if (src == null) {
    stderr.writeln('Could not decode $_srcPath');
    exit(1);
  }
  final w = src.width;
  final h = src.height;

  // ---- 1. Locate and erase the "MatchMe" wordmark (lower half only) ----
  //
  // The wordmark is the only dark content below the rosette: scan rows from
  // the bottom up while they still contain dark pixels, stopping at the first
  // run of empty rows (the gap between the wordmark and the rosette's soft
  // shadow / petals). This never reaches into the rosette itself.
  final darkCount = List<int>.filled(h, 0);
  for (var y = 0; y < h; y++) {
    var n = 0;
    for (var x = 0; x < w; x++) {
      final p = src.getPixel(x, y);
      if (_lum(p.r, p.g, p.b) < 150) n++;
    }
    darkCount[y] = n;
  }
  var bandBottom = -1;
  for (var y = h - 1; y >= 0; y--) {
    if (darkCount[y] > 0) {
      bandBottom = y;
      break;
    }
  }
  if (bandBottom < 0) {
    stderr.writeln('Wordmark not found - unexpected artwork.');
    exit(1);
  }
  var bandTop = bandBottom;
  var emptyRun = 0;
  for (var y = bandBottom; y >= 0; y--) {
    if (darkCount[y] == 0) {
      emptyRun++;
      if (emptyRun >= 5) break;
    } else {
      emptyRun = 0;
      bandTop = y;
    }
  }
  final y0 = math.max(h ~/ 2, bandTop - 16);
  final y1 = math.min(h - 1, bandBottom + 8);
  print('Wordmark band: rows [$bandTop,$bandBottom] -> erasing [$y0,$y1]');

  // Erase: for every row in the band, replace anything that is not flat
  // background (glyph strokes, colored "+", faint anti-aliased glyph tops)
  // by a linear blend between the nearest background pixels on the same row.
  // Every band row has background anchors at the far left/right (the wordmark
  // never spans the full width), and the background is a near-uniform light
  // gradient, so the repair is seamless.
  bool isBackground(img.Pixel p) =>
      _lum(p.r, p.g, p.b) >= 234 && _sat(p.r, p.g, p.b) < 0.07;
  for (var y = y0; y <= y1; y++) {
    final cleanXs = <int>[];
    for (var x = 0; x < w; x++) {
      if (isBackground(src.getPixel(x, y))) cleanXs.add(x);
    }
    if (cleanXs.length < 2) continue;
    for (var x = cleanXs.first; x <= cleanXs.last; x++) {
      final p = src.getPixel(x, y);
      if (isBackground(p)) continue;
      var i = 0;
      while (i < cleanXs.length - 1 && cleanXs[i + 1] < x) {
        i++;
      }
      final xa = cleanXs[i];
      final xb = cleanXs[math.min(i + 1, cleanXs.length - 1)];
      final pa = src.getPixel(xa, y);
      final pb = src.getPixel(xb, y);
      final t = xb == xa ? 0.0 : (x - xa) / (xb - xa);
      src.setPixelRgba(
        x,
        y,
        (pa.r + (pb.r - pa.r) * t).round().clamp(0, 255),
        (pa.g + (pb.g - pa.g) * t).round().clamp(0, 255),
        (pa.b + (pb.b - pa.b) * t).round().clamp(0, 255),
        255,
      );
    }
  }

  // ---- 2. Locate the rosette (saturated, colorful pixels) ----
  var minX = w, maxX = -1, minY = h, maxY = -1;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = src.getPixel(x, y);
      if (_sat(p.r, p.g, p.b) > 0.25 && _lum(p.r, p.g, p.b) > 40) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < 0) {
    stderr.writeln('Rosette not found.');
    exit(1);
  }
  final rosetteW = maxX - minX + 1;
  final rosetteH = maxY - minY + 1;
  print('Rosette bbox: x=[$minX,$maxX] y=[$minY,$maxY] '
      '(${rosetteW}x$rosetteH)');

  // ---- 3. Scale so the rosette hits the target fraction, then center ----
  final target = (_size * _rosetteFraction);
  final scale = target / math.max(rosetteW, rosetteH);
  final scaled = img.copyResize(
    src,
    width: math.max(1, (w * scale).round()),
    height: math.max(1, (h * scale).round()),
    interpolation: img.Interpolation.cubic,
  );
  final sMinX = (minX * scale).round();
  final sMinY = (minY * scale).round();
  final sW = math.max(1, (rosetteW * scale).round());
  final sH = math.max(1, (rosetteH * scale).round());
  final sCx = sMinX + sW / 2;
  final sCy = sMinY + sH / 2;
  final offX = (_size / 2 - sCx).round();
  final offY = (_size / 2 - sCy).round();
  print('Scale=$scale offset=($offX,$offY)');

  // Clamp-extend fill: pixels that shift off-canvas are filled by
  // replicating the nearest edge pixel, so the background gradient continues
  // naturally and no seam is visible.
  final out = img.Image(width: _size, height: _size);
  for (var y = 0; y < _size; y++) {
    final sy = math.max(0, math.min(scaled.height - 1, y - offY));
    for (var x = 0; x < _size; x++) {
      final sx = math.max(0, math.min(scaled.width - 1, x - offX));
      final p = scaled.getPixel(sx, sy);
      out.setPixelRgba(x, y, p.r.round(), p.g.round(), p.b.round(), 255);
    }
  }

  Directory(_outDir).createSync(recursive: true);
  final iconFile = File('$_outDir/app_icon.png');
  iconFile.writeAsBytesSync(img.encodePng(out));
  print('Wrote ${iconFile.path}');

  // ---- 4. Transparent-background variant for the adaptive foreground ----
  final fg = img.Image(width: _size, height: _size);
  for (var y = 0; y < _size; y++) {
    for (var x = 0; x < _size; x++) {
      final p = out.getPixel(x, y);
      final isBg =
          _sat(p.r, p.g, p.b) < 0.10 && _lum(p.r, p.g, p.b) > 215;
      if (isBg) {
        fg.setPixelRgba(x, y, 255, 255, 255, 0);
      } else {
        fg.setPixelRgba(x, y, p.r.round(), p.g.round(), p.b.round(), 255);
      }
    }
  }
  final fgFile = File('$_outDir/app_icon_foreground.png');
  fgFile.writeAsBytesSync(img.encodePng(fg));
  print('Wrote ${fgFile.path}');
}
