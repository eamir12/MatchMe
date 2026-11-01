// A small drawn illustration of the outfit a Spot me card describes.
//
// The figure is decorative: the text rows next to it carry every fact for
// screen readers, so the painter canvas is excluded from Semantics. Colours
// are the same tokens the composer stores; legacy free-text colours render as
// a hatched swatch instead of being dropped.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

enum MeetupOutfitGender { female, male, neutral }

/// Maps a profile gender value to one of the three silhouettes. Non-binary,
/// unset, or not-yet-loaded profiles get the neutral figure.
MeetupOutfitGender meetupOutfitGenderFromProfile(String? rawGender) {
  var gender = (rawGender ?? '').trim().toLowerCase().replaceAll('-', '_');
  if (gender.startsWith('gender_')) {
    gender = gender.substring('gender_'.length);
  }
  if (gender == 'female' || gender == 'f') return MeetupOutfitGender.female;
  if (gender == 'male' || gender == 'm') return MeetupOutfitGender.male;
  return MeetupOutfitGender.neutral;
}

/// The six outfit values stored on a Spot me card.
class MeetupOutfitSpec {
  final String? shirt;
  final String? shirtColor;
  final String? pants;
  final String? pantsColor;
  final String? shoes;
  final String? shoesColor;

  const MeetupOutfitSpec({
    this.shirt,
    this.shirtColor,
    this.pants,
    this.pantsColor,
    this.shoes,
    this.shoesColor,
  });

  factory MeetupOutfitSpec.fromMap(Map<String, dynamic> map) {
    String? read(String key) {
      final value = map[key]?.toString().trim();
      return value == null || value.isEmpty ? null : value;
    }

    return MeetupOutfitSpec(
      shirt: read('shirt'),
      shirtColor: read('shirt_color'),
      pants: read('pants'),
      pantsColor: read('pants_color'),
      shoes: read('shoes'),
      shoesColor: read('shoes_color'),
    );
  }

  bool get isDress => shirt == 'dress';

  bool get hasPants => pants != null || pantsColor != null;

  /// A dress hides the pants row, unless pants were explicitly shared.
  bool get showsPants => !isDress || hasPants;

  bool get isEmpty =>
      shirt == null &&
      shirtColor == null &&
      pants == null &&
      pantsColor == null &&
      shoes == null &&
      shoesColor == null;

  @override
  bool operator ==(Object other) =>
      other is MeetupOutfitSpec &&
      other.shirt == shirt &&
      other.shirtColor == shirtColor &&
      other.pants == pants &&
      other.pantsColor == pantsColor &&
      other.shoes == shoes &&
      other.shoesColor == shoesColor;

  @override
  int get hashCode =>
      Object.hash(shirt, shirtColor, pants, pantsColor, shoes, shoesColor);
}

const Map<String, Color> kMeetupOutfitColors = <String, Color>{
  'black': Color(0xFF1F2937),
  'white': Color(0xFFFFFFFF),
  'gray': Color(0xFF9CA3AF),
  'beige': Color(0xFFD8C3A5),
  'brown': Color(0xFF8B5E3C),
  'navy': Color(0xFF1E3A8A),
  'blue': Color(0xFF2563EB),
  'light_blue': Color(0xFF38BDF8),
  'green': Color(0xFF16A34A),
  'olive': Color(0xFF6B7A3A),
  'red': Color(0xFFDC2626),
  'burgundy': Color(0xFF7F1D1D),
  'pink': Color(0xFFEC4899),
  'yellow': Color(0xFFFACC15),
  'orange': Color(0xFFF97316),
  'purple': Color(0xFF7C3AED),
  'gold': Color(0xFFD4AF37),
  'silver': Color(0xFFC0C0C0),
};

const List<Color> kMeetupMulticolorGradient = <Color>[
  Color(0xFFEF4444),
  Color(0xFFF59E0B),
  Color(0xFF10B981),
  Color(0xFF3B82F6),
  Color(0xFF8B5CF6),
];

const List<Color> _kGoldGradient = <Color>[
  Color(0xFFF7E08B),
  Color(0xFFB8860B),
];

const List<Color> _kSilverGradient = <Color>[
  Color(0xFFFFFFFF),
  Color(0xFF94A3B8),
];

const Color _kGarmentFallback = Color(0xFFE2E8F0);
const Color _kGarmentStroke = Color(0x8064748B);
const Color _kHatchLine = Color(0xFF94A3B8);
const Color _kGhostFill = Color(0x248BA3B8);
const Color _kGhostStroke = Color(0x8C64748B);

