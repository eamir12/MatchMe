import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/meetup_models.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/meetup_alerts_provider.dart';
import 'package:matchme/providers/meetup_provider.dart';
import 'package:matchme/screens/meetup/meetup_coordination_widgets.dart';
import 'package:matchme/services/landmark_suggestion_service.dart';
import 'package:matchme/utils/map_utils.dart';
import 'package:matchme/utils/meetup_display.dart';
import 'package:matchme/utils/localized_duration.dart';
import 'package:matchme/utils/unit_utils.dart';
import 'package:matchme/widgets/safe_text.dart';

/// In-person meet-up flow for one match: suggest a landmark or venue zone,
/// accept or counter, then coordinate with a beacon, Spot me card or wave.
class MeetupScreen extends ConsumerStatefulWidget {
  final String matchId;
  final String otherUserId;
  final String otherUserName;
  final String matchType;
  final String? eventName;

  const MeetupScreen({
    super.key,
    required this.matchId,
    required this.otherUserId,
    required this.otherUserName,
    this.matchType = 'proximity',
    this.eventName,
  });

  @override
  ConsumerState<MeetupScreen> createState() => _MeetupScreenState();
}

/// Which kind of suggestion sheet is open: a first proposal, a counter, or an
/// edit of the proposer's own pending options.
enum _SuggestionMode { initial, counter, replace }

class _MeetupScreenState extends ConsumerState<MeetupScreen> {
  _SuggestionMode? _suggestionMode;
  final Set<int> _selectedSuggestions = {};
  String? _selectedLandmarkId;
  Timer? _ticker;
  // This is a live meet-up surface: the global alert bar hides while open.
  MeetupSurfacesNotifier? _meetupSurfaces;
  bool _surfacesEntered = false;

  bool get _isEventMatch =>
      widget.matchType.toLowerCase() == 'event' ||
      (widget.eventName?.trim().isNotEmpty ?? false);

  MeetupNotifier get _notifier =>
      ref.read(meetupProvider(widget.matchId).notifier);

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
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (ref.read(meetupProvider(widget.matchId)).isActive) {
        setState(() {});
      }
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

