// Swipe-to-clear gesture for the app's top-of-screen banners. The card tracks
// the finger sideways or upward; a past-threshold drag or a fling settles it
// off-screen and then reports the dismissal, and anything shorter springs
// back. Downward drags are damped so a pull never tears the banner out of the
// status-bar slot.

import 'package:flutter/material.dart';

class SwipeToDismiss extends StatefulWidget {
  const SwipeToDismiss({
    super.key,
    required this.child,
    required this.onDismissed,
  });

  final Widget child;
  final VoidCallback onDismissed;

  @override
  State<SwipeToDismiss> createState() => _SwipeToDismissState();
}

class _SwipeToDismissState extends State<SwipeToDismiss>
    with SingleTickerProviderStateMixin {
  static const Duration _settleDuration = Duration(milliseconds: 180);
  static const double _horizontalThresholdFraction = 0.3;
  static const double _flingVelocity = 700;
  static const double _upwardThreshold = 24;
  static const double _downwardResistance = 0.2;

  late final AnimationController _settle;
  Offset _drag = Offset.zero;
  Offset _settleFrom = Offset.zero;
  Offset _settleTo = Offset.zero;
  bool _settling = false;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _settle = AnimationController(vsync: this, duration: _settleDuration);
  }

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  Offset get _offset {
    if (!_settling) {
      return Offset(
        _drag.dx,
        _drag.dy <= 0 ? _drag.dy : _drag.dy * _downwardResistance,
      );
    }
    final progress = Curves.easeOutCubic.transform(_settle.value);
    return Offset.lerp(_settleFrom, _settleTo, progress)!;
  }

  void _handleStart(DragStartDetails details) {
    if (_dismissing || !_settling) return;
    // Catch the card mid-spring-back and keep it under the finger.
    _settle.stop();
    setState(() {
      _drag = _offset;
      _settling = false;
    });
  }

  void _handleUpdate(DragUpdateDetails details) {
    if (_dismissing) return;
    setState(() {
      _settling = false;
      _drag += details.delta;
    });
  }

  void _handleEnd(DragEndDetails details) {
    if (_dismissing) return;
    final size = context.size;
    if (size == null) return;

    final offset = _offset;
    final velocity = details.velocity.pixelsPerSecond;
    final sideways =
        offset.dx.abs() > size.width * _horizontalThresholdFraction ||
        (offset.dx.abs() > 12 && velocity.dx.abs() > _flingVelocity);
    final upward =
        offset.dy < -_upwardThreshold ||
        (offset.dy < 0 && velocity.dy < -_flingVelocity);

    if (sideways && (!upward || offset.dx.abs() >= offset.dy.abs())) {
      final direction = offset.dx < 0 ? -1.0 : 1.0;
      final screenWidth = MediaQuery.sizeOf(context).width;
      _settleOut(Offset(direction * (screenWidth + size.width), offset.dy));
      return;
    }
    if (upward) {
      final top =
          (context.findRenderObject() as RenderBox?)
              ?.localToGlobal(Offset.zero)
              .dy ??
          0;
      _settleOut(Offset(offset.dx, -(top + size.height + 24)));
      return;
    }
    _springBack();
  }

  void _handleCancel() {
    if (_dismissing) return;
    if (!_settling && _drag == Offset.zero) return;
    _springBack();
  }

  void _settleOut(Offset target) {
    _dismissing = true;
    _animateTo(target, onDone: widget.onDismissed);
  }

  void _springBack() {
    _animateTo(
      Offset.zero,
      onDone: () {
        setState(() {
          _drag = Offset.zero;
          _settling = false;
        });
      },
    );
  }

  void _animateTo(Offset target, {required VoidCallback onDone}) {
    _settleFrom = _offset;
    _settleTo = target;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _settle.duration = reduceMotion ? Duration.zero : _settleDuration;
    setState(() => _settling = true);
    _settle.forward(from: 0).whenComplete(() {
      if (!mounted) return;
      onDone();
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: _handleStart,
      onPanUpdate: _handleUpdate,
      onPanEnd: _handleEnd,
      onPanCancel: _handleCancel,
      child: AnimatedBuilder(
        animation: _settle,
        child: widget.child,
        builder: (context, child) => Transform.translate(
          offset: _offset,
          child: AbsorbPointer(absorbing: _dismissing, child: child),
        ),
      ),
    );
  }
}