bool _isKnownColorToken(String? token) =>
    token == 'multicolor' ||
    token == 'gold' ||
    token == 'silver' ||
    kMeetupOutfitColors.containsKey(token);

/// A 13 px colour chip that mirrors the figure's garment fill: solid for a
/// token, gradient for multicolour/gold/silver, hatched for legacy text and
/// an empty dashed box when no colour was chosen.
class MeetupColorSwatch extends StatelessWidget {
  final String? color;
  final double size;

  const MeetupColorSwatch({super.key, required this.color, this.size = 13});

  @override
  Widget build(BuildContext context) {
    final token = color?.trim();
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _SwatchPainter(
          token: token == null || token.isEmpty ? null : token,
          borderColor: Theme.of(
            context,
          ).colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
        ),
      ),
    );
  }
}

class _SwatchPainter extends CustomPainter {
  final String? token;
  final Color borderColor;

  const _SwatchPainter({required this.token, required this.borderColor});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final radius = Radius.circular(size.width * 0.3);
    final rrect = RRect.fromRectAndRadius(rect, radius);
    final token = this.token;

    if (token != null) {
      canvas.save();
      canvas.clipRRect(rrect);
      if (token == 'multicolor') {
        _fillGradient(canvas, rect, kMeetupMulticolorGradient, const [
          0,
          0.25,
          0.5,
          0.75,
          1,
        ]);
      } else if (token == 'gold') {
        _fillGradient(canvas, rect, _kGoldGradient, const [0, 1]);
      } else if (token == 'silver') {
        _fillGradient(canvas, rect, _kSilverGradient, const [0, 1]);
      } else if (kMeetupOutfitColors[token] case final color?) {
        canvas.drawRect(rect, Paint()..color = color);
      } else {
        _paintHatch(canvas, rect);
      }
      canvas.restore();
      if (!_isKnownColorToken(token)) {
        canvas.drawRRect(
          rrect.deflate(0.5),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.8
            ..color = borderColor,
        );
      } else {
        canvas.drawRRect(
          rrect.deflate(0.4),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.8
            ..color = _kGarmentStroke,
        );
      }
      return;
    }

    _drawDashedRRect(
      canvas,
      rrect.deflate(0.6),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = borderColor,
      dash: 2.4,
      gap: 1.8,
    );
  }

  void _fillGradient(
    Canvas canvas,
    Rect rect,
    List<Color> colors,
    List<double> stops,
  ) {
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          rect.topLeft,
          rect.bottomRight,
          colors,
          stops,
        ),
    );
  }

  void _paintHatch(Canvas canvas, Rect rect) {
    canvas.drawRect(rect, Paint()..color = _kGarmentFallback);
    final line = Paint()
      ..color = _kHatchLine
      ..strokeWidth = 2;
    for (
      double x = rect.left - rect.height;
      x < rect.right + rect.height;
      x += 6
    ) {
      canvas.drawLine(
        Offset(x, rect.bottom),
        Offset(x + rect.height, rect.top),
        line,
      );
    }
  }

  @override
  bool shouldRepaint(_SwatchPainter oldDelegate) =>
      oldDelegate.token != token || oldDelegate.borderColor != borderColor;
}

/// Square stage with the soft spot tint used behind the figure on cards.
class MeetupOutfitFigureStage extends StatelessWidget {
  final MeetupOutfitSpec outfit;
  final MeetupOutfitGender gender;
  final double width;

  const MeetupOutfitFigureStage({
    super.key,
    required this.outfit,
    required this.gender,
    this.width = 112,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 8),
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -0.8),
          radius: 1.15,
          colors: dark
              ? const [Color(0x2EF472B6), Color(0xB82A1020), Color(0x590F172A)]
              : const [Color(0xFFFFFFFF), Color(0xFFFDF2F8), Color(0xFFFCE7F3)],
          stops: const [0, 0.6, 1],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: (dark ? Colors.pink.shade200 : Colors.pink.shade600)
              .withValues(alpha: dark ? 0.26 : 0.16),
        ),
      ),
      child: MeetupOutfitFigure(outfit: outfit, gender: gender),
    );
  }
}

class MeetupOutfitFigure extends StatelessWidget {
  final MeetupOutfitSpec outfit;
  final MeetupOutfitGender gender;

