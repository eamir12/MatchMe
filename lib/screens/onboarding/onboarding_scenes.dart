// Interactive onboarding tour — replica demo scenes.
//
// Each scene is a compact, self-contained mock of a real MatchMe screen,
// rendered inside a phone frame (see onboarding_intro_screen.dart). Scenes
// are deliberately static replicas — no providers, no navigation, no data
// fetching — but they reuse the REAL translation keys (navHome, tierGold,
// settingsMatching…) so the mockups show the user's actual UI language, and
// they follow the app's Material 3 theme so light/dark both look native.
//
// Focus system: a chapter beat names a region id; every region is wrapped in
// [HighlightableRegion]. The active region gets a pulsing spotlight ring,
// other regions dim to draw the eye. Regions marked dimWhenInactive:false
// (used when one region is nested inside another) stay lit and rely on the
// nested ring alone.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:matchme/screens/onboarding/onboarding_content.dart';
import 'package:matchme/services/voice_guidance_service.dart';
import 'package:matchme/utils/country_localized_names.dart';
import 'package:matchme/utils/directional_icons.dart';

/// Builds the replica for a chapter scene.
Widget buildOnboardingReplica(OnboardingScene scene, OnboardingSceneData data) {
  switch (scene) {
    case OnboardingScene.welcome:
      return WelcomeReplica(data: data);
    case OnboardingScene.home:
      return HomeReplica(data: data);
    case OnboardingScene.nearby:
      return NearbyReplica(data: data);
    case OnboardingScene.worldMap:
      return WorldMapReplica(data: data);
    case OnboardingScene.matches:
      return MatchesReplica(data: data);
    case OnboardingScene.chats:
      return ChatsReplica(data: data);
    case OnboardingScene.events:
      return EventsReplica(data: data);
    case OnboardingScene.profile:
      return ProfileReplica(data: data);
    case OnboardingScene.settings:
      return SettingsReplica(data: data);
    case OnboardingScene.finish:
      return FinishReplica(data: data);
  }
}

// ---------------------------------------------------------------------------
// Shared chrome
// ---------------------------------------------------------------------------

/// Status-bar strip at the top of the phone frame, purely decorative.
class _DemoStatusBar extends StatelessWidget {
  const _DemoStatusBar();

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
      child: Row(
        children: [
          Text(
            '9:41',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w600,
              color: onSurface.withValues(alpha: 0.7),
            ),
          ),
          const Spacer(),
          Icon(Icons.wifi, size: 10, color: onSurface.withValues(alpha: 0.6)),
          const SizedBox(width: 3),
          Icon(
            Icons.signal_cellular_4_bar,
            size: 10,
            color: onSurface.withValues(alpha: 0.6),
          ),
          const SizedBox(width: 3),
          Icon(
            Icons.battery_full,
            size: 11,
            color: onSurface.withValues(alpha: 0.6),
          ),
        ],
      ),
    );
  }
}

/// Mock app bar. The gear can itself be a highlight region (settings chapter).
/// Mirrors the real main-navigation bar: a title row plus (on tab screens) the
/// online/visible status strip with the switch users flip to go invisible.
class _DemoMiniAppBar extends StatelessWidget {
  const _DemoMiniAppBar({
    required this.data,
    required this.title,
    this.gearRegionId,
    this.showBack = false,
    this.showStatusStrip = true,
    this.subtitle,
  });

  final OnboardingSceneData data;
  final String title;
  final String? gearRegionId;
  final bool showBack;

  /// Matches the real navigation hub: pushed screens (map, settings) have no
  /// visibility strip, tab screens do.
  final bool showStatusStrip;

  /// Optional row rendered under the title (e.g. the nearby radius control).
  final Widget? subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final onSurface = colors.onSurface;
    // logout_rounded has no matchTextDirection, so it still needs a manual
    // flip; arrow_back below does not (it auto-mirrors).
    final rtl = Directionality.of(context) == TextDirection.rtl;

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 3),
      child: Column(
        children: [
          Row(
            children: [
              if (showBack)
                // arrow_back auto-mirrors in RTL (matchTextDirection), so it
                // points right in Hebrew without manual branching.
                Icon(
                  Icons.arrow_back,
                  size: 15,
                  color: onSurface.withValues(alpha: 0.7),
                ),
              if (showBack) const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.visible,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: onSurface,
                  ),
                ),
              ),
              HighlightableRegion(
                id: gearRegionId ?? 'gear',
                activeId: data.highlight,
                // Standalone spotlight target (settings chapter) vs chrome.
                dimWhenInactive: gearRegionId != null,
                radius: BorderRadius.circular(8),
                child: _gearIcon(context),
              ),
              const SizedBox(width: 8),
              Transform.flip(
                flipX: rtl,
                child: Icon(
                  Icons.logout_rounded,
                  size: 14,
                  color: colors.error.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
          if (subtitle != null) ...[const SizedBox(height: 5), subtitle!],
          if (showStatusStrip) ...[
            const SizedBox(height: 4),
            HighlightableRegion(
              id: 'status',
              activeId: data.highlight,
              dimWhenInactive: false,
              radius: BorderRadius.circular(999),
              child: _DemoStatusStrip(data: data),
            ),
          ],
        ],
      ),
    );
  }

  Widget _gearIcon(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        Icons.settings_outlined,
        size: 14,
        color: colors.onSurface.withValues(alpha: 0.7),
      ),
    );
  }
}

/// Compact copy of the real main-nav visibility pill: green "online & visible"
/// label with the switch that makes you invisible. The explanation always
/// shows in full (never ellipsized) and the switch is live: flip it to go
/// invisible and back, exactly as in the real app.
class _DemoStatusStrip extends StatefulWidget {
  const _DemoStatusStrip({required this.data});

  final OnboardingSceneData data;

  @override
  State<_DemoStatusStrip> createState() => _DemoStatusStripState();
}

class _DemoStatusStripState extends State<_DemoStatusStrip> {
  bool _online = true;

  /// Guards the scripted demo against manual taps and disposals.
  int _demoGeneration = 0;
  bool _demoPlayedForStatus = false;

  OnboardingSceneData get data => widget.data;

  /// Fraction of the Home1 narration at which the offline clause is spoken
  /// ("it takes you offline and invisible") and at which the closing online
  /// clause lands ("brings you back online"). The flips track these fractions
  /// of the spoken (or, when muted, reading-paced) utterance instead of fixed
  /// wall-clock delays, so the switch and the words stay in sync.
  static const double _offlineAt = 0.60;
  static const double _onlineAt = 0.90;

  /// How long to wait for the narration to start before falling back to
  /// subtitle-paced timing (muted / no TTS engine).
  static const Duration _utteranceWaitCap = Duration(milliseconds: 2500);

