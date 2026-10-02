import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/location_share_session.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/location_share_provider.dart';

class LocationShareBanner extends ConsumerStatefulWidget {
  final String otherUserId;
  final String otherUserName;
  final VoidCallback? onViewMap;
  final VoidCallback? onStopSharing;
  final VoidCallback? onChangeDuration;
  final VoidCallback? onShareBack;

  const LocationShareBanner({
    super.key,
    required this.otherUserId,
    required this.otherUserName,
    this.onViewMap,
    this.onStopSharing,
    this.onChangeDuration,
    this.onShareBack,
  });

  @override
  ConsumerState<LocationShareBanner> createState() =>
      _LocationShareBannerState();
}

class _LocationShareBannerState extends ConsumerState<LocationShareBanner> {
  Timer? _tickTimer;

  @override
  void initState() {
    super.initState();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(locationShareProvider);
    final l10n = ref.watch(localizationProvider);

    if (session == null) return const SizedBox.shrink();

    if (session.otherUserId != widget.otherUserId &&
        session.myUserId != widget.otherUserId) {
      return const SizedBox.shrink();
    }

    // Am I the one who initiated sharing? (I started sharing with the other user)
    final bool isSharer =
        session.myUserId != widget.otherUserId &&
        session.myStatus == ShareStatus.sharing;

    // Is the other person sharing with me?
    // Show the green banner if they are actively sharing (either we have their position
    // or they have just started and we haven't received the first position yet).
    // A `stopped` status always wins over any leftover position data.
    final bool otherIsSharing =
        session.otherUserId == widget.otherUserId &&
        session.otherStatus != ShareStatus.stopped &&
        (session.otherPosition != null ||
            session.otherStatus == ShareStatus.sharing);

    if (!isSharer && !otherIsSharing) return const SizedBox.shrink();

    final bool isMutual =
        isSharer && session.otherStatus == ShareStatus.sharing;

    if (isMutual) {
      return _buildMutualBanner(session, l10n);
    }

    if (isSharer) {
      return _buildSharerBanner(session, l10n);
    }

    return _buildReceiverBanner(session, l10n);
  }

  String _timeSuffix(LocationShareSession session, LocalizationState l10n) {
    if (session.expiresAt == null) {
      return '(${l10n.getString('locationShareUntilOff')})';
    }
    final remaining = session.timeRemaining;
    if (remaining == null || remaining.inSeconds <= 0) return '';
    if (remaining.inHours > 0) {
      final hours = remaining.inHours;
      final minutes = remaining.inMinutes % 60;
      return '(${l10n.getString('locationShareCountdownHours', params: {'hours': hours.toString(), 'minutes': minutes.toString()})})';
    }
    final minutes = remaining.inMinutes;
    final seconds = remaining.inSeconds % 60;
    return '(${l10n.getString('locationShareCountdownMinutes', params: {'minutes': minutes.toString(), 'seconds': seconds.toString()})})';
  }

