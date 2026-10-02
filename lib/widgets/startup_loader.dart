import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';

/// Translation key for the line shown under the logo on the startup loader.
const String kStartupTaglineKey = 'appTagline';

/// Reads [kStartupTaglineKey] from the loaded translations when a
/// [ProviderScope] is available, and from the built-in English fallback
/// otherwise. The first splash renders before the app's provider scope is
/// mounted, so the container lookup is expected to fail there.
String resolveStartupTagline(BuildContext context) {
  try {
    return ProviderScope.containerOf(
      context,
    ).read(localizationProvider).getString(kStartupTaglineKey);
  } catch (_) {
    return LocalizationState.defaultTranslation(kStartupTaglineKey);
  }
}

/// The same English fallback used when no provider scope is mounted yet.
String get defaultStartupTagline =>
    LocalizationState.defaultTranslation(kStartupTaglineKey);

class StartupLoaderScaffold extends StatelessWidget {
  const StartupLoaderScaffold({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: const SafeArea(child: _StartupLoaderBody()),
    );
  }
}

class _StartupLoaderBody extends StatefulWidget {
  const _StartupLoaderBody();

  @override
  State<_StartupLoaderBody> createState() => _StartupLoaderBodyState();
}

class _StartupLoaderBodyState extends State<_StartupLoaderBody>
    with SingleTickerProviderStateMixin {
  static const double _nativeLaunchWidth = 96.0;
  static const double _nativeLaunchHeight = 106.0;

  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _shadowAnimation;
  bool _reduceMotion = false;

  // Resolved in [didChangeDependencies] rather than [build]: the pulse animation
  // rebuilds every frame, and the provider lookup has to pay for a thrown error
  // while the pre-scope splash is up.
  String _tagline = defaultStartupTagline;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();

    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween<double>(1.0), weight: 20),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.0,
          end: 1.08,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 12,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.08,
          end: 0.98,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 8,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.98,
          end: 1.12,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 14,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.12,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 18,
      ),
      TweenSequenceItem(tween: ConstantTween<double>(1.0), weight: 28),
    ]).animate(_controller);

    _shadowAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween<double>(16.0), weight: 20),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 16.0,
          end: 24.0,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 12,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 24.0,
          end: 14.0,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 8,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 14.0,
          end: 28.0,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 14,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 28.0,
          end: 16.0,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 18,
      ),
      TweenSequenceItem(tween: ConstantTween<double>(16.0), weight: 28),
    ]).animate(_controller);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tagline = resolveStartupTagline(context);
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (_reduceMotion == reduceMotion) return;
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
    final theme = Theme.of(context);

    return Center(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final shortestSide = constraints.maxWidth < constraints.maxHeight
              ? constraints.maxWidth
              : constraints.maxHeight;
          final width = shortestSide < 360
              ? shortestSide * 0.27
              : _nativeLaunchWidth;
          final height = width * (_nativeLaunchHeight / _nativeLaunchWidth);
          final taglineFontSize = (width * 0.135).clamp(11.0, 15.0);

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedBuilder(
                animation: _controller,
                child: RepaintBoundary(
                  child: SizedBox(
                    width: width,
                    height: height,
                    child: Image.asset(
                      'assets/images/logo.png',
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
                builder: (context, child) {
                  return Transform.scale(
                    scale: _scaleAnimation.value,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.08),
                            blurRadius: _shadowAnimation.value,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: child,
                    ),
                  );
                },
              ),
              SizedBox(height: width * 0.16),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: shortestSide * 0.78),
                child: Text(
                  _tagline,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: taglineFontSize,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                    height: 1.25,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
