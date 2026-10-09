// lib/widgets/pinned_location_sheet.dart
//
// Shared pinned-home-base management sheet. One canonical surface for the
// three pin actions (start / extend / unpin), opened from every quick entry
// point — the Home dashboard cards, the map status banner, the map pin FAB,
// the persistent overlay banner's "Manage" action — and from the full card
// in Settings → Matching. Settings stays the deep manager; this sheet is
// the fast path that never requires navigation.
//
// Anti-fraud context: the server only ever pins the position it has
// observed from live GPS (see migration 20262087000000) — this sheet never
// sends coordinates of its own choosing, and server rejections surface as
// localized errors here.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/pinned_location_provider.dart';
import 'package:matchme/services/error_localization_service.dart';

/// Duration presets shared by the start and extend forms.
const List<Duration> kPinnedLocationDurations = <Duration>[
  Duration(hours: 24),
  Duration(days: 3),
  Duration(days: 7),
  Duration(days: 14),
];

String pinnedDurationLabel(Duration d, LocalizationState l10n) {
  if (d == const Duration(hours: 24)) return l10n.getString('pinnedLocationDur24h');
  if (d == const Duration(days: 3)) return l10n.getString('pinnedLocationDur3d');
  if (d == const Duration(days: 7)) return l10n.getString('pinnedLocationDur7d');
  return l10n.getString('pinnedLocationDur14d');
}

const Duration kMaximumPinnedLocationDuration = Duration(days: 14);

List<Duration> pinnedExtensionDurations(PinnedLocationState pin) {
  final createdAt = pin.createdAt;
  final expiresAt = pin.expiresAt;
  if (createdAt == null || expiresAt == null) return const [];
  final remainingAllowance = createdAt
      .add(kMaximumPinnedLocationDuration)
      .difference(expiresAt);
  return kPinnedLocationDurations
      .where((duration) => duration <= remainingAllowance)
      .toList(growable: false);
}

String pinnedFormatExpiry(DateTime exp) {
  final l = exp.toLocal();
  final min = l.minute.toString().padLeft(2, '0');
  return '${l.day}.${l.month}.${l.year} ${l.hour}:$min';
}

String pinnedRemainingText(Duration remaining, LocalizationState l10n) {
  if (remaining.inMinutes < 1) {
    return l10n.getString(
      'pinnedLocationRemaining',
      params: {
        'duration': l10n.getString(
          'pinnedLocationRemainingMinutes',
          params: {'count': '1'},
        ),
      },
    );
  }
  if (remaining.inHours < 1) {
    return l10n.getString(
      'pinnedLocationRemaining',
      params: {
        'duration': l10n.getString(
          'pinnedLocationRemainingMinutes',
          params: {'count': '${remaining.inMinutes}'},
        ),
      },
    );
  }
  if (remaining.inHours < 48) {
    return l10n.getString(
      'pinnedLocationRemaining',
      params: {
        'duration': l10n.getString(
          'pinnedLocationRemainingHours',
          params: {'count': '${remaining.inHours}'},
        ),
      },
    );
  }
  final days = (remaining.inHours / 24).ceil();
  return l10n.getString(
    'pinnedLocationRemaining',
    params: {
      'duration': l10n.getString(
        'pinnedLocationRemainingDays',
        params: {'count': '$days'},
      ),
    },
  );
}

/// Maps pin-specific server rejections (see migration 20262087000000) and
/// client-side position errors to localized keys; everything else falls
/// through to the generic error mapping.
String pinnedErrorText(Object e, LocalizationState l10n) {
  final msg = e.toString().toLowerCase();
  if (msg.contains('14 days total') ||
      msg.contains('user_locations_pinned_duration_max_14_days')) {
    return l10n.getString('pinnedLocationMaxDurationReached');
  }
  if (msg.contains('no observed location')) {
    return l10n.getString('pinNoObservedLocation');
  }
  if (msg.contains('observed location too old')) {
    return l10n.getString('pinLocationTooOld');
  }
  if (msg.contains('no cached position')) {
    return l10n.getString('pinnedLocationNoPosition');
  }
  return l10n.getString(ErrorLocalizationService.getErrorTranslationKey(e));
}

/// Opens the pinned-location management sheet. Pops with one of
/// 'pinned' | 'extended' | 'unpinned' on success so the caller can toast on
/// the underlying screen.
Future<void> showPinnedLocationSheet(
  BuildContext context,
  WidgetRef ref, {
  bool extensionOnly = false,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _PinnedLocationSheetBody(extensionOnly: extensionOnly),
  ).then((result) async {
    if (result == null || !context.mounted) return;
    final l10n = ref.read(localizationProvider);
    final pin = ref.read(pinnedLocationProvider);
    String? text;
    switch (result) {
      case 'pinned':
        final exp = pin.expiresAt;
        text = l10n.getString(
          'pinnedLocationPinned',
          params: {'date': exp == null ? '' : pinnedFormatExpiry(exp)},
        );
        break;
      case 'extended':
        final exp = pin.expiresAt;
        text = l10n.getString(
          'pinnedLocationExtended',
          params: {'date': exp == null ? '' : pinnedFormatExpiry(exp)},
        );
        break;
      case 'unpinned':
        text = l10n.getString('pinnedLocationUnpinned');
        break;
    }
    if (text == null || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), backgroundColor: Colors.green),
    );
  });
}