  Widget _buildSharerBanner(
    LocationShareSession session,
    LocalizationState l10n,
  ) {
    final hasLocation = session.myPosition != null;
    // Running countdown in the title, mirroring the receiver (green) banner.
    // Previously the suffix only appeared in the subtitle and only after the
    // first GPS fix, so senders without a fix yet (or with a slow fix) saw
    // no duration at all.
    final timeSuffix = _timeSuffix(session, l10n);

    final titleText =
        '${l10n.getString('locationShareBannerYouAreSharing')} $timeSuffix';
    final subtitle = hasLocation
        ? l10n
              .getString('locationShareBannerSharingWith')
              .replaceAll('{name}', widget.otherUserName)
        : l10n.getString('locationShareBannerLocating');

    final showChangeDuration = widget.onChangeDuration != null;
    final showStop = widget.onStopSharing != null;
    final hasAnyAction = showChangeDuration || showStop;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.10),
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.18),
          ],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.35),
          width: 1,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _LiveDot(),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      titleText,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (hasAnyAction) const SizedBox(height: 10),
          if (hasAnyAction)
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (showChangeDuration)
                  Flexible(
                    child: OutlinedButton.icon(
                      onPressed: widget.onChangeDuration,
                      style: OutlinedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        visualDensity: VisualDensity.compact,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        side: BorderSide.none,
                        tapTargetSize: MaterialTapTargetSize.padded,
                      ),
                      icon: const Icon(Icons.timer_outlined, size: 14),
                      label: Text(
                        l10n.getString('locationShareChangeDuration'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                SizedBox(width: showChangeDuration && showStop ? 8 : 0),
                if (showStop)
                  Flexible(
                    child: OutlinedButton.icon(
                      onPressed: widget.onStopSharing,
                      style: OutlinedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.error,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        visualDensity: VisualDensity.compact,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        side: BorderSide.none,
                        tapTargetSize: MaterialTapTargetSize.padded,
                      ),
                      icon: const Icon(Icons.stop, size: 14),
                      label: Text(
                        l10n.getString('locationShareStop'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildReceiverBanner(
    LocationShareSession session,
    LocalizationState l10n,
  ) {
    final hasLocation = session.otherPosition != null;
    final timeSuffix = _timeSuffix(session, l10n);

    final titleText =
        '${l10n.getString('locationShareReceiving').replaceAll('{name}', session.otherUserName)} $timeSuffix';
    final subtitleText = hasLocation
        ? l10n.getString('locationShareBannerSubtitle')
        : l10n.getString('locationShareBannerWaiting');

    return Semantics(
      button: widget.onViewMap != null,
      label: '$titleText. $subtitleText',
      child: GestureDetector(
        onTap: widget.onViewMap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Theme.of(context).colorScheme.tertiary.withValues(alpha: 0.10),
                Theme.of(context).colorScheme.tertiary.withValues(alpha: 0.18),
              ],
            ),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Theme.of(
                context,
              ).colorScheme.tertiary.withValues(alpha: 0.35),
              width: 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.tertiary,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.location_on,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          titleText,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitleText,
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (widget.onViewMap != null) const SizedBox(height: 10),
              if (widget.onViewMap != null)
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: OutlinedButton.icon(
                        onPressed: widget.onViewMap,
                        style: OutlinedButton.styleFrom(
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.tertiary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          visualDensity: VisualDensity.compact,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          side: BorderSide.none,
                          tapTargetSize: MaterialTapTargetSize.padded,
                        ),
                        icon: const Icon(Icons.map, size: 14),
                        label: Text(
                          l10n.getString('locationShareBannerView'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMutualBanner(
    LocationShareSession session,
    LocalizationState l10n,
  ) {
    final timeSuffix = _timeSuffix(session, l10n);

    final titleText = l10n.getString('locationShareMutualActive');
    final subtitleText =
        '${l10n.getString('locationShareTapToView')} $timeSuffix';
    final showStop = widget.onStopSharing != null;

    return Semantics(
      button: widget.onViewMap != null,
      label: '$titleText. $subtitleText',
      child: GestureDetector(
        onTap: widget.onViewMap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Theme.of(context).colorScheme.tertiary.withValues(alpha: 0.10),
                Theme.of(context).colorScheme.tertiary.withValues(alpha: 0.18),
              ],
            ),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Theme.of(
                context,
              ).colorScheme.tertiary.withValues(alpha: 0.35),
              width: 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.tertiary,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.people,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          titleText,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitleText,
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (showStop) const SizedBox(height: 10),
              if (showStop)
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: OutlinedButton.icon(
                        onPressed: widget.onStopSharing,
                        style: OutlinedButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.error,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          visualDensity: VisualDensity.compact,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          side: BorderSide.none,
                          tapTargetSize: MaterialTapTargetSize.padded,
                        ),
                        icon: const Icon(Icons.stop, size: 14),
                        label: Text(
                          l10n.getString('locationShareStop'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small animated pulsing "LIVE" dot indicator.
class _LiveDot extends StatefulWidget {
  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(
      begin: 0.5,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      return const SizedBox(
        width: 28,
        height: 28,
        child: Icon(Icons.share_location, size: 16),
      );
    }
    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (context, child) {
        return Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(context).colorScheme.primary.withValues(
                  alpha: 0.25 * _pulseAnimation.value,
                ),
              ),
            ),
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(context).colorScheme.primary,
              ),
              child: const Center(
                child: Icon(Icons.share_location, color: Colors.white, size: 9),
              ),
            ),
          ],
        );
      },
    );
  }
}
