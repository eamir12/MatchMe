import 'package:flutter/material.dart';

class AppSkeletonBox extends StatefulWidget {
  final double? width;
  final double height;
  final double borderRadius;

  const AppSkeletonBox({
    super.key,
    this.width,
    required this.height,
    this.borderRadius = 12,
  });

  @override
  State<AppSkeletonBox> createState() => _AppSkeletonBoxState();
}

class _AppSkeletonBoxState extends State<AppSkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _reduceMotion = false;
  bool _motionInitialized = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (_motionInitialized && _reduceMotion == reduceMotion) return;
    _motionInitialized = true;
    _reduceMotion = reduceMotion;
    if (reduceMotion) {
      _controller.stop();
      _controller.value = 0;
    } else {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final baseColor = colorScheme.surfaceContainerHighest;
    final highlightColor = colorScheme.surfaceContainerLow;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final value = _reduceMotion ? 0.0 : _controller.value;
        return ExcludeSemantics(
          child: Container(
            width: widget.width,
            height: widget.height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              gradient: LinearGradient(
                begin: Alignment(-1.5 + (value * 3), 0),
                end: Alignment(-0.5 + (value * 3), 0),
                colors: [baseColor, highlightColor, baseColor],
              ),
            ),
          ),
        );
      },
    );
  }
}

class AppSkeletonList extends StatelessWidget {
  final int itemCount;
  final double itemHeight;
  final EdgeInsetsGeometry padding;
  final String? semanticLabel;

  const AppSkeletonList({
    super.key,
    this.itemCount = 3,
    this.itemHeight = 88,
    this.padding = const EdgeInsets.all(16),
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final list = ListView.separated(
      padding: padding,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: itemCount,
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, index) => AppSkeletonBox(
        height: itemHeight,
        width: double.infinity,
        borderRadius: 16,
      ),
    );
    if (semanticLabel == null) return list;
    return Semantics(
      container: true,
      liveRegion: true,
      label: semanticLabel,
      child: list,
    );
  }
}