  @override
  void initState() {
    super.initState();
    VoiceGuidanceService.instance.spokenText.addListener(_onSpokenText);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoDemo());
  }

  @override
  void dispose() {
    _demoGeneration++;
    VoiceGuidanceService.instance.spokenText.removeListener(_onSpokenText);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _DemoStatusStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data.highlight != widget.data.highlight) {
      if (widget.data.highlight != 'status') _demoPlayedForStatus = false;
      _maybeAutoDemo();
    }
  }

  /// A replayed Home1 narration re-runs the demo with it.
  void _onSpokenText() {
    if (!mounted || widget.data.highlight != 'status') return;
    if (VoiceGuidanceService.instance.spokenText.value ==
        data.text('onboardingBeatHome1')) {
      _demoPlayedForStatus = false;
      _maybeAutoDemo();
    }
  }

  /// The tour demonstrates the toggle by itself while the narration
  /// explains its significance: online → invisible → online again. Runs
  /// once per spotlight activation; a manual tap cancels the script.
  void _maybeAutoDemo() {
    if (widget.data.highlight != 'status' || _demoPlayedForStatus) return;
    _demoPlayedForStatus = true;
    final generation = ++_demoGeneration;
    final service = VoiceGuidanceService.instance;
    final beatText = data.text('onboardingBeatHome1');
    final estimate = estimateSpokenDuration(beatText);
    final offlineAfter = Duration(
      milliseconds: (estimate.inMilliseconds * _offlineAt).round(),
    );
    final onlineAfter = Duration(
      milliseconds: (estimate.inMilliseconds * _onlineAt).round(),
    );
    unawaited(
      Future<void>(() async {
        // Anchor to the live utterance when audible: poll in fixed 100ms
        // steps (fake-clock safe — never wall-clock) up to the cap, counting
        // the consumed time so the flips below stay on the narration clock.
        // With no utterance (muted / no TTS engine) the same fractions pace
        // the subtitle a reader follows at roughly the same rate.
        var waited = Duration.zero;
        var anchored = service.spokenText.value == beatText;
        while (!anchored && waited < _utteranceWaitCap) {
          if (!mounted ||
              generation != _demoGeneration ||
              widget.data.highlight != 'status') {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
          waited += const Duration(milliseconds: 100);
          anchored = service.spokenText.value == beatText;
        }
        if (!mounted ||
            generation != _demoGeneration ||
            widget.data.highlight != 'status') {
          return;
        }
        final offlineDelay = offlineAfter - waited;
        if (offlineDelay > Duration.zero) {
          await Future<void>.delayed(offlineDelay);
          if (!mounted ||
              generation != _demoGeneration ||
              widget.data.highlight != 'status') {
            return;
          }
        }
        // Never flip backwards past the narration: with a very late anchor
        // (past the closing clause) just settle online.
        if (waited < onlineAfter) {
          setState(() => _online = false);
        }
        await Future<void>.delayed(onlineAfter - offlineAfter);
        if (!mounted ||
            generation != _demoGeneration ||
            widget.data.highlight != 'status') {
          return;
        }
        setState(() => _online = true);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const green = Color(0xFF10B981);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: _online
            ? green.withValues(alpha: 0.12)
            : colors.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: _online
              ? green.withValues(alpha: 0.3)
              : colors.error.withValues(alpha: 0.3),
        ),
      ),
      // Narrow phone frames (landscape) are only ~120px wide: the title
      // shares its row with the switch, and the explanation takes the full
      // width below, so both always show completely instead of collapsing
      // into a word-per-line column next to a full-size switch.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _online ? green : colors.error,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  // Mirrors the real bar: flipping invisible keeps you online
                  // but marks you invisible (it does NOT show the
                  // network-offline state, which hides the switch).
                  _online
                      ? data.text('youAreCurrentlyOnlineAndVisible')
                      : '${data.text('youAreCurrentlyOnline')} ${data.text('andInvisible')}',
                  softWrap: true,
                  style: TextStyle(
                    fontSize: 7.5,
                    fontWeight: FontWeight.w600,
                    color: _online ? green : colors.error,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              // Fixed layout box: a raw Switch is ~59px wide and would starve
              // the text of width; the scaled paint fits exactly (0.55×59≈32).
              SizedBox(
                width: 32,
                height: 22,
                child: Transform.scale(
                  scale: 0.55,
                  alignment: Alignment.center,
                  child: Switch(
                    value: _online,
                    onChanged: (v) {
                      // A manual tap wins over the scripted demo run.
                      _demoGeneration++;
                      setState(() => _online = v);
                    },
                    activeThumbColor: green,
                    inactiveThumbColor: colors.error,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            data.text('onlineToggleExplained'),
            softWrap: true,
            style: TextStyle(
              fontSize: 6.5,
              color: colors.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

/// Mock bottom navigation bar with the five real tabs; [activeIndex] shows
/// which tab the demonstrated screen lives in.
class _DemoBottomNav extends StatelessWidget {
  const _DemoBottomNav({required this.data, required this.activeIndex});

  final OnboardingSceneData data;
  final int activeIndex;

  static const List<IconData> _icons = [
    Icons.home_outlined,
    Icons.people_outline,
    Icons.chat_bubble_outline,
    Icons.calendar_today_outlined,
    Icons.person_outline,
  ];
  static const List<IconData> _activeIcons = [
    Icons.home,
    Icons.people,
    Icons.chat_bubble,
    Icons.calendar_today,
    Icons.person,
  ];
  static const List<String> _labelKeys = [
    'navHome',
    'navMatches',
    'navChats',
    'navEvents',
    'navProfile',
  ];

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: List.generate(_icons.length, (i) {
          final active = i == activeIndex;
          final color = active
              ? colors.primary
              : colors.onSurface.withValues(alpha: 0.45);
          return Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  active ? _activeIcons[i] : _icons[i],
                  size: 16,
                  color: color,
                ),
                const SizedBox(height: 2),
                Text(
                  data.text(_labelKeys[i]),
                  maxLines: 2,
                  overflow: TextOverflow.visible,
                  style: TextStyle(
                    fontSize: 8,
                    color: color,
                    fontWeight: active ? FontWeight.bold : FontWeight.w400,
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Highlight system
// ---------------------------------------------------------------------------

/// Wraps a replica region that a beat can spotlight. The active region gets a
/// pulsing ring; every other region dims (unless [dimWhenInactive] is false,
/// e.g. when one region is nested inside another).
class HighlightableRegion extends StatelessWidget {
  const HighlightableRegion({
    super.key,
    required this.id,
    required this.activeId,
    required this.child,
    this.radius = const BorderRadius.all(Radius.circular(10)),
    this.dimWhenInactive = true,
  });

  final String id;
  final String? activeId;
  final Widget child;
  final BorderRadius radius;
  final bool dimWhenInactive;

  @override
  Widget build(BuildContext context) {
    final active = activeId == id;
    final dim = dimWhenInactive && activeId != null && !active;
    return AnimatedOpacity(
      opacity: dim ? 0.3 : 1.0,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
      child: Stack(
        children: [
          child,
          if (active)
            Positioned.fill(
              child: IgnorePointer(child: _HighlightRing(radius: radius)),
            ),
        ],
      ),
    );
  }
}

class _HighlightRing extends StatefulWidget {
  const _HighlightRing({required this.radius});

  final BorderRadius radius;

  @override
  State<_HighlightRing> createState() => _HighlightRingState();
}

class _HighlightRingState extends State<_HighlightRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );
  bool _reduceMotion = false;
  bool _motionInitialized = false;

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
    final color = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => CustomPaint(
        painter: _HighlightRingPainter(
          t: _reduceMotion ? 0 : _controller.value,
          radius: widget.radius,
          color: color,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _HighlightRingPainter extends CustomPainter {
  _HighlightRingPainter({
    required this.t,
    required this.radius,
    required this.color,
  });

  final double t;
  final BorderRadius radius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final pulse = 0.5 + 0.5 * math.sin(2 * math.pi * t);
    final rrect = radius.toRRect(Offset.zero & size);

    // Soft glow underneath the crisp ring.
    canvas.drawRRect(
      rrect.deflate(2 + 2 * pulse),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..color = color.withValues(alpha: 0.16 + 0.16 * pulse)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    canvas.drawRRect(
      rrect.deflate(2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..color = color.withValues(alpha: 0.75 + 0.25 * pulse),
    );
  }

  @override
  bool shouldRepaint(_HighlightRingPainter oldDelegate) =>
      oldDelegate.t != t || oldDelegate.color != color;
}

/// Loops a gentle 1.0 → 1.1 scale on its child (map density circles, typing
/// dots…) so the replicas feel alive instead of like screenshots.
class GentlePulse extends StatefulWidget {
  const GentlePulse({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 1900),
  });

  final Widget child;
  final Duration duration;

  @override
  State<GentlePulse> createState() => _GentlePulseState();
}

class _GentlePulseState extends State<GentlePulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late final Animation<double> _scale = Tween<double>(
    begin: 1.0,
    end: 1.1,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  bool _reduceMotion = false;
  bool _motionInitialized = false;

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
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_reduceMotion) return widget.child;
    return ScaleTransition(scale: _scale, child: widget.child);
  }
}

// ---------------------------------------------------------------------------
// Shared small parts
// ---------------------------------------------------------------------------

/// Gradient initials avatar used wherever the real app shows a photo.
class _DemoAvatar extends StatelessWidget {
  const _DemoAvatar({required this.initials, this.size = 26, this.seed = 0});

  final String initials;
  final double size;
  final int seed;

  static const List<List<Color>> _gradients = [
    [Color(0xFF6366F1), Color(0xFF8B5CF6)],
    [Color(0xFFEC4899), Color(0xFFF472B6)],
    [Color(0xFFF59E0B), Color(0xFFFB923C)],
    [Color(0xFF10B981), Color(0xFF34D399)],
  ];

  @override
  Widget build(BuildContext context) {
    final colors = _gradients[seed % _gradients.length];
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        initials,
        style: TextStyle(
          fontSize: size * 0.38,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _DemoChip extends StatelessWidget {
  const _DemoChip({
    required this.label,
    required this.icon,
    this.selected = false,
    this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;

  /// When set, the chip is a live filter demo: tapping selects it.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: selected
            ? colors.primary.withValues(alpha: 0.15)
            : colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: selected
              ? colors.primary
              : colors.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 9,
            color: selected
                ? colors.primary
                : colors.onSurface.withValues(alpha: 0.6),
          ),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.visible,
              style: TextStyle(
                fontSize: 8.5,
                fontWeight: selected ? FontWeight.bold : FontWeight.w400,
                color: selected
                    ? colors.primary
                    : colors.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return chip;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: chip,
    );
  }
}

IconData _directionalArrow(BuildContext context) {
  // Icons.arrow_forward auto-mirrors in RTL, so always return the forward
  // glyph; manually returning arrow_back in RTL would mirror twice.
  return Icons.arrow_forward;
}

/// First letter of a localized demo name, used as the avatar "photo" initial
/// so the monogram follows the UI language (Maya→M, מאיה→מ…).
String _demoInitial(String name) {
  final trimmed = name.trim();
  return trimmed.isEmpty ? '?' : trimmed.substring(0, 1);
}

// ---------------------------------------------------------------------------
// Welcome
// ---------------------------------------------------------------------------

class WelcomeReplica extends StatelessWidget {
  const WelcomeReplica({super.key, required this.data});

  final OnboardingSceneData data;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        const _DemoStatusBar(),
        // Scroll-safe: on short landscape frames the hero + steps are
        // taller than the phone, so this region scrolls instead of
        // overflowing. On tall frames the content stays vertically centered.
        Expanded(
          child: LayoutBuilder(
            builder: (context, viewport) => SingleChildScrollView(
              padding: const EdgeInsets.all(14),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: (viewport.maxHeight - 28).clamp(
                    0.0,
                    double.infinity,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    HighlightableRegion(
                      id: 'hero',
                      activeId: data.highlight,
                      radius: BorderRadius.circular(20),
                      dimWhenInactive: false,
                      child: Column(
                        children: [
                          Container(
                            width: 76,
                            height: 76,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(
                                colors: [colors.primary, colors.secondary],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                            ),
                            child: const Icon(
                              Icons.favorite,
                              color: Colors.white,
                              size: 38,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            data.text('appName'),
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: colors.onSurface,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            data.text('onboardingTagline'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 10.5,
                              color: colors.onSurface.withValues(alpha: 0.6),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 22),
                    HighlightableRegion(
                      id: 'steps',
                      activeId: data.highlight,
                      radius: BorderRadius.circular(16),
                      dimWhenInactive: false,
                      child: Row(
                        children: [
                          Expanded(
                            child: _stepTile(
                              context,
                              Icons.person_add_alt,
                              'onboardingWelcomeStepProfile',
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: Icon(
                              _directionalArrow(context),
                              size: 12,
                              color: colors.primary,
                            ),
                          ),
                          Expanded(
                            child: _stepTile(
                              context,
                              Icons.radar_outlined,
                              'onboardingWelcomeStepDiscover',
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: Icon(
                              _directionalArrow(context),
                              size: 12,
                              color: colors.primary,
                            ),
                          ),
                          Expanded(
                            child: _stepTile(
                              context,
                              Icons.chat_bubble,
                              'onboardingWelcomeStepChat',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _stepTile(BuildContext context, IconData icon, String labelKey) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 3),
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: colors.primary),
          const SizedBox(height: 3),
          // Step labels must show completely in every language: they wrap
          // onto as many lines as needed instead of clipping.
          Text(
            data.text(labelKey),
            textAlign: TextAlign.center,
            softWrap: true,
            overflow: TextOverflow.visible,
            style: TextStyle(
              fontSize: 7,
              color: colors.onSurface.withValues(alpha: 0.75),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Home
// ---------------------------------------------------------------------------

class HomeReplica extends StatefulWidget {
  const HomeReplica({super.key, required this.data});

  final OnboardingSceneData data;

  @override
  State<HomeReplica> createState() => _HomeReplicaState();
}

class _HomeReplicaState extends State<HomeReplica> {
  /// Shared demo intent selection (null = All). The real home screen keeps
  /// independent state per section; the tour simplifies to one row that
  /// filters both sections at once.
  String? _intent;

  OnboardingSceneData get data => widget.data;

  static const List<({String nameKey, String intent, String rating, int seed})>
  _matches = [
    (nameKey: 'demoName1', intent: 'dating', rating: '4.8', seed: 0),
    (nameKey: 'demoName3', intent: 'friends', rating: '4.6', seed: 2),
  ];
  static const List<
    ({String nameKey, String msgKey, String intent, int seed, bool unread})
  >
  _chats = [
    (
      nameKey: 'demoName2',
      msgKey: 'demoLastMessage1',
      intent: 'friends',
      seed: 1,
      unread: true,
    ),
    (
      nameKey: 'demoName1',
      msgKey: 'demoChatMessage1',
      intent: 'dating',
      seed: 0,
      unread: false,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final matches = _matches
        .where((m) => _intent == null || m.intent == _intent)
        .toList();
    final chats = _chats
        .where((c) => _intent == null || c.intent == _intent)
        .toList();
    return Column(
      children: [
        const _DemoStatusBar(),
        _DemoMiniAppBar(data: data, title: data.text('navHome')),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 2),
                Text(
                  data.text('onboardingDemoGreeting'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: colors.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                HighlightableRegion(
                  id: 'stats',
                  activeId: data.highlight,
                  child: Row(
                    children: [
                      _statCard(
                        context,
                        Icons.radar_outlined,
                        '3',
                        'homeNearby',
                      ),
                      const SizedBox(width: 6),
                      _statCard(
                        context,
                        Icons.people_outline,
                        '12',
                        'homeOnline',
                      ),
                      const SizedBox(width: 6),
                      _statCard(
                        context,
                        Icons.workspace_premium,
                        '★',
                        'tierGold',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                HighlightableRegion(
                  id: 'filters',
                  activeId: data.highlight,
                  radius: BorderRadius.circular(999),
                  // Wrap: narrow landscape frames fit one chip per line.
                  // Live demo: tapping a chip filters both sections below,
                  // tapping All restores every intent.
                  child: Wrap(
                    spacing: 5,
                    runSpacing: 5,
                    children: [
                      _DemoChip(
                        label: data.text('generalAll'),
                        icon: Icons.tune_rounded,
                        selected: _intent == null,
                        onTap: () => setState(() => _intent = null),
                      ),
                      _DemoChip(
                        label: data.text('onboardingDemoIntentFriends'),
                        icon: Icons.group_outlined,
                        selected: _intent == 'friends',
                        onTap: () => setState(() => _intent = 'friends'),
                      ),
                      _DemoChip(
                        label: data.text('onboardingDemoIntentDating'),
                        icon: Icons.favorite_border,
                        selected: _intent == 'dating',
                        onTap: () => setState(() => _intent = 'dating'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                HighlightableRegion(
                  id: 'recents',
                  activeId: data.highlight,
                  radius: BorderRadius.circular(14),
                  dimWhenInactive: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _sectionHeader(context, 'homeRecentMatches'),
                      const SizedBox(height: 4),
                      // Mirrors MatchBoxList: one card holding divider-separated
                      // rows (photo, name + star rating, age and gender).
                      Container(
                        decoration: BoxDecoration(
                          color: colors.surfaceContainerHighest.withValues(
                            alpha: 0.5,
                          ),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: colors.outlineVariant.withValues(alpha: 0.4),
                          ),
                        ),
                        child: Column(
                          children: [
                            for (var i = 0; i < matches.length; i++) ...[
                              _homeMatchRow(
                                context,
                                data.text(matches[i].nameKey),
                                matches[i].rating,
                                matches[i].seed,
                              ),
                              if (i < matches.length - 1)
                                Divider(
                                  height: 1,
                                  color: colors.outlineVariant.withValues(
                                    alpha: 0.4,
                                  ),
                                ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      _sectionHeader(context, 'homeRecentChats'),
                      const SizedBox(height: 4),
                      for (final chat in chats) ...[
                        _chatRow(
                          context,
                          data.text(chat.nameKey),
                          data.text(chat.msgKey),
                          chat.seed,
                          unread: chat.unread,
                        ),
                        const SizedBox(height: 5),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        ),
        _DemoBottomNav(data: data, activeIndex: 0),
      ],
    );
  }

  Widget _sectionHeader(BuildContext context, String key) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Text(
            data.text(key),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: colors.onSurface.withValues(alpha: 0.8),
            ),
          ),
        ),
        TextButton(
          onPressed: () {},
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: const TextStyle(
              fontSize: 8.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          child: Text(data.text('homeSeeAll')),
        ),
      ],
    );
  }

  Widget _statCard(
    BuildContext context,
    IconData icon,
    String value,
    String labelKey,
  ) {
    final colors = Theme.of(context).colorScheme;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          color: colors.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colors.primary.withValues(alpha: 0.2)),
        ),
        child: Column(
          children: [
            Icon(icon, size: 15, color: colors.primary),
            const SizedBox(height: 2),
            Text(
              value,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: colors.onSurface,
              ),
            ),
            Text(
              data.text(labelKey),
              maxLines: 2,
              overflow: TextOverflow.visible,
              style: TextStyle(
                fontSize: 7.5,
                color: colors.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Recent-match row shaped like the real MatchBox: photo, name with star
  /// rating, and the age-and-gender line (no invented % score).
  Widget _homeMatchRow(
    BuildContext context,
    String name,
    String rating,
    int seed,
  ) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(7),
      child: Row(
        children: [
          _DemoAvatar(initials: _demoInitial(name), size: 30, seed: seed),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.visible,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: colors.onSurface,
                        ),
                      ),
                    ),
                    Icon(Icons.star, size: 10, color: Colors.amber.shade700),
                    const SizedBox(width: 2),
                    Text(
                      rating,
                      style: TextStyle(
                        fontSize: 8.5,
                        fontWeight: FontWeight.w600,
                        color: colors.onSurface,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${data.text('demoAge1')} · ${data.text('demoGender1')}',
                  maxLines: 2,
                  overflow: TextOverflow.visible,
                  style: TextStyle(
                    fontSize: 8,
                    color: colors.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chatRow(
    BuildContext context,
    String name,
    String message,
    int seed, {
    bool unread = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: unread
            ? colors.primary.withValues(alpha: 0.07)
            : colors.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          _DemoAvatar(initials: _demoInitial(name), seed: seed),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.visible,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: colors.onSurface,
                  ),
                ),
                Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.visible,
                  style: TextStyle(
                    fontSize: 8,
                    color: colors.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
          if (unread)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: colors.primary,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '1',
                style: TextStyle(
                  fontSize: 7,
                  fontWeight: FontWeight.bold,
                  color: colors.onPrimary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Nearby map
// ---------------------------------------------------------------------------

class NearbyReplica extends StatelessWidget {
  const NearbyReplica({super.key, required this.data});

  final OnboardingSceneData data;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        const _DemoStatusBar(),
        // Real nearby screen is a pushed full-screen map: back button, no
        // visibility strip, and the radius control under the title.
        _DemoMiniAppBar(
          data: data,
          title: data.text('homeNearbyMap'),
          showBack: true,
          showStatusStrip: false,
          subtitle: LayoutBuilder(
            builder: (context, constraints) => HighlightableRegion(
              id: 'radius',
              activeId: data.highlight,
              radius: BorderRadius.circular(999),
              dimWhenInactive: false,
              child: Container(
                width: constraints.maxWidth,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: colors.primary.withValues(alpha: 0.4),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 5,
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.radar_outlined, size: 11, color: colors.primary),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        data.text(
                          'homeNearbyMapRadius',
                          params: {'radius': data.text('onboardingDemoRadius')},
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.visible,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          color: colors.primary,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.keyboard_arrow_down,
                      size: 12,
                      color: colors.onSurface.withValues(alpha: 0.5),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Stack(
              children: [
                // The map itself.
                Positioned.fill(
                  child: HighlightableRegion(
                    id: 'map',
                    activeId: data.highlight,
                    radius: BorderRadius.circular(14),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Stack(
                        children: [
                          // Map backdrop (light tile look, as in the online map).
                          Container(color: const Color(0xFFD4EBF4)),
                          // Street grid.
                          Positioned(
                            left: 0,
                            right: 0,
                            top: 46,
                            child: _street(colors),
                          ),
                          Positioned(
                            left: 0,
                            right: 0,
                            top: 120,
                            child: _street(colors),
                          ),
                          Positioned(
                            top: 0,
                            bottom: 0,
                            left: 70,
                            child: _street(colors, vertical: true),
                          ),
                          Positioned(
                            top: 0,
                            bottom: 0,
                            left: 170,
                            child: _street(colors, vertical: true),
                          ),
                          // User's match radius circle (single circle, as in the real app).
                          Positioned(
                            left: 50,
                            top: 50,
                            child: Container(
                              width: 120,
                              height: 120,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: colors.primary.withValues(alpha: 0.12),
                                border: Border.all(
                                  color: colors.primary.withValues(alpha: 0.5),
                                  width: 2,
                                  style: BorderStyle.solid,
                                ),
                              ),
                              child: Center(
                                child: Text(
                                  data.text(
                                    'onboardingDemoRadius',
                                    params: {
                                      'radius': data.text(
                                        'onboardingDemoRadius',
                                      ),
                                    },
                                  ),
                                  style: TextStyle(
                                    fontSize: 8,
                                    fontWeight: FontWeight.w600,
                                    color: colors.primary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // Own position marker (blue, like the real app).
                          Positioned(
                            left: 108,
                            top: 108,
                            child: Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.blueAccent,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2.5,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.blueAccent.withValues(
                                      alpha: 0.4,
                                    ),
                                    blurRadius: 8,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          // Other visible users inside the match radius, as on
                          // the real map: one plain dot per person (the real
                          // map only adds counts to multi-user clusters).
                          // All dots share one size — every dot is one user.
                          for (final d in const [
                            (left: 72.0, top: 82.0),
                            (left: 120.0, top: 70.0),
                            (left: 94.0, top: 120.0),
                            (left: 132.0, top: 110.0),
                            (left: 105.0, top: 145.0),
                          ])
                            Positioned(
                              left: d.left,
                              top: d.top,
                              child: HighlightableRegion(
                                id: 'users',
                                activeId: data.highlight,
                                radius: BorderRadius.circular(999),
                                dimWhenInactive: false,
                                child: _personDot(),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                // Total count pill (top-left): five dots on the map, five
                // online — part of the map chrome, always visible.
                Positioned(
                  left: 8,
                  top: 8,
                  child: Material(
                    elevation: 0,
                    borderRadius: BorderRadius.circular(999),
                    color: colors.surface.withValues(alpha: 0.94),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      child: Text(
                        data.text(
                          'mapShowingApproxUsers',
                          params: {'count': '5'},
                        ),
                        style: TextStyle(
                          fontSize: 8,
                          fontWeight: FontWeight.w600,
                          color: colors.onSurface,
                        ),
                      ),
                    ),
                  ),
                ),
                // Legend (top-right): exactly the real nearby legend — you in
                // blue, nearby users in deep purple. Country counts live only
                // on the separate online world map, never here.
                Positioned(
                  right: 8,
                  top: 8,
                  child: Material(
                    elevation: 2,
                    borderRadius: BorderRadius.circular(10),
                    color: colors.surface.withValues(alpha: 0.92),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 7,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _legendDot(Colors.blueAccent),
                              const SizedBox(width: 6),
                              Text(
                                data.text('mapLegendYou'),
                                style: TextStyle(
                                  fontSize: 7.5,
                                  color: colors.onSurface,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 5),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _legendDot(Colors.deepPurple),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  data.text('mapLegendOnlineUsersApprox'),
                                  maxLines: 2,
                                  overflow: TextOverflow.visible,
                                  style: TextStyle(
                                    fontSize: 7.5,
                                    color: colors.onSurface,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // Zoom controls (bottom-right).
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: Container(
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: colors.outlineVariant.withValues(alpha: 0.4),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 5,
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _zoomButton(colors, Icons.add),
                        Container(
                          width: 22,
                          height: 1,
                          color: colors.outlineVariant.withValues(alpha: 0.4),
                        ),
                        _zoomButton(colors, Icons.remove),
                      ],
                    ),
                  ),
                ),
                // My-location FAB (bottom-right, above zoom).
                Positioned(
                  right: 10,
                  bottom: 72,
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: colors.primary,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.15),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                    child: Icon(
                      Icons.my_location,
                      size: 15,
                      color: colors.onPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _legendDot(Color color) {
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(width: 1.6, color: Colors.white),
      ),
    );
  }

  /// Another visible user inside the match radius, mirroring the real
  /// single-user markers: a deep-purple dot with a white border and a
  /// plain white center (no counts — one dot per person, all one size).
  Widget _personDot() {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.deepPurple.withValues(alpha: 0.78),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.95),
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Container(
        width: 6,
        height: 6,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _zoomButton(ColorScheme colors, IconData icon) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 30,
        height: 26,
        child: Icon(
          icon,
          size: 14,
          color: colors.onSurface.withValues(alpha: 0.7),
        ),
      ),
    );
  }

  Widget _street(ColorScheme colors, {bool vertical = false}) {
    return Container(
      width: vertical ? 3 : null,
      height: vertical ? null : 3,
      color: colors.onSurface.withValues(alpha: 0.08),
    );
  }
}

// ---------------------------------------------------------------------------
// Online world map (separate screen, as in the real app)
// ---------------------------------------------------------------------------

/// Replica of the standalone online world map (opened from the home screen's
/// online cards — NOT part of the nearby radius map): a world view with one
/// label per country counting its online members, plus the total pill.
class WorldMapReplica extends StatelessWidget {
  const WorldMapReplica({super.key, required this.data});

  final OnboardingSceneData data;

  String _countryName(BuildContext context, String code) {
    final lang = Localizations.localeOf(context).languageCode;
    return localizedCountryNames[lang]?[code] ??
        localizedCountryNames['en']?[code] ??
        code;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        const _DemoStatusBar(),
        // Pushed screen: back button, no visibility strip, no bottom nav.
        _DemoMiniAppBar(
          data: data,
          title: data.text('homeOnline'),
          showBack: true,
          showStatusStrip: false,
          subtitle: LayoutBuilder(
            builder: (context, constraints) => HighlightableRegion(
              id: 'total',
              activeId: data.highlight,
              radius: BorderRadius.circular(999),
              dimWhenInactive: false,
              child: Container(
                width: constraints.maxWidth,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: colors.primary.withValues(alpha: 0.4),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 5,
                    ),
                  ],
                ),
                child: Text(
                  data.text('onlineMapTotalOnline', params: {'count': '25'}),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.visible,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: colors.primary,
                  ),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: HighlightableRegion(
              id: 'markers',
              activeId: data.highlight,
              radius: BorderRadius.circular(14),
              dimWhenInactive: false,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                // LayoutBuilder keeps the geography glued to the frame: the
                // painter fills whatever space the phone gives it and each
                // count stays centered on its own country at any size.
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final w =
                        constraints.maxWidth.isFinite &&
                            constraints.maxWidth > 0
                        ? constraints.maxWidth
                        : 200.0;
                    final h =
                        constraints.maxHeight.isFinite &&
                            constraints.maxHeight > 0
                        ? constraints.maxHeight
                        : 200.0;
                    return SizedBox(
                      width: w,
                      height: h,
                      child: Stack(
                        children: [
                          const Positioned.fill(
                            child: CustomPaint(painter: _WorldMapPainter()),
                          ),
                          Align(
                            alignment: const Alignment(0.06, -0.68),
                            child: _countryPill(
                              context,
                              _countryName(context, 'DE'),
                              '12',
                            ),
                          ),
                          Align(
                            alignment: const Alignment(-0.08, -0.46),
                            child: _countryPill(
                              context,
                              _countryName(context, 'FR'),
                              '8',
                            ),
                          ),
                          Align(
                            alignment: const Alignment(0.20, -0.33),
                            child: _countryPill(
                              context,
                              _countryName(context, 'IL'),
                              '5',
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Country label mirroring the real markers: dark name pill above a
  /// purple count pill.
  Widget _countryPill(BuildContext context, String name, String count) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            name,
            maxLines: 2,
            overflow: TextOverflow.visible,
            style: const TextStyle(fontSize: 8, color: Colors.white),
          ),
        ),
        const SizedBox(height: 2),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.deepPurple.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.white, width: 1.2),
          ),
          child: Text(
            count,
            style: const TextStyle(
              fontSize: 8,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }
}

/// Stylized world map behind the online-map counts, drawn in fraction space
/// so it fills any phone frame: the Americas left, Europe/Africa center,
/// Asia right, Australia bottom-right — like the real online map's tiles.
/// Country pills anchor to matching fractions (DE ~0.53/0.16,
/// FR ~0.46/0.27, IL ~0.60/0.335).
class _WorldMapPainter extends CustomPainter {
  const _WorldMapPainter();

  static const List<List<List<double>>> _lands = [
    // North America.
    [
      [0.04, 0.24],
      [0.09, 0.15],
      [0.17, 0.09],
      [0.25, 0.10],
      [0.29, 0.16],
      [0.26, 0.23],
      [0.21, 0.25],
      [0.205, 0.31],
      [0.23, 0.37],
      [0.19, 0.39],
      [0.16, 0.33],
      [0.11, 0.31],
      [0.05, 0.29],
    ],
    // Greenland.
    [
      [0.29, 0.05],
      [0.36, 0.04],
      [0.37, 0.09],
      [0.31, 0.10],
    ],
    // South America.
    [
      [0.25, 0.41],
      [0.31, 0.41],
      [0.32, 0.49],
      [0.29, 0.59],
      [0.25, 0.65],
      [0.22, 0.57],
      [0.20, 0.48],
    ],
    // Europe.
    [
      [0.455, 0.14],
      [0.52, 0.10],
      [0.565, 0.12],
      [0.575, 0.18],
      [0.54, 0.235],
      [0.48, 0.25],
      [0.44, 0.21],
    ],
    // Britain.
    [
      [0.435, 0.12],
      [0.455, 0.12],
      [0.45, 0.17],
      [0.435, 0.17],
    ],
    // Iberia and France.
    [
      [0.44, 0.24],
      [0.50, 0.235],
      [0.50, 0.30],
      [0.45, 0.315],
      [0.42, 0.28],
    ],
    // Africa.
    [
      [0.47, 0.30],
      [0.555, 0.28],
      [0.585, 0.35],
      [0.565, 0.45],
      [0.535, 0.54],
      [0.50, 0.55],
      [0.475, 0.46],
      [0.45, 0.38],
    ],
    // Madagascar.
    [
      [0.60, 0.47],
      [0.615, 0.47],
      [0.61, 0.53],
      [0.598, 0.53],
    ],
    // Asia.
    [
      [0.58, 0.10],
      [0.72, 0.06],
      [0.87, 0.09],
      [0.95, 0.14],
      [0.93, 0.24],
      [0.78, 0.28],
      [0.66, 0.30],
      [0.585, 0.25],
    ],
    // Arabia.
    [
      [0.585, 0.29],
      [0.645, 0.29],
      [0.63, 0.37],
      [0.585, 0.37],
    ],
    // India.
    [
      [0.665, 0.30],
      [0.715, 0.30],
      [0.69, 0.39],
    ],
    // Southeast Asia.
    [
      [0.74, 0.32],
      [0.79, 0.33],
      [0.775, 0.40],
      [0.745, 0.39],
    ],
    // Korea.
    [
      [0.815, 0.235],
      [0.83, 0.235],
      [0.828, 0.27],
      [0.813, 0.27],
    ],
    // Japan.
    [
      [0.86, 0.20],
      [0.875, 0.20],
      [0.865, 0.27],
      [0.855, 0.27],
    ],
    // Indonesia.
    [
      [0.76, 0.43],
      [0.83, 0.44],
      [0.82, 0.47],
      [0.77, 0.46],
    ],
    // Australia.
    [
      [0.79, 0.52],
      [0.89, 0.50],
      [0.92, 0.56],
      [0.84, 0.60],
      [0.78, 0.57],
    ],
    // New Zealand.
    [
      [0.945, 0.60],
      [0.955, 0.60],
      [0.95, 0.65],
      [0.943, 0.65],
    ],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFD4EBF4),
    );
    final fill = Paint()..color = const Color(0xFFF2EFE9);
    final soft = Paint()
      ..color = const Color(0xFFF2EFE9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    for (final land in _lands) {
      final path = Path()
        ..moveTo(land[0][0] * size.width, land[0][1] * size.height);
      for (var i = 1; i < land.length; i++) {
        path.lineTo(land[i][0] * size.width, land[i][1] * size.height);
      }
      path.close();
      canvas.drawPath(path, soft);
      canvas.drawPath(path, fill);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ---------------------------------------------------------------------------
// Matches
// ---------------------------------------------------------------------------
class MatchesReplica extends StatefulWidget {
  const MatchesReplica({super.key, required this.data});

  final OnboardingSceneData data;

  @override
  State<MatchesReplica> createState() => _MatchesReplicaState();
}

class _MatchesReplicaState extends State<MatchesReplica> {
  /// Live filter demo (null = All), mirroring the real matches screen:
  /// tapping an intent shows only matches of that intent, All restores all.
  String? _intent;

  OnboardingSceneData get data => widget.data;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final showMaya = _intent == null || _intent == 'dating';
    final showSofia = _intent == null || _intent == 'friends';
    return Column(
      children: [
        const _DemoStatusBar(),
        _DemoMiniAppBar(data: data, title: data.text('navMatches')),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Column(
              children: [
                const SizedBox(height: 4),
                // Intent filter chips (All / Friends / Dating) — as on the real screen.
                HighlightableRegion(
                  id: 'filters',
                  activeId: data.highlight,
                  radius: BorderRadius.circular(999),
                  child: Wrap(
                    spacing: 5,
                    runSpacing: 5,
                    children: [
                      _DemoChip(
                        label: data.text('generalAll'),
                        icon: Icons.tune_rounded,
                        selected: _intent == null,
                        onTap: () => setState(() => _intent = null),
                      ),
                      _DemoChip(
                        label: data.text('onboardingDemoIntentFriends'),
                        icon: Icons.group_outlined,
                        selected: _intent == 'friends',
                        onTap: () => setState(() => _intent = 'friends'),
                      ),
                      _DemoChip(
                        label: data.text('onboardingDemoIntentDating'),
                        icon: Icons.favorite_border,
                        selected: _intent == 'dating',
                        onTap: () => setState(() => _intent = 'dating'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                // Sort-by label + pill (matches the real PopupMenuButton look).
                // Wrap: narrow landscape frames drop the pill below the label.
                HighlightableRegion(
                  id: 'sort',
                  activeId: data.highlight,
                  radius: BorderRadius.circular(999),
                  dimWhenInactive: false,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      Text(
                        data.text('sortByLabel'),
                        style: TextStyle(
                          fontSize: 8.5,
                          color: colors.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: colors.primary.withValues(alpha: 0.35),
                          ),
                          color: colors.primary.withValues(alpha: 0.08),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.sort_rounded,
                              size: 11,
                              color: colors.primary,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                data.text('sortOptionNewest'),
                                maxLines: 2,
                                overflow: TextOverflow.visible,
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w600,
                                  color: colors.primary,
                                ),
                              ),
                            ),
                            Icon(
                              Icons.keyboard_arrow_down,
                              size: 11,
                              color: colors.primary,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                HighlightableRegion(
                  id: 'cards',
                  activeId: data.highlight,
                  radius: BorderRadius.circular(14),
                  dimWhenInactive: false,
                  child: Column(
                    children: [
                      if (showMaya)
                        _matchCard(
                          context,
                          'M',
                          data.text('demoName1'),
                          '5',
                          data.text('demoInterest1'),
                          data.text('demoInterest2'),
                          0,
                          withExpiry: true,
                        ),
                      if (showMaya && showSofia) const SizedBox(height: 8),
                      if (showSofia)
                        _matchCard(
                          context,
                          'S',
                          data.text('demoName3'),
                          '3',
                          data.text('demoInterest3'),
                          data.text('demoInterest1'),
                          2,
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        ),
        _DemoBottomNav(data: data, activeIndex: 1),
      ],
    );
  }

  Widget _matchCard(
    BuildContext context,
    String initials,
    String name,
    String sharedCount,
    String interest1,
    String interest2,
    int seed, {
    bool withExpiry = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    // Mirrors the real match card: header (avatar, name, shared-interest
    // count — matches show a count, never a % score) and interest chips on
    // top, and the expiry countdown + Extend button in a details row at
    // the bottom of the card (hidden once chatting starts).
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _DemoAvatar(initials: initials, size: 34, seed: seed),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 2,
                            overflow: TextOverflow.visible,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: colors.onSurface,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: colors.secondary.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.favorite,
                                size: 8.5,
                                color: colors.secondary,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                sharedCount,
                                style: TextStyle(
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.bold,
                                  color: colors.secondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 4,
                      runSpacing: 3,
                      children: [
                        _DemoChip(label: interest1, icon: Icons.hiking),
                        _DemoChip(label: interest2, icon: Icons.music_note),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (withExpiry) ...[
            const SizedBox(height: 6),
            HighlightableRegion(
              id: 'expiry',
              activeId: data.highlight,
              radius: BorderRadius.circular(999),
              dimWhenInactive: false,
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.timer_outlined,
                          size: 9,
                          color: colors.tertiary,
                        ),
                        const SizedBox(width: 2),
                        Flexible(
                          child: Text(
                            data.text('onboardingDemoTimeLeft'),
                            maxLines: 2,
                            overflow: TextOverflow.visible,
                            style: TextStyle(
                              fontSize: 8,
                              fontWeight: FontWeight.bold,
                              color: colors.tertiary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  // One-tap extension: each side of the match can extend once.
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: colors.primary,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.more_time_outlined,
                          size: 9,
                          color: colors.onPrimary,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          data.text('matchExtendButton'),
                          style: TextStyle(
                            fontSize: 8,
                            fontWeight: FontWeight.bold,
                            color: colors.onPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Chats
// ---------------------------------------------------------------------------

class ChatsReplica extends StatelessWidget {
  const ChatsReplica({super.key, required this.data});

  final OnboardingSceneData data;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        const _DemoStatusBar(),
        _DemoMiniAppBar(data: data, title: data.text('navChats')),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Column(
              children: [
                const SizedBox(height: 4),
                HighlightableRegion(
                  id: 'list',
                  activeId: data.highlight,
                  radius: BorderRadius.circular(12),
                  dimWhenInactive: false,
                  child: Column(
                    children: [
                      Container(
                        height: 30,
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 9),
                        decoration: BoxDecoration(
                          color: colors.surfaceContainerHighest.withValues(
                            alpha: 0.45,
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.search,
                              size: 13,
                              color: colors.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                data.text('chatsSearchHint'),
                                maxLines: 2,
                                overflow: TextOverflow.visible,
                                style: TextStyle(
                                  fontSize: 8.5,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Intent filter chips (All / Friends / Dating) — as on the real chats tab.
                      Wrap(
                        spacing: 5,
                        runSpacing: 5,
                        children: [
                          _DemoChip(
                            label: data.text('generalAll'),
                            icon: Icons.tune_rounded,
                            selected: true,
                          ),
                          _DemoChip(
                            label: data.text('onboardingDemoIntentFriends'),
                            icon: Icons.group_outlined,
                          ),
                          _DemoChip(
                            label: data.text('onboardingDemoIntentDating'),
                            icon: Icons.favorite_border,
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      _chatRow(
                        context,
                        data.text('demoName2'),
                        data.text('demoLastMessage1'),
                        1,
                        unread: true,
                      ),
                      const SizedBox(height: 4),
                      _chatRow(
                        context,
                        data.text('demoName1'),
                        data.text('demoChatMessage1'),
                        0,
                      ),
                    ],
                  ),
                ),
                // No second filter row: intent filters are explained once
                // for both Matches and Chats (see Matches4), so the replica
                // keeps a single chip row inside the spotlighted list above.
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
        _DemoBottomNav(data: data, activeIndex: 2),
      ],
    );
  }

  Widget _chatRow(
    BuildContext context,
    String name,
    String message,
    int seed, {
    bool unread = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: unread
            ? colors.primary.withValues(alpha: 0.07)
            : colors.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          _DemoAvatar(initials: _demoInitial(name), seed: seed),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.visible,
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.bold,
                    color: colors.onSurface,
                  ),
                ),
                Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.visible,
                  style: TextStyle(
                    fontSize: 8,
                    color: colors.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
          if (unread)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: colors.primary,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '1',
                style: TextStyle(
                  fontSize: 7,
                  fontWeight: FontWeight.bold,
                  color: colors.onPrimary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

class EventsReplica extends StatelessWidget {
  const EventsReplica({super.key, required this.data});

  final OnboardingSceneData data;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        const _DemoStatusBar(),
        _DemoMiniAppBar(data: data, title: data.text('navEvents')),
        Expanded(
          child: Stack(
            children: [
              SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Column(
                  children: [
                    const SizedBox(height: 4),
                    HighlightableRegion(
                      id: 'cards',
                      activeId: data.highlight,
                      radius: BorderRadius.circular(12),
                      child: Column(
                        children: [
                          _eventCard(context),
                          const SizedBox(height: 8),
                          _eventCard(context, alt: true),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    // Real events chrome: shared-event-matching + past-events toggles
                    // and device/online import buttons, as on the real events tab.
                    HighlightableRegion(
                      id: 'calendar',
                      activeId: data.highlight,
                      radius: BorderRadius.circular(12),
                      dimWhenInactive: false,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: colors.surfaceContainerHighest.withValues(
                            alpha: 0.5,
                          ),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: colors.outlineVariant.withValues(alpha: 0.4),
                          ),
                        ),
                        child: Column(
                          children: [
                            _toggleRow(
                              context,
                              data.text('settingsSharedEventMatching'),
                              true,
                            ),
                            const SizedBox(height: 4),
                            _toggleRow(
                              context,
                              data.text('showPastEvents'),
                              false,
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: _importButton(
                                    context,
                                    Icons.devices_outlined,
                                    data.text('eventsImportDeviceCalendar'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: _importButton(
                                    context,
                                    Icons.cloud_outlined,
                                    data.text('eventsImportOnlineProviders'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 64),
                  ],
                ),
              ),
              // Add-event floating action button (real FAB.extended), bottom-right.
              Positioned(
                right: 10,
                bottom: 10,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                  child: Material(
                    color: colors.primary,
                    borderRadius: BorderRadius.circular(20),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add, size: 14, color: colors.onPrimary),
                            const SizedBox(width: 4),
                            Text(
                              data.text('eventAdd'),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: colors.onPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        _DemoBottomNav(data: data, activeIndex: 3),
      ],
    );
  }

  Widget _toggleRow(BuildContext context, String label, bool enabled) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 8.5,
              fontWeight: FontWeight.w500,
              color: colors.onSurface,
            ),
          ),
        ),
        Transform.scale(
          scale: 0.65,
          child: Switch(
            value: enabled,
            onChanged: null,
            activeThumbColor: colors.secondary,
            activeTrackColor: colors.secondary.withValues(alpha: 0.3),
          ),
        ),
      ],
    );
  }

  Widget _importButton(BuildContext context, IconData icon, String label) {
    final colors = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      onPressed: null,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        minimumSize: const Size(0, 30),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        side: BorderSide(color: colors.primary.withValues(alpha: 0.6)),
      ),
      icon: Icon(icon, size: 12, color: colors.primary),
      label: Text(
        label,
        maxLines: 2,
        overflow: TextOverflow.visible,
        style: TextStyle(
          fontSize: 7.5,
          fontWeight: FontWeight.w600,
          color: colors.primary,
        ),
      ),
    );
  }

  Widget _eventCard(BuildContext context, {bool alt = false}) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Date chip.
          Container(
            width: 30,
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: (alt ? colors.secondary : colors.primary).withValues(
                alpha: 0.15,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                Text(
                  data.text(
                    alt ? 'onboardingDemoDaySun' : 'onboardingDemoDaySat',
                  ),
                  style: TextStyle(
                    fontSize: 6.5,
                    fontWeight: FontWeight.bold,
                    color: alt ? colors.secondary : colors.primary,
                  ),
                ),
                Text(
                  alt ? '21' : '20',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: colors.onSurface,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  data.text(alt ? 'demoEventTitle2' : 'demoEventTitle'),
                  maxLines: 2,
                  overflow: TextOverflow.visible,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.bold,
                    color: colors.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  data.text(alt ? 'demoEventMeta2' : 'demoEventMeta'),
                  maxLines: 2,
                  overflow: TextOverflow.visible,
                  style: TextStyle(
                    fontSize: 8,
                    color: colors.onSurface.withValues(alpha: 0.55),
                  ),
                ),
                const SizedBox(height: 4),
                // Mirrors the real events list item: a details link on the
                // left and map + delete actions on the right. Attendance is
                // implicit via the events you added (calendar sync, ticket
                // upload, link, manual entry) — there is no attendee avatar
                // stack and no one-tap Join button on this screen.
                Row(
                  children: [
                    Expanded(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              data.text('eventViewDetails'),
                              maxLines: 2,
                              overflow: TextOverflow.visible,
                              style: TextStyle(
                                fontSize: 8,
                                fontWeight: FontWeight.w600,
                                color: colors.primary,
                              ),
                            ),
                          ),
                          Icon(
                            directionalForwardIos(context),
                            size: 8,
                            color: colors.primary.withValues(alpha: 0.7),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: colors.primaryContainer.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: colors.primary.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Icon(
                        Icons.map_outlined,
                        size: 11,
                        color: colors.primary,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: colors.error.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        Icons.delete_outline,
                        size: 11,
                        color: colors.error,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Profile
// ---------------------------------------------------------------------------

class ProfileReplica extends StatelessWidget {
  const ProfileReplica({super.key, required this.data});

  final OnboardingSceneData data;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        const _DemoStatusBar(),
        _DemoMiniAppBar(data: data, title: data.text('navProfile')),
        Expanded(
          child: Stack(
            children: [
              SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 4),
                    HighlightableRegion(
                      id: 'photos',
                      activeId: data.highlight,
                      radius: BorderRadius.circular(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: _photoTile(
                                  context,
                                  seed: 0,
                                  headShot: true,
                                  primary: true,
                                ),
                              ),
                              Expanded(
                                child: _photoTile(
                                  context,
                                  seed: 1,
                                  headShot: true,
                                ),
                              ),
                              Expanded(
                                child: _photoTile(
                                  context,
                                  seed: 2,
                                  headShot: false,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            data.text('demoName2'),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: colors.onSurface,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            data.text('demoBio'),
                            maxLines: 2,
                            overflow: TextOverflow.visible,
                            style: TextStyle(
                              fontSize: 8.5,
                              color: colors.onSurface.withValues(alpha: 0.6),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: [
                              _DemoChip(
                                label:
                                    '${data.text('demoAge1')} · ${data.text('demoGender1')}',
                                icon: Icons.circle_outlined,
                                selected: true,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    HighlightableRegion(
                      id: 'interests',
                      activeId: data.highlight,
                      radius: BorderRadius.circular(12),
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          _DemoChip(
                            label: data.text('demoInterest1'),
                            icon: Icons.hiking,
                            selected: true,
                          ),
                          _DemoChip(
                            label: data.text('demoInterest2'),
                            icon: Icons.music_note,
                          ),
                          _DemoChip(
                            label: data.text('demoInterest3'),
                            icon: Icons.flight_takeoff,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    HighlightableRegion(
                      id: 'verify',
                      activeId: data.highlight,
                      radius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: colors.primary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: colors.primary.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.verified_user_outlined,
                              size: 16,
                              color: colors.primary,
                            ),
                            const SizedBox(width: 7),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    data.text(
                                      'onboardingBeatProfileVerifyLabel',
                                    ),
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: colors.primary,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(999),
                                    child: LinearProgressIndicator(
                                      value: 0.6,
                                      minHeight: 3.5,
                                      backgroundColor:
                                          colors.surfaceContainerHighest,
                                      color: colors.primary,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    data.text(
                                      'onboardingBeatProfileVerifyHint',
                                    ),
                                    style: TextStyle(
                                      fontSize: 7.5,
                                      color: colors.onSurface.withValues(
                                        alpha: 0.5,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.verified_user_outlined,
                              size: 14,
                              color: colors.primary,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
              // Edit-profile FAB (real FloatingActionButton.extended), bottom-right.
              Positioned(
                right: 10,
                bottom: 10,
                child: HighlightableRegion(
                  id: 'edit',
                  activeId: data.highlight,
                  radius: BorderRadius.circular(16),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.25),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                    child: Material(
                      color: colors.primary,
                      elevation: 0,
                      borderRadius: BorderRadius.circular(16),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 9,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.edit_outlined,
                              size: 14,
                              color: colors.onPrimary,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              data.text('generalEdit'),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: colors.onPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        _DemoBottomNav(data: data, activeIndex: 4),
      ],
    );
  }

  /// Mock profile photo tile: a painted head shot for the main photo and
  /// head or body shots for the secondaries, standing in for real photos
  /// that passed the app photo rules (face visible on the main photo).
  /// Fully code-drawn so the tour stays deterministic with no assets.
  Widget _photoTile(
    BuildContext context, {
    required int seed,
    required bool headShot,
    bool primary = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    const skins = [
      Color(0xFFF3D9C4),
      Color(0xFFE4B48C),
      Color(0xFFC68854),
      Color(0xFF7C4A2D),
    ];
    const hairs = [
      Color(0xFF241A12),
      Color(0xFF6B3F16),
      Color(0xFF9AA0A6),
      Color(0xFFA33F1F),
    ];
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      height: 58,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        gradient: LinearGradient(
          colors: [
            _photoColor(context, seed).withValues(alpha: 0.85),
            _photoColor(context, seed).withValues(alpha: 0.5),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
          color: primary ? colors.primary : Colors.transparent,
          width: primary ? 1.5 : 0,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: CustomPaint(
        painter: _MockPhotoPainter(
          skin: skins[seed % skins.length],
          hair: hairs[seed % hairs.length],
          shirt: _photoColor(context, (seed + 1) % 3),
          headShot: headShot,
        ),
      ),
    );
  }

  Color _photoColor(BuildContext context, int i) {
    final colors = Theme.of(context).colorScheme;
    switch (i) {
      case 0:
        return colors.primary;
      case 1:
        return colors.secondary;
      default:
        return colors.tertiary;
    }
  }
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

/// Flat-illustration stand-in for a profile photo: hair, face and
/// shoulders (head shot) or a longer torso (body shot) in varying tones.
class _MockPhotoPainter extends CustomPainter {
  _MockPhotoPainter({
    required this.skin,
    required this.hair,
    required this.shirt,
    required this.headShot,
  });

  final Color skin;
  final Color hair;
  final Color shirt;
  final bool headShot;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final cx = size.width / 2;
    final h = size.height;
    final r = (headShot ? size.width * 0.24 : size.width * 0.17).clamp(
      8.0,
      20.0,
    );
    final hy = headShot ? h * 0.36 : h * 0.28;
    // Torso/shoulders first (behind the head).
    final sh = headShot ? h * 0.34 : h * 0.46;
    final sw = headShot ? size.width * 0.88 : size.width * 0.66;
    canvas.drawRRect(
      RRect.fromLTRBR(
        cx - sw / 2,
        h - sh,
        cx + sw / 2,
        h + 6,
        Radius.circular(sh * 0.5),
      ),
      Paint()..color = shirt,
    );
    // Neck.
    canvas.drawRect(
      Rect.fromCenter(
        center: Offset(cx, hy + r * 0.95),
        width: r * 0.5,
        height: r * 0.5,
      ),
      Paint()..color = skin,
    );
    // Hair cap behind the face, then the face itself.
    canvas.drawCircle(
      Offset(cx, hy - r * 0.22),
      r * 1.04,
      Paint()..color = hair,
    );
    canvas.drawCircle(Offset(cx, hy), r, Paint()..color = skin);
  }

  @override
  bool shouldRepaint(covariant _MockPhotoPainter oldDelegate) =>
      oldDelegate.skin != skin ||
      oldDelegate.hair != hair ||
      oldDelegate.shirt != shirt ||
      oldDelegate.headShot != headShot;
}

/// Real-settings mirror: same sections order and icons as the actual settings
/// screen. Auto-scrolls the highlighted section into view when the tour steps
/// through it.
class SettingsReplica extends StatefulWidget {
  const SettingsReplica({super.key, required this.data});

  final OnboardingSceneData data;

  @override
  State<SettingsReplica> createState() => _SettingsReplicaState();
}

class _SettingsReplicaState extends State<SettingsReplica> {
  static const List<({String region, IconData icon, String key})> _rowDefs = [
    (region: 'tour', icon: Icons.school_outlined, key: 'settingsAppTour'),
    (
      region: 'display',
      icon: Icons.settings_display,
      key: 'settingsAppDisplay',
    ),
    (region: 'matching', icon: Icons.favorite_border, key: 'settingsMatching'),
    (
      region: 'prefs',
      icon: Icons.people_alt_outlined,
      key: 'settingsMatchPreferences',
    ),
    (
      region: 'invisibility',
      icon: Icons.visibility_off,
      key: 'settingsInvisibilityRules',
    ),
    (
      region: 'notifs',
      icon: Icons.notifications_outlined,
      key: 'settingsNotifications',
    ),
    (
      region: 'paywall',
      icon: Icons.workspace_premium_outlined,
      key: 'paywallTitle',
    ),
    (region: 'billing', icon: Icons.receipt_long_outlined, key: 'billingTitle'),
    (region: 'invite', icon: Icons.card_giftcard, key: 'inviteFriendsTitle'),
    (
      region: 'verify',
      icon: Icons.verified_outlined,
      key: 'profileVerification',
    ),
    (region: 'security', icon: Icons.security, key: 'securitySignInHubTitle'),
    (region: 'account', icon: Icons.person, key: 'settingsAccountManagement'),
  ];

  late final Map<String, GlobalKey> _rowKeys = {
    for (final r in _rowDefs) r.region: GlobalKey(),
  };

  OnboardingSceneData get data => widget.data;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const _DemoStatusBar(),
        _DemoMiniAppBar(
          data: data,
          title: data.text('settingsTitle'),
          gearRegionId: 'entry',
          showBack: true,
          showStatusStrip: false,
        ),
        Expanded(
          // SingleChildScrollView (not a lazy ListView) so every row is
          // always materialized: the highlighted section's context exists
          // even below the fold, and auto-scroll + spotlight stay in sync
          // with the narration on every beat.
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Column(
              children: [
                for (final r in _rowDefs) ...[
                  _settingsRow(context, r.region, r.icon, r.key),
                  const SizedBox(height: 7),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  void didUpdateWidget(covariant SettingsReplica oldWidget) {
    super.didUpdateWidget(oldWidget);
    final id = data.highlight;
    if (id == oldWidget.data.highlight) return;
    final target = _rowDefs.where((r) => r.region == id).toList();
    if (target.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _rowKeys[target.first.region]?.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Widget _settingsRow(
    BuildContext context,
    String regionId,
    IconData icon,
    String labelKey,
  ) {
    final colors = Theme.of(context).colorScheme;
    return KeyedSubtree(
      key: _rowKeys[regionId],
      child: HighlightableRegion(
        id: regionId,
        activeId: data.highlight,
        radius: BorderRadius.circular(12),
        dimWhenInactive: false,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: colors.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(9),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: 13, color: colors.primary),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    data.text(labelKey),
                    maxLines: 2,
                    overflow: TextOverflow.visible,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: colors.onSurface,
                    ),
                  ),
                ),
                // arrow_forward_ios auto-mirrors in RTL, so no Transform.flip:
                // it points left in Hebrew on its own.
                Icon(
                  Icons.arrow_forward_ios,
                  size: 9,
                  color: colors.onSurface.withValues(alpha: 0.45),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Finish
// ---------------------------------------------------------------------------

class FinishReplica extends StatelessWidget {
  const FinishReplica({super.key, required this.data});

  final OnboardingSceneData data;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        const _DemoStatusBar(),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GentlePulse(
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [colors.primary, colors.secondary],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                      child: const Icon(
                        Icons.check,
                        color: Colors.white,
                        size: 38,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    data.text('onboardingChapterFinish'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: colors.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Icon(
                    Icons.celebration_outlined,
                    size: 18,
                    color: colors.tertiary,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
