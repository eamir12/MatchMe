import 'package:flutter/material.dart';

/// Subtle chat background inspired by WhatsApp: a neutral base color with a
/// faint dotted grid overlay. Implemented with [CustomPainter] so no image
/// assets are required (avoids copyright issues).
class ChatBackground extends StatelessWidget {
  const ChatBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return CustomPaint(
      painter: _ChatBackgroundPainter(isDark: isDark),
      child: child,
    );
  }
}

class _ChatBackgroundPainter extends CustomPainter {
  _ChatBackgroundPainter({required this.isDark});

  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    // Draw base color (slightly darker in light mode so white bubbles stand out more)
    final basePaint = Paint()
      ..style = PaintingStyle.fill
      ..color = isDark ? const Color(0xFF111111) : const Color(0xFFE0E6E5);

    canvas.drawRect(Offset.zero & size, basePaint);

    // Draw a slightly more visible dotted/tiled pattern over the base for clearer texture
    final dotPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = isDark ? Colors.white.withValues(alpha: 0.03) : Colors.black.withValues(alpha: 0.045);

    const double step = 40.0;
    const double radius = 1.6;

    for (double y = 0; y < size.height + step; y += step) {
      final double xOffset = ((y / step) % 2 == 0) ? 0.0 : step / 2;
      for (double x = -xOffset; x < size.width + step; x += step) {
        canvas.drawCircle(Offset(x + xOffset, y), radius, dotPaint);
      }
    }

    // Optional faint diagonal strokes for extra texture (very subtle)
    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.3
      ..color = isDark ? Colors.white.withValues(alpha: 0.01) : Colors.black.withValues(alpha: 0.01);

    const double diagGap = 120.0;
    for (double start = -size.height; start < size.width; start += diagGap) {
      final p1 = Offset(start, 0);
      final p2 = Offset(start + size.height, size.height);
      canvas.drawLine(p1, p2, linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ChatBackgroundPainter oldDelegate) => oldDelegate.isDark != isDark;
}
