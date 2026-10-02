import 'dart:async';

import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';

class BirthdayOverlay extends StatefulWidget {
  final bool? isBirthdayToday;
  const BirthdayOverlay({super.key, this.isBirthdayToday = false});

  bool get isBirthdayActive => isBirthdayToday ?? false;

  @override
  State<BirthdayOverlay> createState() => _BirthdayOverlayState();
}

class _BirthdayOverlayState extends State<BirthdayOverlay>
    with WidgetsBindingObserver {
  late final ConfettiController _confettiController;
  Timer? _celebrationTimer;

  static const _colors = [
    Color(0xFFFF6B6B),
    Color(0xFFFFD93D),
    Color(0xFF6BCB77),
    Color(0xFF4D96FF),
    Color(0xFFFF8CE7),
    Color(0xFFA66CFF),
    Color(0xFFFF9F43),
    Color(0xFF00D2D3),
  ];

  @override
  void initState() {
    super.initState();
    _confettiController = ConfettiController(
      duration: const Duration(seconds: 30),
    );
    WidgetsBinding.instance.addObserver(this);
    if (widget.isBirthdayActive) {
      _playConfetti();
    }
  }

  @override
  void didUpdateWidget(BirthdayOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isBirthdayActive &&
        _confettiController.state == ConfettiControllerState.stopped) {
      _playConfetti();
    } else if (!widget.isBirthdayActive) {
      _stopConfetti();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.isBirthdayActive) {
      _playConfetti();
    }
  }

  void _playConfetti() {
    _celebrationTimer?.cancel();
    _confettiController.stop();
    _confettiController.play();
    _celebrationTimer = Timer(const Duration(seconds: 30), () {
      _confettiController.stop();
    });
  }

  void _stopConfetti() {
    _celebrationTimer?.cancel();
    _confettiController.stop();
  }

  @override
  void dispose() {
    _celebrationTimer?.cancel();
    _confettiController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ClipRect(
        child: ConfettiWidget(
          confettiController: _confettiController,
          blastDirectionality: BlastDirectionality.explosive,
          numberOfParticles: 40,
          maxBlastForce: 80,
          gravity: 0.04,
          colors: _colors,
          strokeColor: Colors.transparent,
          strokeWidth: 0,
          minimumSize: const Size(4, 4),
          maximumSize: const Size(10, 10),
        ),
      ),
    );
  }
}
