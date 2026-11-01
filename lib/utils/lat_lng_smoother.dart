import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

class LatLngSmoother {
  LatLngSmoother({
    required TickerProvider vsync,
    required ValueChanged<LatLng> onChanged,
    Duration duration = const Duration(milliseconds: 900),
    Curve curve = Curves.easeOutCubic,
    double snapDistanceMeters = 2000,
  }) : _onChanged = onChanged,
       _curve = curve,
       _snapDistanceMeters = snapDistanceMeters,
       _controller = AnimationController(vsync: vsync, duration: duration) {
    _controller.addListener(_handleTick);
  }

  final ValueChanged<LatLng> _onChanged;
  final Curve _curve;
  final double _snapDistanceMeters;
  final AnimationController _controller;
  final Distance _distance = const Distance();

  LatLng? _current;
  LatLng? _from;
  LatLng? _target;

  LatLng? get current => _current;

  void update(LatLng target, {bool immediate = false}) {
    final current = _current;
    if (current == null) {
      _snapTo(target);
      return;
    }

    final distance = _distance.as(LengthUnit.Meter, current, target);
    if (immediate || distance > _snapDistanceMeters) {
      _snapTo(target);
      return;
    }

    if (distance < 0.25) {
      _snapTo(target);
      return;
    }

    _from = current;
    _target = target;
    _controller.forward(from: 0);
  }

  void _snapTo(LatLng target) {
    _controller.stop();
    _current = target;
    _from = target;
    _target = target;
    _onChanged(target);
  }

  void _handleTick() {
    final from = _from;
    final target = _target;
    if (from == null || target == null) return;

    final t = _curve.transform(_controller.value);
    var longitudeDelta = target.longitude - from.longitude;
    if (longitudeDelta > 180) {
      longitudeDelta -= 360;
    } else if (longitudeDelta < -180) {
      longitudeDelta += 360;
    }
    var longitude = from.longitude + longitudeDelta * t;
    if (longitude > 180) {
      longitude -= 360;
    } else if (longitude < -180) {
      longitude += 360;
    }
    final next = LatLng(
      from.latitude + (target.latitude - from.latitude) * t,
      longitude,
    );
    _current = next;
    _onChanged(next);
  }

  void dispose() {
    _controller
      ..removeListener(_handleTick)
      ..dispose();
  }
}