  const MeetupOutfitFigure({
    super.key,
    required this.outfit,
    this.gender = MeetupOutfitGender.neutral,
  });

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: AspectRatio(
        aspectRatio: 120 / 238,
        child: CustomPaint(
          painter: _MeetupOutfitFigurePainter(outfit: outfit, gender: gender),
        ),
      ),
    );
  }
}

class _Frame {
  final double sl;
  final double sr;
  final double wl;
  final double wr;
  final double hl;
  final double hr;

  const _Frame(this.sl, this.sr, this.wl, this.wr, this.hl, this.hr);
}

class _MeetupOutfitFigurePainter extends CustomPainter {
  final MeetupOutfitSpec outfit;
  final MeetupOutfitGender gender;

  const _MeetupOutfitFigurePainter({
    required this.outfit,
    required this.gender,
  });

  static const double _viewWidth = 120;
  static const double _viewHeight = 238;

  static const Color _skin = Color(0xFFE9C0A0);
  static const Color _hair = Color(0xFF3A2E2A);
  static const Color _faceLine = Color(0xFF46362C);

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width / _viewWidth, size.height / _viewHeight);
    canvas.save();
    canvas.translate((size.width - _viewWidth * scale) / 2, 0);
    canvas.scale(scale);
    _paintFigure(canvas);
    canvas.restore();
  }

  _Frame get _frame => switch (gender) {
    MeetupOutfitGender.female => const _Frame(39, 81, 49, 71, 43, 77),
    MeetupOutfitGender.male => const _Frame(37, 83, 46, 74, 44, 76),
    MeetupOutfitGender.neutral => const _Frame(38.5, 81.5, 47.5, 72.5, 44, 76),
  };

  void _paintFigure(Canvas canvas) {
    final g = _frame;
    final skin = Paint()..color = _skin;

    // Ground shadow.
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(60, 230), width: 62, height: 10),
      Paint()..color = const Color(0x1A0F172A),
    );

    // Arms, legs, torso and neck are painted first so garments cover the
    // seams — pants must sit on top of the torso, and the shirt on top of
    // both so no skin band shows at the waist.
    _drawRotated(
      canvas,
      7,
      Offset(g.sl - 8, 76),
      () => canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(g.sl - 14, 70, 12, 78),
          const Radius.circular(6),
        ),
        skin,
      ),
    );
    _drawRotated(
      canvas,
      -7,
      Offset(g.sr + 8, 76),
      () => canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(g.sr + 2, 70, 12, 78),
          const Radius.circular(6),
        ),
        skin,
      ),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(44, 146, 14, 68),
        const Radius.circular(6),
      ),
      skin,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(62, 146, 14, 68),
        const Radius.circular(6),
      ),
      skin,
    );
    canvas.drawPath(_torsoPath(g), skin);
    canvas.drawRect(const Rect.fromLTWH(54, 52, 12, 16), skin);

    _paintPants(canvas, g);
    _paintShoes(canvas);
    _paintTop(canvas, g);
    _paintHead(canvas);
  }

  void _paintPants(Canvas canvas, _Frame g) {
    if (!outfit.showsPants) return;
    final type = outfit.pants;
    final path = type == 'skirt'
        ? _skirtPath(g)
        : _pantsPath(g, type == 'shorts' ? 170 : 208);
    final known = type != null || outfit.pantsColor != null;
    if (!known) {
      _drawGhost(canvas, path);
      return;
    }
    _fillGarment(canvas, path, outfit.pantsColor);
    if (type != 'skirt') {
      canvas.drawPath(
        Path()
          ..moveTo(g.hl + 2, 140)
          ..quadraticBezierTo(60, 147, g.hr - 2, 140),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = const Color(0x240F172A),
      );
    }
  }

  void _paintShoes(Canvas canvas) {
    final type = switch (outfit.shoes) {
      'boots' => 'boots',
      'sandals' => 'sandals',
      _ => 'sneakers',
    };
    final known = outfit.shoes != null || outfit.shoesColor != null;
    final shoePaint = _garmentPaint(outfit.shoesColor);
    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = _kGarmentStroke;

    void fillPath(Path path) {
      if (known) {
        canvas.drawPath(path, shoePaint);
        canvas.drawPath(path, strokePaint);
      } else {
        _drawGhost(canvas, path);
      }
    }

    void fillRRect(RRect rrect) {
      final path = Path()..addRRect(rrect);
      fillPath(path);
    }

    switch (type) {
      case 'boots':
        fillPath(
          Path()
            ..moveTo(45, 184)
            ..lineTo(59, 184)
            ..lineTo(59, 215)
            ..lineTo(38, 215)
            ..quadraticBezierTo(34, 215, 34, 211)
            ..quadraticBezierTo(34, 208, 38, 207)
            ..lineTo(45, 200)
            ..close(),
        );
        fillPath(
          Path()
            ..moveTo(75, 184)
            ..lineTo(61, 184)
            ..lineTo(61, 215)
            ..lineTo(82, 215)
            ..quadraticBezierTo(86, 215, 86, 211)
            ..quadraticBezierTo(86, 208, 82, 207)
            ..lineTo(75, 200)
            ..close(),
        );
        fillRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(34, 215, 26, 4),
            const Radius.circular(1.6),
          ),
        );
        fillRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(61, 215, 26, 4),
            const Radius.circular(1.6),
          ),
        );
      case 'sandals':
        for (final rect in const [
          Rect.fromLTWH(44, 203, 14, 3.2),
          Rect.fromLTWH(41, 211, 19, 3.6),
          Rect.fromLTWH(62, 203, 14, 3.2),
          Rect.fromLTWH(60, 211, 19, 3.6),
        ]) {
          fillRRect(RRect.fromRectAndRadius(rect, const Radius.circular(1.7)));
        }
      default:
        fillPath(
          Path()
            ..moveTo(45, 204)
            ..lineTo(59, 204)
            ..lineTo(59, 214)
            ..lineTo(38, 214)
            ..quadraticBezierTo(34, 214, 34, 210)
            ..quadraticBezierTo(34, 207, 38, 206)
            ..lineTo(45, 205)
            ..close(),
        );
        fillPath(
          Path()
            ..moveTo(75, 204)
            ..lineTo(61, 204)
            ..lineTo(61, 214)
            ..lineTo(82, 214)
            ..quadraticBezierTo(86, 214, 86, 210)
            ..quadraticBezierTo(86, 207, 82, 206)
            ..lineTo(75, 205)
            ..close(),
        );
        if (known) {
          final sole = Paint()..color = const Color(0xFFF1F5F9);
          final soleStroke = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.8
            ..color = const Color(0x8C64748B);
          for (final rect in const [
            Rect.fromLTWH(34, 214, 26, 4),
            Rect.fromLTWH(61, 214, 26, 4),
          ]) {
            final rrect = RRect.fromRectAndRadius(
              rect,
              const Radius.circular(2),
            );
            canvas.drawRRect(rrect, sole);
            canvas.drawRRect(rrect, soleStroke);
          }
        }
    }
  }

  void _paintTop(Canvas canvas, _Frame g) {
    final sleeveLength =
        outfit.shirt == 'long_sleeve' || outfit.shirt == 'jacket' ? 60.0 : 30.0;

    if (outfit.isDress) {
      final dress = _dressPath(g);
      final paint = _garmentPaint(outfit.shirtColor);
      // Sleeves need the same fill, so they are drawn into a separate save
      // layer with the garment paint and then the dress path over them.
      for (final left in const [true, false]) {
        final x = left ? g.sl - 14 : g.sr - 1;
        final pivot = left ? g.sl - 7 : g.sr + 7;
        _drawRotated(
          canvas,
          left ? 6 : -6,
          Offset(pivot, 78),
          () => canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(x, 71, 15, sleeveLength),
              const Radius.circular(5),
            ),
            paint,
          ),
        );
      }
      _fillGarmentWithPaint(canvas, dress, paint, outfit.shirtColor);
      canvas.drawPath(
        Path()
          ..moveTo(g.wl + 3, 118)
          ..quadraticBezierTo(60, 125, g.wr - 3, 118),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = const Color(0x290F172A),
      );
      _paintCollar(canvas);
      return;
    }

    final known = outfit.shirt != null || outfit.shirtColor != null;
    if (!known) {
      for (final left in const [true, false]) {
        final x = left ? g.sl - 14 : g.sr - 1;
        final pivot = left ? g.sl - 7 : g.sr + 7;
        final rrect = RRect.fromRectAndRadius(
          Rect.fromLTWH(x, 71, 15, sleeveLength),
          const Radius.circular(5),
        );
        _drawRotated(
          canvas,
          left ? 6 : -6,
          Offset(pivot, 78),
          () => _drawGhost(canvas, Path()..addRRect(rrect)),
        );
      }
      _drawGhost(canvas, _shirtPath(g));
      return;
    }

    final paint = _garmentPaint(outfit.shirtColor);
    for (final left in const [true, false]) {
      final x = left ? g.sl - 14 : g.sr - 1;
      final pivot = left ? g.sl - 7 : g.sr + 7;
      _drawRotated(
        canvas,
        left ? 6 : -6,
        Offset(pivot, 78),
        () => canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, 71, 15, sleeveLength),
            const Radius.circular(5),
          ),
          paint,
        ),
      );
    }
    _fillGarmentWithPaint(canvas, _shirtPath(g), paint, outfit.shirtColor);

    if (outfit.shirt == 'jacket') {
      canvas.drawLine(
        const Offset(60, 76),
        const Offset(60, 138),
        Paint()
          ..strokeWidth = 1.4
          ..color = const Color(0x3D0F172A),
      );
      canvas.drawPath(
        Path()
          ..moveTo(50, 72)
          ..lineTo(60, 88)
          ..lineTo(70, 72),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round
          ..color = const Color(0x4D0F172A),
      );
    } else {
      _paintCollar(canvas);
    }
  }

  void _paintCollar(Canvas canvas) {
    canvas.drawPath(
      Path()
        ..moveTo(54, 67)
        ..quadraticBezierTo(60, 75, 66, 67),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..color = const Color(0x2E0F172A),
    );
  }

  void _paintHead(Canvas canvas) {
    final skin = Paint()..color = _skin;
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(60, 41), width: 34, height: 38),
      skin,
    );
    canvas.drawCircle(const Offset(43, 43), 3.2, skin);
    canvas.drawCircle(const Offset(77, 43), 3.2, skin);

    canvas.drawPath(
      gender == MeetupOutfitGender.female
          ? (Path()
              ..moveTo(42, 47)
              ..quadraticBezierTo(39, 15, 60, 14)
              ..quadraticBezierTo(81, 15, 78, 47)
              ..lineTo(78, 64)
              ..quadraticBezierTo(74, 43, 70, 36)
              ..quadraticBezierTo(60, 31, 50, 36)
              ..quadraticBezierTo(46, 43, 42, 64)
              ..close())
          : (Path()
              ..moveTo(43, 39)
              ..quadraticBezierTo(43, 18, 60, 17)
              ..quadraticBezierTo(77, 18, 77, 39)
              ..quadraticBezierTo(71, 29, 60, 28)
              ..quadraticBezierTo(49, 29, 43, 39)
              ..close()),
      Paint()..color = _hair,
    );

    final face = Paint()..color = _faceLine;
    canvas.drawCircle(const Offset(53.5, 43), 1.6, face);
    canvas.drawCircle(const Offset(66.5, 43), 1.6, face);
    canvas.drawPath(
      Path()
        ..moveTo(55, 50)
        ..quadraticBezierTo(60, 54, 65, 50),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..color = _faceLine,
    );
  }

  Paint _garmentPaint(String? color) {
    final token = color?.trim();
    final paint = Paint()..style = PaintingStyle.fill;
    if (token == null || token.isEmpty) {
      paint.color = _kGarmentFallback;
    } else if (token == 'multicolor') {
      paint.shader = ui.Gradient.linear(
        const Offset(30, 70),
        const Offset(90, 210),
        kMeetupMulticolorGradient,
        const [0, 0.25, 0.5, 0.75, 1],
      );
    } else if (token == 'gold') {
      paint.shader = ui.Gradient.linear(
        const Offset(30, 70),
        const Offset(90, 210),
        _kGoldGradient,
      );
    } else if (token == 'silver') {
      paint.shader = ui.Gradient.linear(
        const Offset(30, 70),
        const Offset(90, 210),
        _kSilverGradient,
      );
    } else if (kMeetupOutfitColors[token] case final color?) {
      paint.color = color;
    } else {
      // Legacy free text: draw the hatch as the fill and skip the plain path.
      paint.color = _kGarmentFallback;
    }
    return paint;
  }

  void _fillGarment(Canvas canvas, Path path, String? color) {
    final token = color?.trim();
    final paint = _garmentPaint(color);
    if (token != null && token.isNotEmpty && !_isKnownColorToken(token)) {
      canvas.save();
      canvas.clipPath(path);
      final bounds = path.getBounds();
      canvas.drawRect(bounds, Paint()..color = _kGarmentFallback);
      final line = Paint()
        ..color = _kHatchLine
        ..strokeWidth = 2;
      for (
        double x = bounds.left - bounds.height;
        x < bounds.right + bounds.height;
        x += 6
      ) {
        canvas.drawLine(
          Offset(x, bounds.bottom),
          Offset(x + bounds.height, bounds.top),
          line,
        );
      }
      canvas.restore();
    } else {
      canvas.drawPath(path, paint);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = _kGarmentStroke,
    );
  }

  void _fillGarmentWithPaint(
    Canvas canvas,
    Path path,
    Paint paint,
    String? color,
  ) {
    final token = color?.trim();
    if (token != null && token.isNotEmpty && !_isKnownColorToken(token)) {
      _fillGarment(canvas, path, color);
      return;
    }
    canvas.drawPath(path, paint);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = _kGarmentStroke,
    );
  }

  void _drawGhost(Canvas canvas, Path path) {
    canvas.drawPath(path, Paint()..color = _kGhostFill);
    _drawDashedPath(
      canvas,
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.15
        ..color = _kGhostStroke,
      dash: 4,
      gap: 3,
    );
  }

  void _drawRotated(
    Canvas canvas,
    double degrees,
    Offset pivot,
    VoidCallback draw,
  ) {
    canvas.save();
    canvas.translate(pivot.dx, pivot.dy);
    canvas.rotate(degrees * math.pi / 180);
    canvas.translate(-pivot.dx, -pivot.dy);
    draw();
    canvas.restore();
  }

  Path _torsoPath(_Frame g) => Path()
    ..moveTo(g.sl, 72)
    ..quadraticBezierTo(60, 64, g.sr, 72)
    ..lineTo(g.wr, 122)
    ..quadraticBezierTo(g.wr + 1, 130, g.hr, 144)
    ..lineTo(g.hr, 152)
    ..quadraticBezierTo(60, 160, g.hl, 152)
    ..lineTo(g.hl, 144)
    ..quadraticBezierTo(g.wl - 1, 130, g.wl, 122)
    ..close();

  Path _shirtPath(_Frame g) => Path()
    ..moveTo(g.sl - 1, 74)
    ..quadraticBezierTo(60, 66, g.sr + 1, 74)
    ..quadraticBezierTo(g.wr + 3, 106, g.hr - 1, 140)
    ..quadraticBezierTo(60, 148, g.hl + 1, 140)
    ..quadraticBezierTo(g.wl - 3, 106, g.sl - 1, 74)
    ..close();

  Path _dressPath(_Frame g) => Path()
    ..moveTo(g.sl - 1, 74)
    ..quadraticBezierTo(60, 66, g.sr + 1, 74)
    ..quadraticBezierTo(g.wr + 3, 102, g.wr, 120)
    ..lineTo(g.hr + 11, 184)
    ..quadraticBezierTo(60, 194, g.hl - 11, 184)
    ..lineTo(g.wl, 120)
    ..quadraticBezierTo(g.wl - 3, 102, g.sl - 1, 74)
    ..close();

  Path _pantsPath(_Frame g, double hem) => Path()
    ..moveTo(g.hl + 1, 138)
    ..quadraticBezierTo(60, 146, g.hr - 1, 138)
    ..lineTo(g.hr + 1, hem)
    ..quadraticBezierTo(g.hr + 1, hem + 6, g.hr - 5, hem + 6)
    ..lineTo(64, hem + 6)
    ..lineTo(64, 158)
    ..lineTo(56, 158)
    ..lineTo(56, hem + 6)
    ..lineTo(g.hl + 5, hem + 6)
    ..quadraticBezierTo(g.hl - 1, hem + 6, g.hl - 1, hem)
    ..close();

  Path _skirtPath(_Frame g) => Path()
    ..moveTo(g.hl + 1, 138)
    ..quadraticBezierTo(60, 146, g.hr - 1, 138)
    ..lineTo(g.hr + 13, 182)
    ..quadraticBezierTo(60, 192, g.hl - 13, 182)
    ..close();

  @override
  bool shouldRepaint(_MeetupOutfitFigurePainter oldDelegate) =>
      oldDelegate.outfit != outfit || oldDelegate.gender != gender;
}

void _drawDashedPath(
  Canvas canvas,
  Path path,
  Paint paint, {
  required double dash,
  required double gap,
}) {
  for (final metric in path.computeMetrics()) {
    double distance = 0;
    while (distance < metric.length) {
      final next = math.min(distance + dash, metric.length);
      canvas.drawPath(metric.extractPath(distance, next), paint);
      distance = next + gap;
    }
  }
}

void _drawDashedRRect(
  Canvas canvas,
  RRect rrect,
  Paint paint, {
  required double dash,
  required double gap,
}) {
  _drawDashedPath(canvas, Path()..addRRect(rrect), paint, dash: dash, gap: gap);
}