class _PinnedLocationSheetBody extends ConsumerStatefulWidget {
  const _PinnedLocationSheetBody({this.extensionOnly = false});

  final bool extensionOnly;

  @override
  ConsumerState<_PinnedLocationSheetBody> createState() =>
      _PinnedLocationSheetBodyState();
}

class _PinnedLocationSheetBodyState
    extends ConsumerState<_PinnedLocationSheetBody> {
  final TextEditingController _labelCtrl = TextEditingController();
  Duration _chosen = const Duration(days: 7);
  bool _extending = false;

  @override
  void initState() {
    super.initState();
    final pin = ref.read(pinnedLocationProvider);
    if (pin.isActive) {
      final durations = pinnedExtensionDurations(pin);
      if (durations.isNotEmpty) _chosen = durations.first;
    }
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    super.dispose();
  }

  void _pop(String result) => Navigator.of(context).pop(result);

  Future<void> _pin() async {
    try {
      await ref
          .read(pinnedLocationProvider.notifier)
          .pinCurrent(duration: _chosen, label: _labelCtrl.text);
      if (!mounted) return;
      _pop('pinned');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(pinnedErrorText(e, ref.read(localizationProvider))),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _extend() async {
    try {
      await ref
          .read(pinnedLocationProvider.notifier)
          .extend(extra: _chosen);
      if (!mounted) return;
      _pop('extended');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(pinnedErrorText(e, ref.read(localizationProvider))),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _unpin() async {
    try {
      await ref.read(pinnedLocationProvider.notifier).unpin();
      if (!mounted) return;
      _pop('unpinned');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(pinnedErrorText(e, ref.read(localizationProvider))),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Widget _durationPicker(
    LocalizationState l10n, {
    required List<Duration> durations,
  }) {
    return RadioGroup<Duration>(
      groupValue: _chosen,
      onChanged: (v) {
        if (v != null) setState(() => _chosen = v);
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: durations
            .map(
              (d) => RadioListTile<Duration>(
                value: d,
                title: Text(pinnedDurationLabel(d, l10n)),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
            )
            .toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final pin = ref.watch(pinnedLocationProvider);
    final colors = Theme.of(context).colorScheme;
    final remaining = pin.remainingFrom(DateTime.now().toUtc());
    final durations = pin.isActive
        ? pinnedExtensionDurations(pin)
        : kPinnedLocationDurations;

    if (widget.extensionOnly) {
      final hasSelectedDuration = durations.contains(_chosen);
      return Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.getString('pinnedLocationExtend'),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            if (durations.isEmpty)
              Text(l10n.getString('pinnedLocationMaxDurationReached'))
            else ...[
              Text(l10n.getString('pinnedLocationExtensionDuration')),
              _durationPicker(l10n, durations: durations),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: pin.isLoading || !hasSelectedDuration
                      ? null
                      : _extend,
                  child: Text(l10n.getString('pinnedLocationExtend')),
                ),
              ),
            ],
          ],
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        // Keep the form above the keyboard when the label field is focused.
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.push_pin_outlined, color: colors.secondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.getString('pinnedLocationSectionTitle'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            l10n.getString('pinnedLocationSectionDesc'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          if (!pin.initialized)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: CircularProgressIndicator(),
              ),
            )
          else if (!pin.isActive) ...[
            TextField(
              controller: _labelCtrl,
              decoration: InputDecoration(
                hintText: l10n.getString('pinnedLocationLabelHint'),
              ),
            ),
            const SizedBox(height: 8),
            Text(l10n.getString('pinnedLocationDuration')),
            _durationPicker(l10n, durations: kPinnedLocationDurations),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: pin.isLoading ? null : _pin,
                icon: const Icon(Icons.push_pin_outlined),
                label: Text(l10n.getString('pinnedLocationPinAction')),
              ),
            ),
          ] else ...[
            if (remaining != null && !remaining.isNegative)
              Align(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    child: Text(
                      pinnedRemainingText(remaining, l10n),
                      style: const TextStyle(
                        color: Colors.green,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Text(
              l10n.getString(
                'pinnedLocationActiveUntil',
                params: {
                  'label': (pin.label == null || pin.label!.isEmpty)
                      ? ''
                      : ' "${pin.label}"',
                  'date': pin.expiresAt == null
                      ? ''
                      : pinnedFormatExpiry(pin.expiresAt!),
                },
              ),
              style: TextStyle(fontSize: 13, color: colors.onSurface),
            ),
            const SizedBox(height: 12),
            if (pin.isLoading) const LinearProgressIndicator(),
            if (_extending) ...[
              if (durations.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(l10n.getString('pinnedLocationMaxDurationReached')),
                )
              else ...[
                Text(l10n.getString('pinnedLocationExtensionDuration')),
                _durationPicker(l10n, durations: durations),
              ],
            ],
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed:
                        pin.isLoading ||
                            (_extending &&
                                (durations.isEmpty ||
                                    !durations.contains(_chosen)))
                        ? null
                        : () {
                            if (_extending) {
                              _extend();
                            } else {
                              setState(() => _extending = true);
                            }
                          },
                    child: Text(l10n.getString('pinnedLocationExtend')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextButton(
                    onPressed: pin.isLoading ? null : _unpin,
                    child: Text(l10n.getString('pinnedLocationUnpin')),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