  void _showError(String? key) {
    if (key == null || !mounted) return;
    final l10n = ref.read(localizationProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          l10n.getString(key, params: {'name': widget.otherUserName}),
        ),
      ),
    );
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _loadSuggestions(
    _SuggestionMode mode, {
    bool restoreCacheFirst = false,
  }) async {
    setState(() {
      _suggestionMode = mode;
      _selectedSuggestions.clear();
    });
    // Editing an existing proposal re-shows the list this device already
    // fetched: no position fix and no provider call. Only a deliberate
    // "Find places near me" (or having no list at all) pays for a lookup.
    if (restoreCacheFirst && _notifier.restoreCachedSuggestions()) {
      _selectAllSuggestions();
      return;
    }
    final error = await _notifier.loadSuggestions();
    if (!mounted) return;
    if (error != null) {
      if (error != 'meetupNoPlacesFound') {
        _showError(error);
        setState(() => _suggestionMode = null);
      }
      return;
    }
    _selectAllSuggestions();
  }

  void _selectAllSuggestions() {
    final suggestions = ref.read(meetupProvider(widget.matchId)).suggestions;
    if (!mounted) return;
    setState(() {
      _selectedSuggestions
        ..clear()
        ..addAll(List.generate(suggestions.length, (i) => i));
    });
  }

  void _showOtherSuggestions() {
    _notifier.showMoreSuggestions();
    _selectAllSuggestions();
  }

  Future<void> _sendSelectedSuggestions(
    List<MeetupPlaceSuggestion> suggestions,
  ) async {
    final selected = <MeetupPlaceSuggestion>[
      for (var i = 0; i < suggestions.length; i++)
        if (_selectedSuggestions.contains(i)) suggestions[i],
    ];
    if (selected.isEmpty) return;
    final l10n = ref.read(localizationProvider);
    final mode = _suggestionMode ?? _SuggestionMode.initial;
    final error = switch (mode) {
      _SuggestionMode.counter => await _notifier.counterProximityMeetup(
        selected,
      ),
      _SuggestionMode.replace => await _notifier.replaceProposal(selected),
      _SuggestionMode.initial => await _notifier.startProximityMeetup(selected),
    };
    if (!mounted) return;
    if (error != null) {
      _showError(error);
      return;
    }
    setState(() {
      _suggestionMode = null;
      _selectedSuggestions.clear();
    });
    _showMessage(l10n.getString(_suggestionSentKey(mode)));
  }

  static String _suggestionSentKey(_SuggestionMode mode) {
    switch (mode) {
      case _SuggestionMode.counter:
        return 'meetupCounterSent';
      case _SuggestionMode.replace:
        return 'meetupProposalUpdated';
      case _SuggestionMode.initial:
        return 'meetupProposalSent';
    }
  }

  Future<void> _startEventProposal() async {
    final zone = await _pickZone();
    if (zone == null || !mounted) return;
    final l10n = ref.read(localizationProvider);
    final error = await _notifier.startEventMeetup(zone);
    if (!mounted) return;
    if (error != null) {
      _showError(error);
      return;
    }
    _showMessage(l10n.getString('meetupProposalSent'));
  }

  Future<void> _counterEventProposal() async {
    final zone = await _pickZone();
    if (zone == null || !mounted) return;
    final l10n = ref.read(localizationProvider);
    final error = await _notifier.counterEventMeetup(zone);
    if (!mounted) return;
    if (error != null) {
      _showError(error);
      return;
    }
    _showMessage(l10n.getString('meetupCounterSent'));
  }

  Future<String?> _pickZone() async {
    return showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => _ZonePickerSheet(eventName: widget.eventName),
    );
  }

  Future<void> _accept(String? landmarkId) async {
    final l10n = ref.read(localizationProvider);
    final error = await _notifier.acceptMeetup(landmarkId);
    if (!mounted) return;
    if (error != null) {
      _showError(error);
      return;
    }
    _showMessage(l10n.getString('meetupAccepted'));
  }

  Future<void> _openCustomPlace(_SuggestionMode mode) async {
    final label = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => const _CustomPlaceSheet(),
    );
    if (label == null || !mounted) return;
    final l10n = ref.read(localizationProvider);
    final error = switch (mode) {
      _SuggestionMode.counter => await _notifier.counterCustomPlace(label),
      _SuggestionMode.replace => await _notifier.replaceProposal([
        MeetupPlaceSuggestion.custom(label: label),
      ]),
      _SuggestionMode.initial => await _notifier.startCustomMeetup(label),
    };
    if (!mounted) return;
    if (error != null) {
      _showError(error);
      return;
    }
    setState(() {
      _suggestionMode = null;
      _selectedSuggestions.clear();
    });
    _showMessage(l10n.getString(_suggestionSentKey(mode)));
  }

  Future<void> _openChangePlace() async {
    final place = await showModalBottomSheet<MeetupPlaceSuggestion>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => _ChangePlaceSheet(matchId: widget.matchId),
    );
    if (place == null || !mounted) return;
    final l10n = ref.read(localizationProvider);
    final error = await _notifier.requestPlaceChange(place);
    if (!mounted) return;
    if (error != null) {
      _showError(error);
      return;
    }
    _showMessage(l10n.getString('meetupChangePlaceSent'));
  }

  Future<void> _resolvePlaceChange({required bool accept}) async {
    final l10n = ref.read(localizationProvider);
    final error = await _notifier.resolvePlaceChange(accept: accept);
    if (!mounted) return;
    if (error != null) {
      _showError(error);
      return;
    }
    _showMessage(
      l10n.getString(
        accept ? 'meetupChangePlaceAccepted' : 'meetupChangePlaceDeclined',
      ),
    );
  }

  Future<void> _withdrawPlaceChange() async {
    final l10n = ref.read(localizationProvider);
    final error = await _notifier.withdrawPlaceChange();
    if (!mounted) return;
    if (error != null) {
      _showError(error);
      return;
    }
    _showMessage(l10n.getString('meetupChangePlaceWithdrawn'));
  }

  Future<void> _confirmEnd({required bool found}) async {
    final l10n = ref.read(localizationProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.getString('meetupEndConfirmTitle')),
        content: Text(
          l10n.getString(
            found ? 'meetupEndFoundConfirmBody' : 'meetupEndCancelConfirmBody',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.getString('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              l10n.getString(found ? 'meetupFound' : 'meetupEndCancel'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final error = await _notifier.endMeetup(found: found);
    if (!mounted) return;
    if (error != null) {
      _showError(error);
      return;
    }
    _showMessage(l10n.getString('meetupEndedToast'));
  }

  Future<void> _openPlaceOnMap({
    required String label,
    String? placeId,
    double? latitude,
    double? longitude,
  }) async {
    final opened = await openGoogleMapsPlace(
      label: label,
      placeId: placeId,
      latitude: latitude,
      longitude: longitude,
    );
    if (!opened && mounted) {
      _showError('meetupActionFailed');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(meetupProvider(widget.matchId));
    final l10n = ref.watch(localizationProvider);
    final session = state.session;
    // An ended or expired invite has nothing left to act on: the screen goes
    // straight back to planning so "start again" needs no separate stop.
    final showIntro = session == null || state.isEnded || session.isExpired;

    return Scaffold(
      appBar: AppBar(title: ShrinkText(l10n.getString('meetupTitle'))),
      body: RefreshIndicator(
        onRefresh: () => _notifier.refresh(showLoading: false),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: [
            if (state.offline)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: MeetupInfoBanner(
                  icon: Icons.cloud_off,
                  text: l10n.getString('meetupOffline'),
                ),
              ),
            if (state.loading && session == null)
              const Padding(
                padding: EdgeInsets.only(top: 60),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (showIntro)
              ..._buildIntro(state, l10n)
            else if (state.isProposed)
              ..._buildProposal(state, session, l10n)
            else if (session.isActive)
              ..._buildActive(state, session, l10n)
            else
              ..._buildIntro(state, l10n),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildIntro(MeetupState state, LocalizationState l10n) {
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.handshake_outlined,
                    size: 30,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l10n.getString('meetupTitle'),
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                l10n.getString('meetupIntroBody'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              MeetupInfoBanner(
                icon: Icons.lock_outline,
                text: l10n.getString('meetupPrivacyNote'),
              ),
              const SizedBox(height: 8),
              MeetupInfoBanner(
                icon: Icons.visibility_outlined,
                text: l10n.getString('meetupSafetyNote'),
              ),
              if (_isEventMatch) ...[
                const SizedBox(height: 16),
                if (widget.eventName?.trim().isNotEmpty ?? false)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      widget.eventName!.trim(),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _startEventProposal,
                    icon: const Icon(Icons.stadium_outlined),
                    label: Text(l10n.getString('meetupEventZonesTitle')),
                  ),
                ),
              ] else ...[
                const SizedBox(height: 16),
                if (_suggestionMode != _SuggestionMode.initial) ...[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () =>
                          _loadSuggestions(_SuggestionMode.initial),
                      icon: const Icon(Icons.location_searching),
                      label: Text(l10n.getString('meetupSuggestPlaces')),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          _openCustomPlace(_SuggestionMode.initial),
                      icon: const Icon(Icons.edit_location_alt_outlined),
                      label: Text(l10n.getString('meetupCustomPlace')),
                    ),
                  ),
                ] else
                  ..._buildSuggestionPicker(
                    state,
                    l10n,
                    mode: _SuggestionMode.initial,
                  ),
              ],
            ],
          ),
        ),
      ),
      ..._buildCoordination(),
    ];
  }

  List<Widget> _buildSuggestionPicker(
    MeetupState state,
    LocalizationState l10n, {
    required _SuggestionMode mode,
  }) {
    final counter = mode == _SuggestionMode.counter;
    final replacing = mode == _SuggestionMode.replace;
    if (state.suggesting) {
      return [
        const SizedBox(height: 18),
        Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(l10n.getString('meetupFindingPlaces'))),
          ],
        ),
      ];
    }

    if (state.suggestions.isEmpty) {
      return [
        const SizedBox(height: 14),
        Text(l10n.getString('meetupNoPlacesFound')),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => _loadSuggestions(mode),
          icon: const Icon(Icons.refresh),
          label: Text(l10n.getString('meetupRetry')),
        ),
        if (replacing)
          TextButton.icon(
            onPressed: () => _openCustomPlace(_SuggestionMode.replace),
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: Text(l10n.getString('meetupCustomPlace')),
          ),
      ];
    }

    return [
      const SizedBox(height: 16),
      Text(
        l10n.getString(
          counter ? 'meetupCounterRoundTitle' : 'meetupSuggestionRoundTitle',
        ),
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 4),
      Text(
        l10n.getString(
          counter ? 'meetupCounterRoundBody' : 'meetupSuggestionRoundBody',
        ),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 8),
      for (var i = 0; i < state.suggestions.length; i++)
        _SuggestionTile(
          suggestion: state.suggestions[i],
          l10n: l10n,
          checked: _selectedSuggestions.contains(i),
          onChanged: (value) => setState(() {
            if (value) {
              _selectedSuggestions.add(i);
            } else {
              _selectedSuggestions.remove(i);
            }
          }),
          onOpenMap:
              state.suggestions[i].hasCoordinates ||
                  state.suggestions[i].hasPlaceId
              ? () => _openPlaceOnMap(
                  label: state.suggestions[i].label,
                  placeId: state.suggestions[i].placeId,
                  latitude: state.suggestions[i].latitude,
                  longitude: state.suggestions[i].longitude,
                )
              : null,
        ),
      if (state.suggestionPool.isNotEmpty)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _showOtherSuggestions,
            icon: const Icon(Icons.autorenew, size: 18),
            label: Text(l10n.getString('meetupShowOtherPlaces')),
          ),
        ),
      if (replacing)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _loadSuggestions(_SuggestionMode.replace),
            icon: const Icon(Icons.my_location, size: 18),
            label: Text(l10n.getString('meetupRefreshPlaces')),
          ),
        ),
      const SizedBox(height: 10),
      FilledButton.icon(
        onPressed: _selectedSuggestions.isEmpty
            ? null
            : () => _sendSelectedSuggestions(state.suggestions),
        icon: const Icon(Icons.send),
        label: Text(
          l10n.getString(
            counter
                ? 'meetupSuggestOtherPlaces'
                : replacing
                ? 'meetupChangeProposalSend'
                : 'meetupSendOptions',
          ),
        ),
      ),
      const SizedBox(height: 4),
      OutlinedButton.icon(
        onPressed: () => _openCustomPlace(mode),
        icon: const Icon(Icons.edit_location_alt_outlined),
        label: Text(l10n.getString('meetupCustomPlace')),
      ),
      const SizedBox(height: 4),
      Text(
        l10n.getString(_attributionKey(state.suggestionSource)),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      TextButton(
        onPressed: () => setState(() {
          _suggestionMode = null;
          _selectedSuggestions.clear();
        }),
        child: Text(l10n.getString('cancel')),
      ),
    ];
  }

  List<Widget> _buildProposal(
    MeetupState state,
    MeetupSession session,
    LocalizationState l10n,
  ) {
    final isEvent = session.isEvent;
    final landmarks = state.roundLandmarks;
    final waiting = state.isMyProposal;
    final selectedId = landmarks.any((item) => item.id == _selectedLandmarkId)
        ? _selectedLandmarkId
        : (landmarks.isNotEmpty ? landmarks.first.id : null);

    final titleKey = waiting
        ? (session.proposalRound > 1
              ? 'meetupCounterWaiting'
              : 'meetupWaitingForOther')
        : 'meetupBannerProposedByOther';

    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.getString(
                  titleKey,
                  params: {'name': widget.otherUserName},
                ),
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              if (isEvent)
                _PlaceCard(
                  icon: Icons.stadium_outlined,
                  label: l10n.getString('meetupEventZone'),
                  value: meetupZoneDisplay(session.venueZone ?? '', l10n),
                  subtitle: widget.eventName,
                )
              else
                for (final landmark in landmarks)
                  _LandmarkTile(
                    landmark: landmark,
                    l10n: l10n,
                    showDistance: landmark.proposerId == state.currentUserId,
                    selected: waiting ? null : landmark.id == selectedId,
                    onTap: waiting
                        ? null
                        : () =>
                              setState(() => _selectedLandmarkId = landmark.id),
                    onOpenMap: landmark.hasCoordinates || landmark.hasPlaceId
                        ? () => _openPlaceOnMap(
                            label: landmark.label,
                            placeId: landmark.placeId,
                            latitude: landmark.latitude,
                            longitude: landmark.longitude,
                          )
                        : null,
                  ),
              if (!waiting) ...[
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: isEvent || selectedId != null
                      ? () => _accept(isEvent ? null : selectedId)
                      : null,
                  icon: const Icon(Icons.check),
                  label: Text(l10n.getString('meetupChooseThisPlace')),
                ),
                if (state.canCounter) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: isEvent
                        ? _counterEventProposal
                        : () =>
                              _loadSuggestions(_SuggestionMode.counter),
                    icon: const Icon(Icons.edit_location_alt_outlined),
                    label: Text(l10n.getString('meetupSuggestOtherPlaces')),
                  ),
                  const SizedBox(height: 2),
                  TextButton.icon(
                    onPressed: () =>
                        _openCustomPlace(_SuggestionMode.counter),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: Text(l10n.getString('meetupCustomPlace')),
                  ),
                ],
              ],
              if (state.canReplaceProposal &&
                  _suggestionMode != _SuggestionMode.replace) ...[
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _loadSuggestions(
                      _SuggestionMode.replace,
                      restoreCacheFirst: true,
                    ),
                    icon: const Icon(Icons.edit_location_alt_outlined),
                    label: Text(l10n.getString('meetupChangeProposal')),
                  ),
                ),
              ],
              if (state.canReplaceProposal &&
                  _suggestionMode == _SuggestionMode.replace) ...[
                const Divider(height: 28),
                ..._buildSuggestionPicker(
                  state,
                  l10n,
                  mode: _SuggestionMode.replace,
                ),
              ],
              if (state.canCounter &&
                  _suggestionMode == _SuggestionMode.counter &&
                  !isEvent) ...[
                const Divider(height: 28),
                ..._buildSuggestionPicker(
                  state,
                  l10n,
                  mode: _SuggestionMode.counter,
                ),
              ],
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: () => _confirmEnd(found: false),
                icon: const Icon(Icons.close),
                label: Text(
                  l10n.getString(
                    waiting ? 'meetupCancelInvite' : 'meetupEndCancel',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      ..._buildCoordination(),
    ];
  }

  List<Widget> _buildActive(
    MeetupState state,
    MeetupSession session,
    LocalizationState l10n,
  ) {
    final chosen = state.chosenLandmark;
    final remaining = session.timeRemaining;
    final pending = state.pendingLandmark;

    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.getString('meetupActiveTitle'),
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Flexible(
                    child: Chip(
                      avatar: const Icon(Icons.timer_outlined, size: 16),
                      label: Text(
                        l10n.getString(
                          'meetupTimeLeft',
                          params: {'time': _formatDuration(remaining, l10n)},
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (session.isEvent)
                _PlaceCard(
                  icon: Icons.stadium_outlined,
                  label: l10n.getString('meetupEventZone'),
                  value: meetupZoneDisplay(session.venueZone ?? '', l10n),
                  subtitle: widget.eventName,
                )
              else if (chosen != null)
                _PlaceCard(
                  icon: _categoryIcon(chosen.category),
                  label: l10n.getString('meetupChosenPlace'),
                  value: chosen.label,
                  subtitle: _landmarkSubtitle(
                    chosen,
                    l10n,
                    showDistance: chosen.proposerId == state.currentUserId,
                  ),
                  trailing: chosen.hasCoordinates || chosen.hasPlaceId
                      ? TextButton.icon(
                          onPressed: () => _openPlaceOnMap(
                            label: chosen.label,
                            placeId: chosen.placeId,
                            latitude: chosen.latitude,
                            longitude: chosen.longitude,
                          ),
                          icon: const Icon(Icons.map_outlined, size: 18),
                          label: Text(l10n.getString('meetupOpenInMaps')),
                        )
                      : null,
                ),
              if (state.canRequestPlaceChange) ...[
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _openChangePlace,
                    icon: const Icon(Icons.swap_horiz),
                    label: Text(l10n.getString('meetupChangePlace')),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      if (state.hasPendingPlaceChange) ...[
        const SizedBox(height: 12),
        _buildPendingPlaceChange(state, pending, l10n),
      ],
      ..._buildCoordination(),
      const SizedBox(height: 18),
      Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: () => _confirmEnd(found: true),
              icon: const Icon(Icons.check_circle_outline),
              label: Text(l10n.getString('meetupFound')),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _confirmEnd(found: false),
              icon: const Icon(Icons.close),
              label: Text(l10n.getString('meetupEndCancel')),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      MeetupInfoBanner(
        icon: Icons.lock_outline,
        text: l10n.getString('meetupPrivacyNote'),
      ),
    ];
  }

  List<Widget> _buildCoordination() {
    // The tools live in the meet-up hub; this screen keeps the feed so
    // incoming waves, beacons and Spot me cards stay visible while the
    // global alert overlay is hidden behind this surface.
    return [
      const SizedBox(height: 12),
      MeetupCoordinationFeed(
        matchId: widget.matchId,
        otherUserId: widget.otherUserId,
        otherUserName: widget.otherUserName,
      ),
    ];
  }

  Widget _buildPendingPlaceChange(
    MeetupState state,
    MeetupLandmark? pending,
    LocalizationState l10n,
  ) {
    final mine = state.isMyPlaceChange;
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.getString(
                mine
                    ? 'meetupChangePlaceWaiting'
                    : 'meetupChangePlaceIncomingTitle',
                params: {'name': widget.otherUserName},
              ),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.getString('meetupChangePlacePendingLabel'),
              style: theme.textTheme.labelMedium,
            ),
            if (pending != null) ...[
              const SizedBox(height: 2),
              Text(
                pending.label,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                l10n.getString(_categoryKey(pending.category)),
                style: theme.textTheme.bodySmall,
              ),
              if (pending.hasCoordinates || pending.hasPlaceId)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: () => _openPlaceOnMap(
                      label: pending.label,
                      placeId: pending.placeId,
                      latitude: pending.latitude,
                      longitude: pending.longitude,
                    ),
                    icon: const Icon(Icons.map_outlined, size: 18),
                    label: Text(l10n.getString('meetupOpenInMaps')),
                  ),
                ),
            ],
            const SizedBox(height: 6),
            Text(
              l10n.getString(
                mine
                    ? 'meetupChangePlaceBody'
                    : 'meetupChangePlaceIncomingBody',
              ),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (mine)
              OutlinedButton.icon(
                onPressed: _withdrawPlaceChange,
                icon: const Icon(Icons.close),
                label: Text(l10n.getString('meetupChangePlaceWithdraw')),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: () => _resolvePlaceChange(accept: true),
                    icon: const Icon(Icons.check),
                    label: Text(l10n.getString('meetupChangePlaceAccept')),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _resolvePlaceChange(accept: false),
                    icon: const Icon(Icons.undo),
                    label: Text(l10n.getString('meetupChangePlaceKeep')),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  String _landmarkSubtitle(
    MeetupLandmark landmark,
    LocalizationState l10n, {
    required bool showDistance,
  }) {
    final parts = <String>[l10n.getString(_categoryKey(landmark.category))];
    // Distances are measured from the proposer's one-shot lookup, so they are
    // only meaningful to the user who proposed this landmark.
    if (showDistance && landmark.distanceMeters != null) {
      parts.add(_distanceLabel(landmark.distanceMeters!, l10n));
    }
    return parts.join(' · ');
  }
}

String _suggestionSubtitle(
  MeetupPlaceSuggestion suggestion,
  LocalizationState l10n,
) {
  final parts = <String>[l10n.getString(_categoryKey(suggestion.category))];
  if (suggestion.distanceMeters != null) {
    parts.add(_distanceLabel(suggestion.distanceMeters!, l10n));
  }
  if (suggestion.walkingMinutes != null) {
    parts.add(
      l10n.getString(
        'meetupWalkDuration',
        params: {
          'duration': formatDurationParts(
            l10n.getString,
            minutes: suggestion.walkingMinutes,
          ),
        },
      ),
    );
  }
  return parts.join(' · ');
}

String _distanceLabel(int meters, LocalizationState l10n) {
  return l10n.getString(
    'meetupDistanceAway',
    params: {'distance': formatDistance(meters.toDouble(), l10n)},
  );
}

String _formatDuration(Duration duration, LocalizationState l10n) {
  if (duration.inSeconds <= 0) {
    return l10n.getString('durationLessThanOneMinute');
  }
  return formatDurationParts(
    l10n.getString,
    hours: duration.inHours > 0 ? duration.inHours : null,
    minutes: duration.inMinutes > 0 ? duration.inMinutes % 60 : null,
    seconds: duration.inHours == 0 && duration.inMinutes == 0
        ? duration.inSeconds % 60
        : null,
  );
}

String _categoryKey(String category) {
  switch (category) {
    case 'park':
      return 'meetupCategoryPark';
    case 'square':
      return 'meetupCategorySquare';
    case 'landmark':
      return 'meetupCategoryLandmark';
    case 'supermarket':
      return 'meetupCategorySupermarket';
    case 'mall':
      return 'meetupCategoryMall';
    case 'fuel':
      return 'meetupCategoryFuel';
    case 'transit':
      return 'meetupCategoryTransit';
    case 'pharmacy':
      return 'meetupCategoryPharmacy';
    case 'attraction':
      return 'meetupCategoryAttraction';
    case 'library':
      return 'meetupCategoryLibrary';
    case 'custom':
      return 'meetupCategoryCustom';
    default:
      return 'meetupCategoryOther';
  }
}

/// Places content must be attributed to Google Maps, and the OpenStreetMap
/// path keeps its own line, so the picker cannot hardcode a single one.
String _attributionKey(String source) =>
    source == LandmarkSuggestionService.googleProvider
    ? 'meetupGoogleAttribution'
    : 'meetupOsmAttribution';

IconData _categoryIcon(String category) {
  switch (category) {
    case 'park':
      return Icons.park_outlined;
    case 'square':
      return Icons.account_balance_outlined;
    case 'landmark':
      return Icons.account_balance_outlined;
    case 'supermarket':
      return Icons.shopping_cart_outlined;
    case 'mall':
      return Icons.storefront_outlined;
    case 'fuel':
      return Icons.local_gas_station_outlined;
    case 'transit':
      return Icons.directions_transit_outlined;
    case 'pharmacy':
      return Icons.local_pharmacy_outlined;
    case 'attraction':
      return Icons.photo_camera_outlined;
    case 'library':
      return Icons.account_balance_outlined;
    case 'custom':
      return Icons.edit_location_alt_outlined;
    default:
      return Icons.place_outlined;
  }
}

class _CustomPlaceSheet extends ConsumerStatefulWidget {
  const _CustomPlaceSheet();

  @override
  ConsumerState<_CustomPlaceSheet> createState() => _CustomPlaceSheetState();
}

class _CustomPlaceSheetState extends ConsumerState<_CustomPlaceSheet> {
  final TextEditingController _controller = TextEditingController();
  bool _showEmptyError = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _showEmptyError = true);
      return;
    }
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.getString('meetupCustomPlaceTitle'),
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.getString('meetupCustomPlaceBody'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              maxLength: 120,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: l10n.getString('meetupCustomPlaceLabel'),
                hintText: l10n.getString('meetupCustomPlaceHint'),
                errorText: _showEmptyError
                    ? l10n.getString('meetupCustomPlaceInvalid')
                    : null,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) {
                if (_showEmptyError) setState(() => _showEmptyError = false);
              },
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _submit,
              child: Text(l10n.getString('meetupCustomPlaceAdd')),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChangePlaceSheet extends ConsumerStatefulWidget {
  final String matchId;

  const _ChangePlaceSheet({required this.matchId});

  @override
  ConsumerState<_ChangePlaceSheet> createState() => _ChangePlaceSheetState();
}

class _ChangePlaceSheetState extends ConsumerState<_ChangePlaceSheet> {
  final TextEditingController _custom = TextEditingController();
  bool _loading = false;
  bool _customMode = false;
  bool _customEmpty = false;
  bool _searched = false;
  String? _errorKey;
  int? _selected;
  List<MeetupPlaceSuggestion> _places = const [];
  String _source = 'osm';

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  Future<void> _findPlaces() async {
    setState(() {
      _loading = true;
      _errorKey = null;
    });
    final error = await ref
        .read(meetupProvider(widget.matchId).notifier)
        .loadSuggestions();
    if (!mounted) return;
    final snapshot = ref.read(meetupProvider(widget.matchId));
    final places = snapshot.suggestions;
    setState(() {
      _loading = false;
      _searched = true;
      _places = places;
      _source = snapshot.suggestionSource;
      _selected = places.isEmpty ? null : 0;
      _errorKey = error;
    });
  }

  void _showOtherPlaces() {
    ref.read(meetupProvider(widget.matchId).notifier).showMoreSuggestions();
    final places = ref.read(meetupProvider(widget.matchId)).suggestions;
    setState(() {
      _places = places;
      _selected = places.isEmpty ? null : 0;
    });
  }

  void _submitSelected() {
    final index = _selected;
    if (index == null || index < 0 || index >= _places.length) return;
    Navigator.of(context).pop(_places[index]);
  }

  void _submitCustom() {
    final text = _custom.text.trim();
    if (text.isEmpty) {
      setState(() => _customEmpty = true);
      return;
    }
    Navigator.of(context).pop(MeetupPlaceSuggestion.custom(label: text));
  }

  Future<void> _openMap(MeetupPlaceSuggestion place) async {
    await openGoogleMapsPlace(
      label: place.label,
      placeId: place.placeId,
      latitude: place.latitude,
      longitude: place.longitude,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final theme = Theme.of(context);
    final hasMore = ref
        .watch(meetupProvider(widget.matchId))
        .suggestionPool
        .isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.getString('meetupChangePlaceTitle'),
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.getString('meetupChangePlaceBody'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            if (_customMode) ...[
              TextField(
                controller: _custom,
                autofocus: true,
                maxLength: 120,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: l10n.getString('meetupCustomPlaceLabel'),
                  hintText: l10n.getString('meetupCustomPlaceHint'),
                  errorText: _customEmpty
                      ? l10n.getString('meetupCustomPlaceInvalid')
                      : null,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) {
                  if (_customEmpty) setState(() => _customEmpty = false);
                },
                onSubmitted: (_) => _submitCustom(),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _submitCustom,
                child: Text(l10n.getString('meetupChangePlacePropose')),
              ),
              TextButton(
                onPressed: () => setState(() => _customMode = false),
                child: Text(l10n.getString('cancel')),
              ),
            ] else if (_loading) ...[
              const Row(
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Expanded(child: Text('…')),
                ],
              ),
            ] else if (_places.isEmpty) ...[
              if (_searched) ...[
                if (_errorKey != null && _errorKey != 'meetupNoPlacesFound')
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      l10n.getString(_errorKey!),
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(l10n.getString('meetupNoPlacesFound')),
                  ),
              ],
              FilledButton.icon(
                onPressed: _findPlaces,
                icon: const Icon(Icons.location_searching),
                label: Text(l10n.getString('meetupSuggestPlaces')),
              ),
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: () => setState(() => _customMode = true),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: Text(l10n.getString('meetupCustomPlace')),
              ),
            ] else ...[
              for (var i = 0; i < _places.length; i++)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(_categoryIcon(_places[i].category)),
                  title: Text(_places[i].label),
                  subtitle: Text(_suggestionSubtitle(_places[i], l10n)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_places[i].hasCoordinates || _places[i].hasPlaceId)
                        _MapIconButton(
                          tooltip: l10n.getString('meetupOpenInMaps'),
                          onPressed: () => _openMap(_places[i]),
                        ),
                      Icon(
                        _selected == i
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: _selected == i
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outline,
                      ),
                    ],
                  ),
                  onTap: () => setState(() => _selected = i),
                ),
              if (hasMore)
                TextButton.icon(
                  onPressed: _showOtherPlaces,
                  icon: const Icon(Icons.autorenew, size: 18),
                  label: Text(l10n.getString('meetupShowOtherPlaces')),
                ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _selected == null ? null : _submitSelected,
                icon: const Icon(Icons.check),
                label: Text(l10n.getString('meetupChangePlacePropose')),
              ),
              TextButton.icon(
                onPressed: () => setState(() => _customMode = true),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: Text(l10n.getString('meetupCustomPlace')),
              ),
              Text(
                l10n.getString(_attributionKey(_source)),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ZonePickerSheet extends ConsumerStatefulWidget {
  final String? eventName;

  const _ZonePickerSheet({this.eventName});

  @override
  ConsumerState<_ZonePickerSheet> createState() => _ZonePickerSheetState();
}

class _ZonePickerSheetState extends ConsumerState<_ZonePickerSheet> {
  final _custom = TextEditingController();
  bool _customMode = false;

  static const _zones = <String, String>{
    'main_entrance': 'meetupEventZoneMainEntrance',
    'box_office': 'meetupEventZoneBoxOffice',
    'bar': 'meetupEventZoneBar',
    'cloakroom': 'meetupEventZoneCloakroom',
    'seating': 'meetupEventZoneSeating',
  };

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  void _submitCustom() {
    final text = _custom.text.trim();
    if (text.isEmpty) return;
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.getString('meetupEventZonesTitle'),
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.getString('meetupEventZonesBody'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (widget.eventName?.trim().isNotEmpty ?? false) ...[
              const SizedBox(height: 8),
              Text(widget.eventName!.trim(), style: theme.textTheme.titleSmall),
            ],
            const SizedBox(height: 16),
            if (!_customMode) ...[
              for (final entry in _zones.entries)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.place_outlined),
                  title: Text(l10n.getString(entry.value)),
                  onTap: () => Navigator.of(context).pop(entry.key),
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.edit_location_alt_outlined),
                title: Text(l10n.getString('meetupEventZoneCustom')),
                onTap: () => setState(() => _customMode = true),
              ),
            ] else ...[
              TextField(
                controller: _custom,
                autofocus: true,
                maxLength: 120,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: l10n.getString('meetupEventZoneCustom'),
                  hintText: l10n.getString('meetupEventZoneCustomHint'),
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _submitCustom(),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _submitCustom,
                child: Text(l10n.getString('meetupSendOptions')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PlaceCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String? subtitle;
  final Widget? trailing;

  const _PlaceCard({
    required this.icon,
    required this.label,
    required this.value,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, size: 28, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _LandmarkTile extends StatelessWidget {
  final MeetupLandmark landmark;
  final LocalizationState l10n;
  final bool showDistance;
  final bool? selected;
  final VoidCallback? onTap;
  final VoidCallback? onOpenMap;

  const _LandmarkTile({
    required this.landmark,
    required this.l10n,
    required this.showDistance,
    this.selected,
    this.onTap,
    this.onOpenMap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = <String>[l10n.getString(_categoryKey(landmark.category))];
    if (showDistance && landmark.distanceMeters != null) {
      parts.add(_distanceLabel(landmark.distanceMeters!, l10n));
    }
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected == true
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
            width: selected == true ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(_categoryIcon(landmark.category)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    landmark.label,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(parts.join(' · '), style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            if (onOpenMap != null || selected != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (onOpenMap != null)
                    _MapIconButton(
                      tooltip: l10n.getString('meetupOpenInMaps'),
                      onPressed: onOpenMap!,
                    ),
                  if (selected != null)
                    Icon(
                      selected!
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      color: selected!
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline,
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Opens the place in Google Maps before the user commits to it; the row's
/// own tap stays reserved for selecting or ticking the place.
class _MapIconButton extends StatelessWidget {
  final String tooltip;
  final VoidCallback onPressed;

  const _MapIconButton({required this.tooltip, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: const Icon(Icons.map_outlined, size: 20),
      color: Theme.of(context).colorScheme.primary,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
    );
  }
}

class _SuggestionTile extends StatelessWidget {
  final MeetupPlaceSuggestion suggestion;
  final LocalizationState l10n;
  final bool checked;
  final ValueChanged<bool> onChanged;
  final VoidCallback? onOpenMap;

  const _SuggestionTile({
    required this.suggestion,
    required this.l10n,
    required this.checked,
    required this.onChanged,
    this.onOpenMap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(_categoryIcon(suggestion.category)),
      title: Text(suggestion.label),
      subtitle: Text(_suggestionSubtitle(suggestion, l10n)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onOpenMap != null)
            _MapIconButton(
              tooltip: l10n.getString('meetupOpenInMaps'),
              onPressed: onOpenMap!,
            ),
          Checkbox(
            value: checked,
            onChanged: (value) => onChanged(value ?? false),
          ),
        ],
      ),
      onTap: () => onChanged(!checked),
    );
  }
}
