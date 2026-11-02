// One place for every in-person meet-up tool: agree on a meeting point, share
// live location, or help them spot you with a signal, beacon or Spot me card.
//
// The hub is deliberately a launcher, not a second implementation: the plan
// flow, the coordination feed and the live-location system are the same
// surfaces the chat and profile already use.
//
// Every tool has to stay visible at once on a narrow phone, so a row is the
// action itself and its explanation opens in a sheet rather than expanding in
// place.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/chat_model.dart';
import 'package:matchme/models/location_share_session.dart';
import 'package:matchme/models/meetup_models.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/location_share_provider.dart';
import 'package:matchme/providers/meetup_alerts_provider.dart';
import 'package:matchme/providers/meetup_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/screens/location_share/location_share_duration_dialog.dart';
import 'package:matchme/screens/location_share/location_share_map_screen.dart';
import 'package:matchme/screens/meetup/beacon_screen.dart';
import 'package:matchme/screens/meetup/meetup_coordination_widgets.dart';
import 'package:matchme/screens/meetup/meetup_outfit_figure.dart';
import 'package:matchme/screens/meetup/meetup_screen.dart';
import 'package:matchme/screens/meetup/meetup_spot_composer.dart';
import 'package:matchme/services/location_service.dart';
import 'package:matchme/theme/app_theme_tokens.dart';
import 'package:matchme/utils/localized_duration.dart';
import 'package:matchme/utils/meetup_display.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:matchme/utils/unit_utils.dart';
import 'package:matchme/widgets/safe_text.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class MeetupHubScreen extends ConsumerStatefulWidget {
  final String matchId;
  final String otherUserId;
  final String otherUserName;
  final String matchType;
  final String? eventName;

  const MeetupHubScreen({
    super.key,
    required this.matchId,
    required this.otherUserId,
    required this.otherUserName,
    this.matchType = 'proximity',
    this.eventName,
  });

  @override
  ConsumerState<MeetupHubScreen> createState() => _MeetupHubScreenState();
}

class _MeetupHubScreenState extends ConsumerState<MeetupHubScreen> {
  Timer? _ticker;
  MeetupSurfacesNotifier? _meetupSurfaces;
  bool _surfacesEntered = false;

