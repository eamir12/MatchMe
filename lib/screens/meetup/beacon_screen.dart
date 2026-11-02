import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/meetup_provider.dart';
import 'package:matchme/utils/localized_duration.dart';

/// Deterministic beacon identity: both devices derive the same shape and
/// colour from the session id, so no extra payload or media is needed.
int meetupBeaconSeed(String sessionId) {
  var hash = 0x811c9dc5;
  for (final unit in sessionId.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

const List<Color> _beaconColors = [
  Color(0xFFFF5252),
  Color(0xFF40C4FF),
  Color(0xFFFFD740),
  Color(0xFF69F0AE),
  Color(0xFFFF4081),
  Color(0xFFB388FF),
];

Color meetupBeaconColor(String sessionId) {
  final hash = meetupBeaconSeed(sessionId);
  return _beaconColors[(hash >> 8) % _beaconColors.length];
}

int _beaconShapeIndex(String sessionId) => meetupBeaconSeed(sessionId) % 5;

class MeetupBeaconShape extends StatefulWidget {
  final String sessionId;
  final double size;
  final bool animate;

  const MeetupBeaconShape({
    super.key,
    required this.sessionId,
    this.size = 240,
    this.animate = true,
  });

  @override
  State<MeetupBeaconShape> createState() => _MeetupBeaconShapeState();
}

class _MeetupBeaconShapeState extends State<MeetupBeaconShape>
    with SingleTickerProviderStateMixin {
  AnimationController? _pulse;

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _pulse = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1400),
        lowerBound: 0.94,
        upperBound: 1.06,
      )..repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant MeetupBeaconShape oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate && _pulse == null) {
      _pulse = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1400),
        lowerBound: 0.94,
        upperBound: 1.06,
      )..repeat(reverse: true);
    } else if (!widget.animate && _pulse != null) {
      _pulse!.dispose();
      _pulse = null;
    }
  }

  @override
  void dispose() {
    _pulse?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shape = SizedBox(
      width: widget.size,
      height: widget.size,
      child: CustomPaint(
        painter: _BeaconPainter(
          color: meetupBeaconColor(widget.sessionId),
          shapeIndex: _beaconShapeIndex(widget.sessionId),
        ),
      ),
    );
    final controller = _pulse;
    if (controller == null) return shape;
    return ScaleTransition(scale: controller, child: shape);
  }
}

class _BeaconPainter extends CustomPainter {
  final Color color;
  final int shapeIndex;

  const _BeaconPainter({required this.color, required this.shapeIndex});

  Path _path(Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 * 0.92;
    final path = Path();

    switch (shapeIndex) {
      case 0: // Circle
        path.addOval(Rect.fromCircle(center: center, radius: radius));
        break;
      case 1: // Triangle
        for (var i = 0; i < 3; i++) {
          final angle = -math.pi / 2 + i * 2 * math.pi / 3;
          final point = Offset(
            center.dx + radius * math.cos(angle),
            center.dy + radius * math.sin(angle),
          );
          if (i == 0) {
            path.moveTo(point.dx, point.dy);
          } else {
            path.lineTo(point.dx, point.dy);
          }
        }
        path.close();
        break;
      case 2: // Diamond
        path
          ..moveTo(center.dx, center.dy - radius)
          ..lineTo(center.dx + radius, center.dy)
          ..lineTo(center.dx, center.dy + radius)
          ..lineTo(center.dx - radius, center.dy)
          ..close();
        break;
      case 3: // Hexagon
        for (var i = 0; i < 6; i++) {
          final angle = -math.pi / 2 + i * math.pi / 3;
          final point = Offset(
            center.dx + radius * math.cos(angle),
            center.dy + radius * math.sin(angle),
          );
          if (i == 0) {
            path.moveTo(point.dx, point.dy);
          } else {
            path.lineTo(point.dx, point.dy);
          }
        }
        path.close();
        break;
      default: // Rounded square
        path.addRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: center,
              width: radius * 1.7,
              height: radius * 1.7,
            ),
            Radius.circular(radius * 0.22),
          ),
        );
    }
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = _path(size);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(6, size.shortestSide * 0.035),
    );
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _BeaconPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.shapeIndex != shapeIndex;
}

/// Full-screen beacon. The sender holds up the phone; the receiver looks for
/// this exact shape and colour at the meeting point.
class MeetupBeaconScreen extends ConsumerStatefulWidget {
  final String matchId;
  final String otherUserName;
  final bool mine;

  const MeetupBeaconScreen({
    super.key,
    required this.matchId,
    required this.otherUserName,
    required this.mine,
  });

  @override
  ConsumerState<MeetupBeaconScreen> createState() => _MeetupBeaconScreenState();
}

class _MeetupBeaconScreenState extends ConsumerState<MeetupBeaconScreen> {
  Timer? _ticker;
  bool _hiding = false;
  bool _expiryNavigationScheduled = false;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final state = ref.read(meetupProvider(widget.matchId));
      final signal = widget.mine ? state.myBeacon : state.incomingBeacon;
      if (widget.mine &&
          !state.loading &&
          (signal == null || signal.timeRemaining <= Duration.zero)) {
        _returnToHubAfterExpiry();
        return;
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _hideAndClose() async {
    if (_hiding) return;
    _hiding = true;
    if (widget.mine) {
      await ref.read(meetupProvider(widget.matchId).notifier).hideBeacon();
    }
    if (mounted) Navigator.of(context).pop();
  }

  void _returnToHubAfterExpiry() {
    if (_expiryNavigationScheduled) return;
    _expiryNavigationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final state = ref.watch(meetupProvider(widget.matchId));
    final signal = widget.mine ? state.myBeacon : state.incomingBeacon;
    final sessionId = state.session?.id ?? widget.matchId;
    final remaining = signal?.timeRemaining ?? Duration.zero;
    final active = signal != null && remaining > Duration.zero;
    if (widget.mine &&
        !state.loading &&
        !active &&
        !_expiryNavigationScheduled) {
      _returnToHubAfterExpiry();
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                widget.mine
                    ? l10n.getString('meetupBeaconActiveTitle')
                    : l10n.getString(
                        'meetupBeaconIncomingTitle',
                        params: {'name': widget.otherUserName},
                      ),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: active
                    ? MeetupBeaconShape(sessionId: sessionId, size: 280)
                    : Icon(
                        Icons.highlight_off,
                        size: 96,
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Text(
                active
                    ? (widget.mine
                          ? l10n.getString(
                              'meetupBeaconActiveBody',
                              params: {'name': widget.otherUserName},
                            )
                          : l10n.getString('meetupBeaconIncomingBody'))
                    : l10n.getString('meetupBeaconExpired'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 16,
                  height: 1.35,
                ),
              ),
            ),
            if (active)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  l10n.getString(
                    'meetupBeaconEndsIn',
                    params: {
                      'duration': formatDurationParts(
                        l10n.getString,
                        minutes: remaining.inMinutes > 0
                            ? remaining.inMinutes
                            : null,
                        seconds: remaining.inSeconds % 60 > 0
                            ? remaining.inSeconds % 60
                            : null,
                      ),
                    },
                  ),
                  style: const TextStyle(color: Colors.white54, fontSize: 14),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: _hideAndClose,
                  child: Text(
                    widget.mine
                        ? l10n.getString('meetupBeaconHide')
                        : l10n.getString('meetupClose'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