  @override
  void initState() {
    super.initState();
    // Provider state must not be modified while the tree is building, so the
    // registration waits for the end of this frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _meetupSurfaces = ref.read(meetupSurfacesProvider.notifier);
      _meetupSurfaces!.enter(widget.matchId);
      _surfacesEntered = true;
    });
    // Signals, beacons and spot cards expire on a clock; the provider only
    // changes on a database event, so rebuild to drop expired items.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    if (_surfacesEntered) {
      _meetupSurfaces?.exit(widget.matchId);
      _meetupSurfaces = null;
      _surfacesEntered = false;
    }
    _ticker?.cancel();
    super.dispose();
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _openPlan() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MeetupScreen(
          matchId: widget.matchId,
          otherUserId: widget.otherUserId,
          otherUserName: widget.otherUserName,
          matchType: widget.matchType,
          eventName: widget.eventName,
        ),
      ),
    );
  }

  void _openMap() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const LocationShareMapScreen()));
  }

  Future<void> _sendSignal() async {
    await showMeetupGesturePicker(context, ref, widget.matchId);
  }

  Future<void> _openBeacon() async {
    final current = ref.read(meetupProvider(widget.matchId));
    if (current.myBeacon == null) {
      final error = await ref
          .read(meetupProvider(widget.matchId).notifier)
          .showBeacon();
      if (!mounted) return;
      if (error != null) {
        _message(ref.read(localizationProvider).getString(error));
        return;
      }
    }
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MeetupBeaconScreen(
          matchId: widget.matchId,
          otherUserName: widget.otherUserName,
          mine: true,
        ),
      ),
    );
  }

  Future<void> _sendSpot() async {
    final shared = await showMeetupSpotComposer(
      context,
      matchId: widget.matchId,
      otherUserName: widget.otherUserName,
    );
    if (shared && mounted) {
      _message(ref.read(localizationProvider).getString('meetupSpotMeShared'));
    }
  }

  Future<void> _startLiveLocation() async {
    final l10n = ref.read(localizationProvider);
    if (shouldSkipSupabaseCalls()) {
      _message(l10n.getString('locationShareOffline'));
      return;
    }

    final notifier = ref.read(locationShareProvider.notifier);
    final hasExistingSignal = await notifier.hasActiveShareSignal(
      widget.matchId,
    );
    if (!mounted) return;
    if (hasExistingSignal) {
      await notifier.viewExistingShare(
        matchId: widget.matchId,
        otherUserId: widget.otherUserId,
        otherUserName: widget.otherUserName,
      );
      if (!mounted) return;
      _openMap();
      return;
    }

    final hasPermission = await ref
        .read(locationServiceProvider)
        .handleLocationPermission();
    if (!mounted) return;
    if (!hasPermission) {
      _message(l10n.getString('locationPermissionDenied'));
      return;
    }

    final duration = await showDialog<Duration>(
      context: context,
      builder: (_) =>
          LocationShareDurationDialog(otherUserName: widget.otherUserName),
    );
    if (duration == null || !mounted) return;

    await notifier.startSharing(
      matchId: widget.matchId,
      otherUserId: widget.otherUserId,
      otherUserName: widget.otherUserName,
      duration: duration == Duration.zero ? null : duration,
    );
    if (!mounted) return;
    _message(l10n.getString('locationShareStarted'));
  }

  Future<void> _changeLiveDuration() async {
    final l10n = ref.read(localizationProvider);
    final newDuration = await showDialog<Duration>(
      context: context,
      builder: (_) => LocationShareDurationDialog(
        otherUserName: widget.otherUserName,
        isChangingDuration: true,
      ),
    );
    if (newDuration == null || !mounted) return;
    await ref
        .read(locationShareProvider.notifier)
        .updateDuration(newDuration == Duration.zero ? null : newDuration);
    if (!mounted) return;
    _message(l10n.getString('locationShareDurationUpdated'));
  }

  Future<void> _showLiveOptions() async {
    final l10n = ref.read(localizationProvider);
    final choice = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: Text(l10n.getString('locationShareChangeDuration')),
                onTap: () => Navigator.of(sheetContext).pop('duration'),
              ),
              ListTile(
                leading: Icon(
                  Icons.stop_circle_outlined,
                  color: Theme.of(sheetContext).colorScheme.error,
                ),
                title: Text(
                  l10n.getString('locationShareStop'),
                  style: TextStyle(
                    color: Theme.of(sheetContext).colorScheme.error,
                  ),
                ),
                onTap: () => Navigator.of(sheetContext).pop('stop'),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == 'duration') {
      await _changeLiveDuration();
    } else if (choice == 'stop' && mounted) {
      await ref.read(locationShareProvider.notifier).stopSharing();
    }
  }

  void _showCompare() {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _MeetupCompareSheet(),
    );
  }

  void _showExplainer(_ToolExplainer explainer) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _MeetupExplainSheet(explainer: explainer),
    );
  }

  String? _planStatus(MeetupState state, LocalizationState l10n) {
    final session = state.session;
    if (session == null || session.isExpired) return null;
    if (state.isProposed) {
      return state.isMyProposal
          ? l10n.getString(
              'meetupHubPlanProposedByMe',
              params: {'name': widget.otherUserName},
            )
          : l10n.getString(
              'meetupHubPlanProposedByOther',
              params: {'name': widget.otherUserName},
            );
    }
    if (!state.isActive) return null;
    if (state.hasPendingPlaceChange && !state.isMyPlaceChange) {
      return l10n.getString(
        'meetupChangePlaceIncomingTitle',
        params: {'name': widget.otherUserName},
      );
    }
    final place = _chosenPlace(state, l10n);
    if (place == null) return l10n.getString('meetupActiveTitle');
    return l10n.getString('meetupHubPlanAgreed', params: {'place': place});
  }

  String? _liveStatus(LocationShareSession? session, LocalizationState l10n) {
    if (session == null) return null;
    final iShare = session.myStatus == ShareStatus.sharing;
    final otherShare = session.otherStatus == ShareStatus.sharing;
    if (!iShare) {
      if (!otherShare) return null;
      return l10n.getString(
        'meetupHubLiveOtherSharing',
        params: {'name': widget.otherUserName},
      );
    }

    // Their own chosen deadline stays visible in a mutual share too: the
    // "no timers" rule covers the auto-stopping tools, not this one.
    final mutual = otherShare;
    final label = l10n.getString(
      mutual ? 'meetupHubLiveMutual' : 'meetupHubLiveSharing',
    );
    final time = _liveTime(session, l10n);
    if (time == null) return label;
    if (mutual) {
      return '$label${l10n.getString('summarySeparator')}$time';
    }
    return l10n.getString('meetupHubLiveSharingFor', params: {'time': time});
  }

  /// The remaining time, "until you stop" when the share is open-ended, or null
  /// when the share has run out and the one-second ticker is about to drop it.
  String? _liveTime(LocationShareSession session, LocalizationState l10n) {
    final remaining = session.timeRemaining;
    if (remaining == null) {
      return l10n.getString('meetupHubLiveUntilOff');
    }
    if (remaining.inSeconds <= 0) return null;
    final hours = remaining.inHours;
    final minutes = remaining.inMinutes % 60;
    final seconds = remaining.inSeconds % 60;
    final duration = hours > 0
        ? formatDurationParts(l10n.getString, hours: hours, minutes: minutes)
        : formatDurationParts(
            l10n.getString,
            minutes: minutes,
            seconds: seconds,
          );
    if (duration.isEmpty) return null;
    return l10n.getString(
      'locationShareCountdownRemaining',
      params: {'duration': duration},
    );
  }

  String? _chosenPlace(MeetupState state, LocalizationState l10n) {
    final session = state.session;
    if (session == null) return null;
    final zone = session.venueZone?.trim();
    final place = session.isEvent && zone != null && zone.isNotEmpty
        ? meetupZoneDisplay(zone, l10n)
        : state.chosenLandmark?.label;
    if (place == null || place.trim().isEmpty) return null;
    return place.trim();
  }

  /// The agreed place in the toolbar, so it survives a signal or spot card
  /// pushing the meeting-point row down the list.
  String? _toolbarPlace(MeetupState state, LocalizationState l10n) {
    if (state.session == null || !state.isActive || state.session!.isExpired) {
      return null;
    }
    final place = _chosenPlace(state, l10n);
    if (place == null) return null;
    final meters = state.chosenLandmark?.distanceMeters;
    if (meters == null || meters <= 0) return place;
    return '$place · ${formatDistance(meters.toDouble(), l10n)}';
  }

  String _nameInitial(String name) {
    final trimmed = name.trim();
    return trimmed.isEmpty ? '?' : trimmed[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(meetupProvider(widget.matchId));
    final share = ref.watch(locationShareProvider);
    final l10n = ref.watch(localizationProvider);
    final otherProfile = ref
        .watch(otherUserProfileProvider(widget.otherUserId))
        .asData
        ?.value;
    final currentUserId = Supabase.instance.client.auth.currentUser?.id ?? '';
    final chats =
        ref.watch(recentChatsProvider(currentUserId)).asData?.value ??
        const <ChatModel>[];
    String? photoSource = otherProfile?.photos
        .where((photo) => photo.trim().isNotEmpty)
        .firstOrNull;
    if (photoSource == null || photoSource.trim().isEmpty) {
      for (final chat in chats) {
        if (chat.otherUserId != widget.otherUserId) continue;
        photoSource = chat.otherUserPhotos
            .where((photo) => photo.trim().isNotEmpty)
            .firstOrNull;
        if (photoSource != null) break;
      }
    }
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final brightness = theme.brightness;

    final liveSession =
        share != null && share.matchId == widget.matchId && !share.isExpired
        ? share
        : null;
    final iShare = liveSession?.myStatus == ShareStatus.sharing;
    final otherShare = liveSession?.otherStatus == ShareStatus.sharing;
    final planOpen =
        state.session != null &&
        (state.isProposed || state.isActive) &&
        !state.session!.isExpired;
    final planAwaiting =
        state.isProposed ||
        (state.hasPendingPlaceChange && !state.isMyPlaceChange);
    final planStatus = _planStatus(state, l10n);
    final liveStatus = _liveStatus(liveSession, l10n);
    final myBeacon = state.myBeacon;
    final myWave = state.myWave;
    final beaconSeed = state.session?.id ?? widget.matchId;

    final signalInk = AppThemeTokens.accentInk(
      Colors.amber.shade700,
      brightness,
    );
    final beaconInk = AppThemeTokens.accentInk(
      Colors.orange.shade700,
      brightness,
    );
    final spotInk = AppThemeTokens.accentInk(Colors.pink.shade600, brightness);
    final liveInk = AppThemeTokens.accentInk(Colors.blue.shade700, brightness);

    final planAction = l10n.getString(
      planOpen ? 'meetupHubPlanOpen' : 'meetupHubPlanAction',
    );
    final liveAction = l10n.getString(
      otherShare
          ? 'meetupHubLiveView'
          : iShare
          ? 'meetupHubLiveManage'
          : 'meetupHubLiveStart',
    );
    final beaconAction = l10n.getString(
      myBeacon == null ? 'meetupHubBeaconAction' : 'meetupHubBeaconOpen',
    );
    final signalAction = l10n.getString(
      myWave == null ? 'meetupHubSignalAction' : 'meetupHubSignalAgain',
    );

    VoidCallback sheetThen(void Function() action) => () {
      Navigator.of(context).pop();
      action();
    };

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        titleSpacing: 4,
        title: _HubToolbar(
          title: l10n.getString(
            'meetupHubIntroTitle',
            params: {'name': widget.otherUserName},
          ),
          place:
              _toolbarPlace(state, l10n) ??
              l10n.getString('meetupHubNothingYet'),
          live: iShare || otherShare,
          initial: _nameInitial(widget.otherUserName),
          photoSource: photoSource,
        ),
        bottom: state.loading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: RefreshIndicator(
        onRefresh: () =>
            ref.read(meetupProvider(widget.matchId).notifier).refresh(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 22),
          children: [
            if (state.offline)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: MeetupInfoBanner(
                  icon: Icons.cloud_off,
                  text: l10n.getString('meetupOffline'),
                ),
              ),
            MeetupCoordinationFeed(
              matchId: widget.matchId,
              otherUserId: widget.otherUserId,
              otherUserName: widget.otherUserName,
            ),
            _ToolGroup(
              children: [
                _StateRow(
                  icon: Icons.edit_location_alt_outlined,
                  accent: colors.primary,
                  title: l10n.getString('meetupHubPlanName'),
                  subtitle: planStatus ?? l10n.getString('meetupHubNothingYet'),
                  rowState: !planOpen
                      ? _RowState.none
                      : planAwaiting
                      ? _RowState.pending
                      : _RowState.active,
                  actionLabel: planAction,
                  onTap: _openPlan,
                  onExplain: () => _showExplainer(
                    _ToolExplainer(
                      icon: Icons.edit_location_alt_outlined,
                      accent: colors.primary,
                      titleKey: 'meetupHubPlanName',
                      factsKey: 'meetupHubPlanFacts',
                      bodyKey: 'meetupHubPlanBody',
                      helpsKey: 'meetupHubComparePlanHelps',
                      seeKey: 'meetupHubComparePlanSee',
                      doKey: 'meetupHubExplainPlanDo',
                      endsKey: 'meetupHubComparePlanLasts',
                      locationKey: 'meetupHubComparePlanLocation',
                      actionLabel: planAction,
                      onAction: sheetThen(_openPlan),
                    ),
                  ),
                ),
                _StateRow(
                  icon: Icons.share_location,
                  accent: liveInk,
                  title: l10n.getString('meetupHubLiveName'),
                  subtitle: liveStatus ?? l10n.getString('meetupHubLiveIdle'),
                  rowState: liveStatus == null
                      ? _RowState.none
                      : _RowState.active,
                  actionLabel: liveAction,
                  onTap: otherShare
                      ? _openMap
                      : iShare
                      ? _showLiveOptions
                      : _startLiveLocation,
                  manageLabel: iShare && otherShare
                      ? l10n.getString('meetupHubLiveManage')
                      : null,
                  onManage: iShare && otherShare ? _showLiveOptions : null,
                  onExplain: () => _showExplainer(
                    _ToolExplainer(
                      icon: Icons.share_location,
                      accent: liveInk,
                      titleKey: 'meetupHubLiveName',
                      factsKey: 'meetupHubLiveFacts',
                      bodyKey: 'meetupHubLiveBody',
                      bodyParamName: widget.otherUserName,
                      helpsKey: 'meetupHubCompareLiveHelps',
                      seeKey: 'meetupHubCompareLiveSee',
                      doKey: 'meetupHubExplainLiveDo',
                      endsKey: 'meetupHubCompareLiveLasts',
                      locationKey: 'meetupHubCompareLiveLocation',
                      actionLabel: liveAction,
                      onAction: sheetThen(
                        otherShare
                            ? _openMap
                            : iShare
                            ? _showLiveOptions
                            : _startLiveLocation,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            _SectionLabel(l10n.getString('meetupHubCloseSection')),
            _ToolTileRow(
              tiles: [
                _ToolTile(
                  icon: myWave == null
                      ? Icons.waving_hand_outlined
                      : Icons.waving_hand,
                  accent: signalInk,
                  label: l10n.getString('meetupHubSignalTitle'),
                  actionLabel: signalAction,
                  badge: myWave == null
                      ? null
                      : l10n.getString('meetupSignalOutgoingPill'),
                  explainLabel: l10n.getString('meetupHubHowItWorks'),
                  onTap: _sendSignal,
                  onExplain: () => _showExplainer(
                    _ToolExplainer(
                      icon: Icons.waving_hand_outlined,
                      accent: signalInk,
                      titleKey: 'meetupHubSignalTitle',
                      factsKey: 'meetupHubSignalFacts',
                      bodyKey: 'meetupHubSignalBody',
                      helpsKey: 'meetupHubCompareSignalHelps',
                      seeKey: 'meetupHubCompareSignalSee',
                      doKey: 'meetupHubExplainSignalDo',
                      endsKey: 'meetupHubCompareSignalLasts',
                      locationKey: 'meetupHubCompareSignalLocation',
                      actionLabel: signalAction,
                      onAction: sheetThen(_sendSignal),
                      preview: const _GesturePreview(),
                    ),
                  ),
                ),
                _ToolTile(
                  icon: myBeacon == null
                      ? Icons.light_mode_outlined
                      : Icons.light_mode,
                  accent: beaconInk,
                  label: l10n.getString('meetupHubBeaconTitle'),
                  actionLabel: beaconAction,
                  iconContent: myBeacon == null
                      ? null
                      : MeetupBeaconShape(
                          sessionId: beaconSeed,
                          size: 30,
                          animate: false,
                        ),
                  badge: myBeacon == null
                      ? null
                      : l10n.getString('meetupBeaconActiveTitle'),
                  explainLabel: l10n.getString('meetupHubHowItWorks'),
                  onTap: _openBeacon,
                  onExplain: () => _showExplainer(
                    _ToolExplainer(
                      icon: Icons.light_mode_outlined,
                      accent: beaconInk,
                      titleKey: 'meetupHubBeaconTitle',
                      factsKey: 'meetupHubBeaconFacts',
                      bodyKey: 'meetupHubBeaconBody',
                      helpsKey: 'meetupHubCompareBeaconHelps',
                      seeKey: 'meetupHubCompareBeaconSee',
                      doKey: 'meetupHubExplainBeaconDo',
                      endsKey: 'meetupHubCompareBeaconLasts',
                      locationKey: 'meetupHubCompareBeaconLocation',
                      actionLabel: beaconAction,
                      onAction: sheetThen(_openBeacon),
                      preview: MeetupBeaconShape(
                        sessionId: beaconSeed,
                        size: 88,
                        animate: false,
                      ),
                    ),
                  ),
                ),
                _ToolTile(
                  icon: Icons.photo_camera_front_outlined,
                  accent: spotInk,
                  label: l10n.getString('meetupHubSpotTitle'),
                  actionLabel: l10n.getString('meetupHubSpotAction'),
                  explainLabel: l10n.getString('meetupHubHowItWorks'),
                  onTap: _sendSpot,
                  onExplain: () => _showExplainer(
                    _ToolExplainer(
                      icon: Icons.photo_camera_front_outlined,
                      accent: spotInk,
                      titleKey: 'meetupHubSpotTitle',
                      factsKey: 'meetupHubSpotFacts',
                      bodyKey: 'meetupHubSpotBody',
                      helpsKey: 'meetupHubCompareSpotHelps',
                      seeKey: 'meetupHubCompareSpotSee',
                      doKey: 'meetupHubExplainSpotDo',
                      endsKey: 'meetupHubCompareSpotLasts',
                      locationKey: 'meetupHubCompareSpotLocation',
                      actionLabel: l10n.getString('meetupHubSpotAction'),
                      onAction: sheetThen(_sendSpot),
                      preview: const SizedBox(
                        height: 88,
                        child: MeetupOutfitFigure(outfit: MeetupOutfitSpec()),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.center,
              child: TextButton.icon(
                onPressed: _showCompare,
                icon: const Icon(Icons.compare_arrows, size: 18),
                label: Text(l10n.getString('meetupHubCompare')),
              ),
            ),
            Text(
              l10n.getString('meetupHubIntroBody'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HubToolbar extends StatelessWidget {
  final String title;
  final String place;
  final bool live;
  final String initial;
  final String? photoSource;

  const _HubToolbar({
    required this.title,
    required this.place,
    required this.live,
    required this.initial,
    required this.photoSource,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final imageSource = photoSource;
    final fallback = Container(
      color: colors.primary.withValues(alpha: 0.14),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            color: colors.primary,
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
      ),
    );
    return Row(
      children: [
        SizedBox(
          width: 48,
          height: 48,
          child: Stack(
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: imageSource != null && imageSource.trim().isNotEmpty
                      ? SignedImage(
                          source: imageSource,
                          width: 44,
                          height: 44,
                          fit: BoxFit.cover,
                          placeholder: fallback,
                          errorWidget: fallback,
                        )
                      : fallback,
                ),
              ),
              if (live)
                PositionedDirectional(
                  end: 2,
                  bottom: 2,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: colors.primary,
                      shape: BoxShape.circle,
                      border: Border.all(color: colors.surface, width: 2),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ShrinkText(
                title,
                maxLines: 2,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              ShrinkText(
                place,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 6),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 2, top: 16, bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _ToolGroup extends StatelessWidget {
  final List<Widget> children;

  const _ToolGroup({required this.children});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

enum _RowState { none, pending, active }

class _StateRow extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final String title;
  final String subtitle;
  final _RowState rowState;
  final String actionLabel;
  final VoidCallback onTap;
  final VoidCallback onExplain;
  final String? manageLabel;
  final VoidCallback? onManage;

  const _StateRow({
    required this.icon,
    required this.accent,
    required this.title,
    required this.subtitle,
    required this.rowState,
    required this.actionLabel,
    required this.onTap,
    required this.onExplain,
    this.manageLabel,
    this.onManage,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final ink = switch (rowState) {
      _RowState.active => colors.primary,
      _RowState.pending => AppThemeTokens.accentInk(
        Colors.amber.shade700,
        theme.brightness,
      ),
      _RowState.none => colors.onSurfaceVariant,
    };

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 11, 6, 11),
        child: Row(
          children: [
            Icon(icon, size: 20, color: accent),
            const SizedBox(width: 11),
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  SafeText(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            if (manageLabel != null)
              TextButton(
                onPressed: onManage,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 34),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(manageLabel!, style: const TextStyle(fontSize: 12)),
              ),
            _ExplainButton(onPressed: onExplain),
            Flexible(
              flex: 2,
              child: ShrinkText(
                actionLabel,
                textAlign: TextAlign.end,
                maxLines: 2,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: ink),
          ],
        ),
      ),
    );
  }
}

class _ExplainButton extends ConsumerWidget {
  final VoidCallback onPressed;

  const _ExplainButton({required this.onPressed});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    return IconButton(
      onPressed: onPressed,
      tooltip: l10n.getString('meetupHubHowItWorks'),
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        minimumSize: const Size(34, 34),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: const Icon(Icons.info_outline, size: 18),
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
  }
}

class _ToolTileRow extends StatelessWidget {
  final List<_ToolTile> tiles;

  const _ToolTileRow({required this.tiles});

  @override
  Widget build(BuildContext context) {
    const gap = 8.0;
    // Enough for the 36 dp accent circle, the tile name, an optional status
    // pill and a two-line explainer footer, so no label has to shrink below
    // the 12 floor to fit.
    const height = 132.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width =
            (constraints.maxWidth - gap * (tiles.length - 1)) / tiles.length;
        return SizedBox(
          height: height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final tile in tiles)
                Padding(
                  padding: EdgeInsets.only(left: tile == tiles.first ? 0 : gap),
                  child: SizedBox(width: width, child: tile),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ToolTile extends StatelessWidget {
  final IconData icon;
  final Widget? iconContent;
  final Color accent;
  final String label;
  final String actionLabel;
  final String explainLabel;
  final String? badge;
  final VoidCallback onTap;
  final VoidCallback onExplain;

  const _ToolTile({
    required this.icon,
    required this.accent,
    required this.label,
    required this.actionLabel,
    required this.explainLabel,
    required this.onTap,
    required this.onExplain,
    this.badge,
    this.iconContent,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Expanded(
            child: Semantics(
              button: true,
              label: actionLabel,
              child: Tooltip(
                message: actionLabel,
                child: InkWell(
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: AppThemeTokens.accentSurface(
                              accent,
                              theme.brightness,
                            ),
                            shape: BoxShape.circle,
                          ),
                          child:
                              iconContent ??
                              Icon(icon, size: 19, color: accent),
                        ),
                        const SizedBox(height: 4),
                        ShrinkText(
                          label,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (badge != null) ...[
                          const SizedBox(height: 3),
                          _StatusPill(label: badge!, accent: accent),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          InkWell(
            onTap: onExplain,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 3),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh.withValues(alpha: 0.45),
                border: Border(top: BorderSide(color: colors.outlineVariant)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.info_outline, size: 12, color: colors.primary),
                  const SizedBox(width: 3),
                  Expanded(
                    child: ShrinkText(
                      explainLabel,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.primary,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String label;
  final Color accent;

  const _StatusPill({required this.label, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_outline, size: 11, color: accent),
          const SizedBox(width: 3),
          Flexible(
            child: ShrinkText(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolExplainer {
  final IconData icon;
  final Color accent;
  final String titleKey;
  final String factsKey;
  final String bodyKey;
  final String bodyParamName;
  final String helpsKey;
  final String seeKey;
  final String doKey;
  final String endsKey;
  final String locationKey;
  final String actionLabel;
  final VoidCallback onAction;
  final Widget? preview;

  const _ToolExplainer({
    required this.icon,
    required this.accent,
    required this.titleKey,
    required this.factsKey,
    required this.bodyKey,
    required this.helpsKey,
    required this.seeKey,
    required this.doKey,
    required this.endsKey,
    required this.locationKey,
    required this.actionLabel,
    required this.onAction,
    this.bodyParamName = '',
    this.preview,
  });
}

class _MeetupExplainSheet extends ConsumerWidget {
  final _ToolExplainer explainer;

  const _MeetupExplainSheet({required this.explainer});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final e = explainer;
    final preview = e.preview;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: AppThemeTokens.accentSurface(
                      e.accent,
                      theme.brightness,
                    ),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(e.icon, size: 21, color: e.accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.getString(e.titleKey),
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        l10n.getString(e.factsKey),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              l10n.getString(
                e.bodyKey,
                params: e.bodyParamName.isEmpty
                    ? null
                    : {'name': e.bodyParamName},
              ),
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
            ),
            if (preview != null) ...[
              const SizedBox(height: 14),
              Center(child: preview),
            ],
            const SizedBox(height: 14),
            _ExplainRow(
              label: l10n.getString('meetupHubCompareHelps'),
              value: l10n.getString(e.helpsKey),
            ),
            _ExplainRow(
              label: l10n.getString('meetupHubCompareSee'),
              value: l10n.getString(e.seeKey),
            ),
            _ExplainRow(
              label: l10n.getString('meetupHubExplainYouDo'),
              value: l10n.getString(e.doKey),
              emphasize: true,
            ),
            _ExplainRow(
              label: l10n.getString('meetupHubCompareLasts'),
              value: l10n.getString(e.endsKey),
            ),
            _ExplainRow(
              label: l10n.getString('meetupHubCompareLocation'),
              value: l10n.getString(e.locationKey),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.getString('meetupHubExplainNotNow')),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: e.onAction,
                    child: Text(e.actionLabel),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ExplainRow extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasize;

  const _ExplainRow({
    required this.label,
    required this.value,
    this.emphasize = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: emphasize ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GesturePreview extends ConsumerWidget {
  const _GesturePreview();

  static const List<String> _gestures = <String>[
    kMeetupGestureWave,
    kMeetupGestureHandsUp,
    kMeetupGestureJumping,
    kMeetupGestureArmsWide,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final gesture in _gestures)
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  meetupGestureIcon(gesture),
                  size: 24,
                  color: colors.primary,
                ),
                const SizedBox(height: 5),
                SizedBox(
                  width: 68,
                  child: ShrinkText(
                    meetupGestureDisplay(gesture, l10n),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    minFontSize: 8,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                      height: 1.25,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _CompareEntry {
  final IconData icon;
  final String name;
  final String helps;
  final String see;
  final String ends;
  final String location;

  const _CompareEntry({
    required this.icon,
    required this.name,
    required this.helps,
    required this.see,
    required this.ends,
    required this.location,
  });
}

class _MeetupCompareSheet extends ConsumerWidget {
  const _MeetupCompareSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    final entries = <_CompareEntry>[
      _CompareEntry(
        icon: Icons.edit_location_alt_outlined,
        name: l10n.getString('meetupHubPlanName'),
        helps: l10n.getString('meetupHubComparePlanHelps'),
        see: l10n.getString('meetupHubComparePlanSee'),
        ends: l10n.getString('meetupHubComparePlanLasts'),
        location: l10n.getString('meetupHubComparePlanLocation'),
      ),
      _CompareEntry(
        icon: Icons.share_location,
        name: l10n.getString('meetupHubLiveName'),
        helps: l10n.getString('meetupHubCompareLiveHelps'),
        see: l10n.getString('meetupHubCompareLiveSee'),
        ends: l10n.getString('meetupHubCompareLiveLasts'),
        location: l10n.getString('meetupHubCompareLiveLocation'),
      ),
      _CompareEntry(
        icon: Icons.waving_hand_outlined,
        name: l10n.getString('meetupHubSignalTitle'),
        helps: l10n.getString('meetupHubCompareSignalHelps'),
        see: l10n.getString('meetupHubCompareSignalSee'),
        ends: l10n.getString('meetupHubCompareSignalLasts'),
        location: l10n.getString('meetupHubCompareSignalLocation'),
      ),
      _CompareEntry(
        icon: Icons.light_mode_outlined,
        name: l10n.getString('meetupHubBeaconTitle'),
        helps: l10n.getString('meetupHubCompareBeaconHelps'),
        see: l10n.getString('meetupHubCompareBeaconSee'),
        ends: l10n.getString('meetupHubCompareBeaconLasts'),
        location: l10n.getString('meetupHubCompareBeaconLocation'),
      ),
      _CompareEntry(
        icon: Icons.photo_camera_front_outlined,
        name: l10n.getString('meetupHubSpotTitle'),
        helps: l10n.getString('meetupHubCompareSpotHelps'),
        see: l10n.getString('meetupHubCompareSpotSee'),
        ends: l10n.getString('meetupHubCompareSpotLasts'),
        location: l10n.getString('meetupHubCompareSpotLocation'),
      ),
    ];

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.getString('meetupHubCompareTitle'),
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.getString('meetupHubCompareBody'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            for (final entry in entries) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(entry.icon, size: 18, color: colors.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            entry.name,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _CompareRow(
                      label: l10n.getString('meetupHubCompareHelps'),
                      value: entry.helps,
                    ),
                    _CompareRow(
                      label: l10n.getString('meetupHubCompareSee'),
                      value: entry.see,
                    ),
                    _CompareRow(
                      label: l10n.getString('meetupHubCompareLasts'),
                      value: entry.ends,
                    ),
                    _CompareRow(
                      label: l10n.getString('meetupHubCompareLocation'),
                      value: entry.location,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.getString('meetupHubCompareClose')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompareRow extends StatelessWidget {
  final String label;
  final String value;

  const _CompareRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
