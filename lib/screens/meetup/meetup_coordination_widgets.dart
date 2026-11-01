// Shared widgets for the match-scoped coordination tools (signal, beacon,
// Spot me). Used by the meet-up hub and by the coordination feed inside the
// plan screen, so the tools stay in one place.
//
// These widgets never request or use a location. The only network calls are
// the match-keyed meet-up RPCs and the private spot-photo bucket.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/meetup_models.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/meetup_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/screens/meetup/beacon_screen.dart';
import 'package:matchme/screens/meetup/meetup_outfit_figure.dart';
import 'package:matchme/screens/meetup/meetup_spot_composer.dart';
import 'package:matchme/services/meetup_service.dart';
import 'package:matchme/theme/app_theme_tokens.dart';
import 'package:matchme/utils/meetup_display.dart';
import 'package:matchme/utils/localized_duration.dart';
import 'package:matchme/widgets/safe_text.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

IconData meetupGestureIcon(String gesture) {
  switch (gesture) {
    case kMeetupGestureHandsUp:
      return Icons.pan_tool_outlined;
    case kMeetupGestureJumping:
      return Icons.accessibility_new;
    case kMeetupGestureArmsWide:
      return Icons.open_in_full;
    case kMeetupGestureWave:
    default:
      return Icons.waving_hand_outlined;
  }
}

/// Neutral inline note (privacy, safety, offline). Shared so both surfaces
/// look the same.
class MeetupInfoBanner extends StatelessWidget {
  final IconData icon;
  final String text;

  const MeetupInfoBanner({super.key, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: colors.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class MeetupGesturePickerSheet extends ConsumerWidget {
  const MeetupGesturePickerSheet({super.key});

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
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.getString('meetupGestureSheetTitle'),
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.getString('meetupGestureSheetBody'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            for (final gesture in _gestures)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(meetupGestureIcon(gesture)),
                title: Text(meetupGestureDisplay(gesture, l10n)),
                onTap: () => Navigator.of(context).pop(gesture),
              ),
          ],
        ),
      ),
    );
  }
}

Future<void> showMeetupGesturePicker(
  BuildContext context,
  WidgetRef ref,
  String matchId,
) async {
  final gesture = await showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    builder: (_) => const MeetupGesturePickerSheet(),
  );
  if (gesture == null) return;

  final error = await ref
      .read(meetupProvider(matchId).notifier)
      .sendGesture(gesture);
  if (!context.mounted) return;

  final l10n = ref.read(localizationProvider);
  final message = error != null
      ? l10n.getString(error)
      : l10n.getString(
          'meetupGestureSent',
          params: {'gesture': meetupGestureDisplay(gesture, l10n)},
        );
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

class MeetupIncomingSignalCard extends StatelessWidget {
  final String gesture;
  final String otherUserName;
  final LocalizationState l10n;
  final VoidCallback onReply;
  final VoidCallback onDismiss;

  const MeetupIncomingSignalCard({
    super.key,
    required this.gesture,
    required this.otherUserName,
    required this.l10n,
    required this.onReply,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(meetupGestureIcon(gesture), size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.getString(
                      'meetupGestureIncomingTitle',
                      params: {
                        'name': otherUserName,
                        'gesture': meetupGestureDisplay(gesture, l10n),
                      },
                    ),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(l10n.getString('meetupGestureIncomingBody')),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: onReply,
                    child: Text(l10n.getString('meetupSignalBack')),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: l10n.getString('meetupClose'),
              visualDensity: VisualDensity.compact,
              onPressed: onDismiss,
              icon: const Icon(Icons.close, size: 20),
            ),
          ],
        ),
      ),
    );
  }
}

/// The signal you sent, kept on screen exactly as long as the other device can
/// still see it. Sending a signal used to leave only a fleeting banner, so the
/// hub looked unchanged after it and there was no way to tell whether the
/// other person had been signaled. Both screens that host this feed rebuild on
/// a one-second ticker, so the countdown needs no timer of its own.
class MeetupOutgoingSignalCard extends StatelessWidget {
  final MeetupSignal signal;
  final String otherUserName;
  final LocalizationState l10n;
  final VoidCallback onDismiss;

  const MeetupOutgoingSignalCard({
    super.key,
    required this.signal,
    required this.otherUserName,
    required this.l10n,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    if (signal.isExpired) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final accent = AppThemeTokens.accentInk(
      Colors.amber.shade700,
      theme.brightness,
    );
    final gesture = meetupSignalGesture(signal);

    return Card(
      color: AppThemeTokens.accentSurface(accent, theme.brightness),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(meetupGestureIcon(gesture), size: 28, color: accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.getString(
                      'meetupSignalOutgoingKicker',
                      params: {'name': otherUserName},
                    ),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  SafeText(
                    meetupGestureDisplay(gesture, l10n),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: accent,
                    ),
                  ),
                  const SizedBox(height: 2),
                  SafeText(
                    l10n.getString(
                      'meetupSignalOutgoingVisible',
                      params: {'time': _countdown(l10n)},
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                  _ExpiryTrack(signal: signal, accent: accent),
                ],
              ),
            ),
            IconButton(
              tooltip: l10n.getString('meetupClose'),
              visualDensity: VisualDensity.compact,
              onPressed: onDismiss,
              icon: const Icon(Icons.close, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  /// "for another 42 seconds". Rounds up so the line never reads "0 seconds"
  /// while the signal is still live, and names minutes only for a whole one.
  String _countdown(LocalizationState l10n) {
    final seconds = (signal.timeRemaining.inMilliseconds / 1000).ceil();
    final duration = seconds >= 60
        ? formatDurationParts(l10n.getString, minutes: seconds ~/ 60)
        : formatDurationParts(l10n.getString, seconds: seconds);
    if (duration.isEmpty) return '';
    return l10n.getString(
      'locationShareCountdownRemaining',
      params: {'duration': duration},
    );
  }
}

/// How much of the signal's life is left. A plain sized box rather than a
/// progress indicator: the parent's one-second rebuild drives it, so no
/// implicit animation is wanted.
class _ExpiryTrack extends StatelessWidget {
  final MeetupSignal signal;
  final Color accent;

  const _ExpiryTrack({required this.signal, required this.accent});

  @override
  Widget build(BuildContext context) {
    final total = signal.expiresAt.difference(signal.createdAt).inMilliseconds;
    final left = signal.timeRemaining.inMilliseconds.clamp(0, total);
    final fraction = total <= 0 ? 0.0 : left / total;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LayoutBuilder(
          builder: (context, constraints) => Stack(
            children: [
              Container(
                height: 3,
                color: accent.withValues(alpha: 0.22),
              ),
              SizedBox(
                width: constraints.maxWidth * fraction,
                child: Container(height: 3, color: accent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MeetupIncomingBeaconCard extends StatelessWidget {
  final String beaconSeed;
  final String otherUserName;
  final LocalizationState l10n;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  const MeetupIncomingBeaconCard({
    super.key,
    required this.beaconSeed,
    required this.otherUserName,
    required this.l10n,
    required this.onOpen,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              MeetupBeaconShape(
                sessionId: beaconSeed,
                size: 54,
                animate: false,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.getString(
                        'meetupBeaconIncomingTitle',
                        params: {'name': otherUserName},
                      ),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(l10n.getString('meetupBeaconIncomingBody')),
                  ],
                ),
              ),
              IconButton(
                tooltip: l10n.getString('meetupClose'),
                onPressed: onDismiss,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A Spot me card counts as new for its first half hour.
bool meetupSpotIsNew(DateTime createdAt, {DateTime? now}) {
  final elapsed = (now ?? DateTime.now().toUtc()).difference(createdAt.toUtc());
  return elapsed < const Duration(minutes: 30);
}

/// "just now", "2 minutes ago", "1 hour and 23 minutes ago".
String meetupSpotAgeLabel(
  DateTime createdAt,
  LocalizationState l10n, {
  DateTime? now,
}) {
  final elapsed = (now ?? DateTime.now().toUtc()).difference(createdAt.toUtc());
  final minutes = elapsed.inMinutes;
  if (minutes < 1) return l10n.getString('meetupSpotMeJustNow');
  return l10n.getString(
    'meetupSpotMeAgo',
    params: {
      'duration': formatDurationParts(
        l10n.getString,
        hours: minutes ~/ 60 > 0 ? minutes ~/ 60 : null,
        minutes: minutes % 60 > 0 ? minutes % 60 : null,
      ),
    },
  );
}

class _SpotOutfitRow {
  final String label;
  final String value;
  final String? color;

  const _SpotOutfitRow({
    required this.label,
    required this.value,
    required this.color,
  });
}

List<_SpotOutfitRow> _spotOutfitRows(
  MeetupOutfitSpec outfit,
  LocalizationState l10n,
) {
  final rows = <_SpotOutfitRow>[];

  void add(String labelKey, String? type, String? color) {
    if (labelKey == 'meetupOutfitPants' && !outfit.showsPants) return;
    if (type == null && color == null) return;
    final typeLabel = type == null
        ? ''
        : l10n.getString(meetupOutfitLabelKey(type));
    final colorLabel = color == null
        ? ''
        : meetupOutfitColorDisplay(color, l10n);
    final value = typeLabel.isNotEmpty && colorLabel.isNotEmpty
        ? '$typeLabel, $colorLabel'
        : typeLabel.isNotEmpty
        ? typeLabel
        : colorLabel;
    if (value.isEmpty) return;
    rows.add(
      _SpotOutfitRow(
        label: l10n.getString(labelKey),
        value: value,
        color: color,
      ),
    );
  }

  add('meetupOutfitShirt', outfit.shirt, outfit.shirtColor);
  add('meetupOutfitPants', outfit.pants, outfit.pantsColor);
  add('meetupOutfitShoes', outfit.shoes, outfit.shoesColor);
  return rows;
}

/// Splits "{name} shared a spot card" so the name can be bold and isolated
/// from the sentence direction. FSI/PDI keep an RTL name from dragging an
/// English sentence right-to-left (and the reverse).
List<InlineSpan> _spotTitleSpans(String title, String name) {
  final isolated = '\u2068$name\u2069';
  final start = title.indexOf(isolated);
  if (start < 0) return <InlineSpan>[TextSpan(text: title)];
  return <InlineSpan>[
    if (start > 0) TextSpan(text: title.substring(0, start)),
    TextSpan(
      text: isolated,
      style: const TextStyle(fontWeight: FontWeight.w800),
    ),
    if (start + isolated.length < title.length)
      TextSpan(text: title.substring(start + isolated.length)),
  ];
}

Future<void> _hideSpotCard(
  BuildContext context,
  WidgetRef ref, {
  required String matchId,
  required String cardId,
  required String otherUserName,
}) async {
  final l10n = ref.read(localizationProvider);
  final error = await ref
      .read(meetupProvider(matchId).notifier)
      .hideSpot(cardId);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        l10n.getString(
          error ?? 'meetupSpotMeHidden',
          params: {'name': otherUserName},
        ),
      ),
    ),
  );
}

Future<void> _reportSpotCard(
  BuildContext context,
  WidgetRef ref, {
  required String matchId,
  required String cardId,
  required String otherUserId,
}) async {
  final l10n = ref.read(localizationProvider);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.getString('meetupSpotMeReportConfirm')),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.getString('cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.getString('meetupSpotMeReport')),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    await Supabase.instance.client.rpc(
      'report_user',
      params: {
        'p_reported_user_id': otherUserId,
        'p_match_id': matchId,
        'p_reason': 'inappropriate_spot_card',
      },
    );
    await ref.read(meetupProvider(matchId).notifier).hideSpot(cardId);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.getString('meetupSpotMeReported'))),
    );
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.getString('meetupActionFailed'))),
    );
  }
}

// The photo scrim and pink accents are fixed across themes; only the card
// surface behind them follows the theme.
const LinearGradient _kSpotPhotoScrim = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Color(0x4A0F172A), Color(0x000F172A), Color(0xAB0F172A)],
  stops: [0, 0.32, 1],
);

/// Incoming Spot me card: photo first when the sender shared a selfie,
/// figure first when they did not.
class MeetupIncomingSpotCard extends ConsumerStatefulWidget {
  final MeetupSpotCard card;
  final String matchId;
  final String otherUserId;
  final String otherUserName;

  const MeetupIncomingSpotCard({
    super.key,
    required this.card,
    required this.matchId,
    required this.otherUserId,
    required this.otherUserName,
  });

  @override
  ConsumerState<MeetupIncomingSpotCard> createState() =>
      _MeetupIncomingSpotCardState();
}

class _MeetupIncomingSpotCardState
    extends ConsumerState<MeetupIncomingSpotCard> {
  Uint8List? _photoBytes;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    // Keeps both the age label and the 30-minute NEW pill honest while the
    // card sits on screen and no database event arrives.
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  // See MeetupOwnSpotCardTile: a tear-off keeps the callback identity stable,
  // otherwise SignedImage re-notifies on every frame.
  void _handlePhotoBytes(Uint8List? bytes) {
    if (!mounted) return;
    setState(() => _photoBytes = bytes);
  }

  void _openPhoto() {
    final bytes = _photoBytes;
    if (bytes == null) return;
    showMeetupSpotPhoto(context, bytes: bytes);
  }

  Future<void> _hide() => _hideSpotCard(
    context,
    ref,
    matchId: widget.matchId,
    cardId: widget.card.id,
    otherUserName: widget.otherUserName,
  );

  Future<void> _report() => _reportSpotCard(
    context,
    ref,
    matchId: widget.matchId,
    cardId: widget.card.id,
    otherUserId: widget.otherUserId,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;

    final profile = ref
        .watch(otherUserProfileProvider(widget.otherUserId))
        .asData
        ?.value;
    final gender = meetupOutfitGenderFromProfile(profile?.gender);
    final outfit = MeetupOutfitSpec.fromMap(widget.card.outfit);
    final rows = _spotOutfitRows(outfit, l10n);
    final hasOutfit = rows.isNotEmpty;
    final note = widget.card.note?.trim() ?? '';
    final hasPhoto = widget.card.storagePath.trim().isNotEmpty;
    final isNew = meetupSpotIsNew(widget.card.createdAt);

    final spotFill = dark ? Colors.pink.shade300 : Colors.pink.shade600;
    final spotInk = AppThemeTokens.accentInk(
      Colors.pink.shade700,
      theme.brightness,
    );
    final onSpotFill = dark ? const Color(0xFF2A1020) : Colors.white;

    final title = l10n.getString(
      'meetupSpotMeIncomingTitle',
      params: {'name': '\u2068${widget.otherUserName}\u2069'},
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? const [Color(0xFF2A1020), Color(0xFF0F172A)]
              : const [Color(0xFFFDF2F8), Colors.white],
          stops: const [0, 0.64],
        ),
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: spotFill.withValues(alpha: dark ? 0.34 : 0.26),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasPhoto)
            _buildPhotoHero(
              l10n: l10n,
              title: title,
              isNew: isNew,
              spotFill: spotFill,
              onSpotFill: onSpotFill,
            )
          else ...[
            _buildHeader(
              l10n: l10n,
              theme: theme,
              isNew: isNew,
              spotInk: spotInk,
              spotFill: spotFill,
              onSpotFill: onSpotFill,
            ),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(14, 9, 14, 0),
              child: Text.rich(
                TextSpan(
                  children: _spotTitleSpans(title, widget.otherUserName),
                ),
                softWrap: true,
                overflow: TextOverflow.visible,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontSize: 18.5,
                  height: 1.24,
                  letterSpacing: -0.2,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface,
                ),
              ),
            ),
          ],
          if (hasOutfit) ...[
            _buildWearingLabel(l10n, theme),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(14, 9, 14, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MeetupOutfitFigureStage(
                    outfit: outfit,
                    gender: gender,
                    width: hasPhoto ? 96 : 112,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final row in rows) _buildRow(row, theme),
                        if (note.isNotEmpty) _buildNote(note, theme, spotFill),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            // Without outfit values the photo already shows what they wear,
            // so an empty figure would only restate missing data.
            if (!hasPhoto)
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(14, 9, 14, 0),
                child: SafeText(
                  l10n.getString('meetupSpotMeNoOutfit'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    height: 1.4,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            if (note.isNotEmpty)
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(14, 9, 14, 0),
                child: _buildNote(note, theme, spotFill),
              ),
          ],
          _buildActions(l10n, theme, hasPhoto: hasPhoto, spotFill: spotFill),
        ],
      ),
    );
  }

  Widget _buildPhotoHero({
    required LocalizationState l10n,
    required String title,
    required bool isNew,
    required Color spotFill,
    required Color onSpotFill,
  }) {
    return SizedBox(
      height: 188,
      child: Stack(
        fit: StackFit.expand,
        children: [
          MouseRegion(
            cursor: _photoBytes == null
                ? MouseCursor.defer
                : SystemMouseCursors.click,
            child: GestureDetector(
              onTap: _photoBytes == null ? null : _openPhoto,
              child: SignedImage(
                key: ValueKey('spot-photo-${widget.card.id}'),
                source: widget.card.storagePath,
                bucket: MeetupService.spotBucket,
                fit: BoxFit.cover,
                // Fixed TTL skips the app-config lookup and matches the
                // 10-minute window the spot flow always used.
                ttlSeconds: 600,
                onBytesLoaded: _handlePhotoBytes,
              ),
            ),
          ),
          const IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: _kSpotPhotoScrim),
            ),
          ),
          PositionedDirectional(
            start: 11,
            end: 11,
            top: 10,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _SpotKicker(
                        label: l10n.getString('meetupSpotMe'),
                        color: Colors.white,
                        background: const Color(0x610F172A),
                      ),
                      if (isNew)
                        _SpotNewPill(
                          label: l10n.getString('meetupSpotMeNew'),
                          background: spotFill,
                          foreground: onSpotFill,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: _SpotAgeText(
                      createdAt: widget.card.createdAt,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xF0FFFFFF),
                        shadows: [
                          Shadow(
                            color: Color(0x80000000),
                            blurRadius: 4,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          PositionedDirectional(
            start: 13,
            end: 56,
            bottom: 11,
            child: Text.rich(
              TextSpan(children: _spotTitleSpans(title, widget.otherUserName)),
              softWrap: true,
              overflow: TextOverflow.visible,
              style: const TextStyle(
                fontSize: 17,
                height: 1.25,
                letterSpacing: -0.1,
                fontWeight: FontWeight.w600,
                color: Colors.white,
                shadows: [
                  Shadow(
                    color: Color(0x59000000),
                    blurRadius: 10,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
            ),
          ),
          PositionedDirectional(
            end: 10,
            bottom: 10,
            child: Tooltip(
              message: l10n.getString('meetupSpotMeViewPhoto'),
              child: Material(
                color: Colors.white.withValues(alpha: 0.22),
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: _photoBytes == null ? null : _openPhoto,
                  child: const SizedBox(
                    width: 34,
                    height: 34,
                    child: Icon(
                      Icons.open_in_full,
                      size: 15,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader({
    required LocalizationState l10n,
    required ThemeData theme,
    required bool isNew,
    required Color spotInk,
    required Color spotFill,
    required Color onSpotFill,
  }) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(14, 13, 14, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _SpotKicker(
                  label: l10n.getString('meetupSpotMe'),
                  color: spotInk,
                ),
                if (isNew)
                  _SpotNewPill(
                    label: l10n.getString('meetupSpotMeNew'),
                    background: spotFill,
                    foreground: onSpotFill,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: _SpotAgeText(
                createdAt: widget.card.createdAt,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWearingLabel(LocalizationState l10n, ThemeData theme) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 14, 0),
      child: Text(
        l10n.getString('meetupSpotMeWearing').toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 1,
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
        ),
      ),
    );
  }

  Widget _buildRow(_SpotOutfitRow row, ThemeData theme) {
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: MeetupColorSwatch(color: row.color),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.label,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                SafeText(
                  row.value,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNote(String note, ThemeData theme, Color spotFill) {
    final dark = theme.brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(top: 1),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: dark ? 0.35 : 0.55,
        ),
        borderRadius: BorderRadius.circular(6),
        border: BorderDirectional(
          start: BorderSide(
            color: spotFill.withValues(alpha: dark ? 0.4 : 0.26),
            width: 2,
          ),
        ),
      ),
      child: SafeText(
        '\u201C$note\u201D',
        style: TextStyle(
          fontSize: 13,
          height: 1.45,
          fontStyle: FontStyle.italic,
          color: theme.colorScheme.onSurface,
        ),
      ),
    );
  }

  Widget _buildActions(
    LocalizationState l10n,
    ThemeData theme, {
    required bool hasPhoto,
    required Color spotFill,
  }) {
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final spotInk = AppThemeTokens.accentInk(
      Colors.pink.shade700,
      theme.brightness,
    );
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(14, 8, 11, 11),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: hasPhoto
                  ? FilledButton.icon(
                      onPressed: _photoBytes == null ? null : _openPhoto,
                      icon: const Icon(Icons.photo_outlined, size: 15),
                      label: ShrinkText(
                        l10n.getString('meetupSpotMeViewPhoto'),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: spotFill.withValues(
                          alpha: dark ? 0.18 : 0.10,
                        ),
                        foregroundColor: spotInk,
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 7,
                        ),
                        minimumSize: const Size(0, 34),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.hide_image_outlined,
                          size: 14,
                          color: colors.onSurfaceVariant.withValues(alpha: 0.8),
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: SafeText(
                            l10n.getString('meetupSpotMeNoPhotoShared'),
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.onSurfaceVariant.withValues(
                                alpha: 0.85,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          const SizedBox(width: 4),
          _spotActionButton(
            icon: Icons.visibility_off_outlined,
            label: l10n.getString('meetupSpotMeHide'),
            onPressed: _hide,
            foreground: colors.onSurfaceVariant,
          ),
          _spotActionButton(
            icon: Icons.flag_outlined,
            label: l10n.getString('meetupSpotMeReport'),
            onPressed: _report,
            foreground: colors.onSurfaceVariant,
          ),
        ],
      ),
    );
  }

  Widget _spotActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    required Color foreground,
  }) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 15),
      label: ShrinkText(
        label,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
      ),
      style: TextButton.styleFrom(
        foregroundColor: foreground,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        minimumSize: const Size(0, 34),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

class _SpotKicker extends StatelessWidget {
  final String label;
  final Color color;
  final Color? background;

  const _SpotKicker({
    required this.label,
    required this.color,
    this.background,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: background == null
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: background == null
          ? null
          : BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(999),
            ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.photo_camera_front_outlined, size: 13, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: ShrinkText(
              label.toUpperCase(),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SpotNewPill extends StatelessWidget {
  final String label;
  final Color background;
  final Color foreground;

  const _SpotNewPill({
    required this.label,
    required this.background,
    required this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: ShrinkText(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
          color: foreground,
        ),
      ),
    );
  }
}

/// The age label. It has no clock of its own: the incoming card rebuilds on
/// a 30-second timer, which is also when the NEW pill expires.
class _SpotAgeText extends ConsumerWidget {
  final DateTime createdAt;
  final TextStyle? style;

  const _SpotAgeText({required this.createdAt, this.style});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ShrinkText(
      meetupSpotAgeLabel(createdAt, ref.watch(localizationProvider)),
      style: style,
      maxLines: 1,
      minFontSize: 8,
    );
  }
}

/// The sender's own active card. It stays compact and sits below incoming
/// cards, so the top of the feed belongs to what the other person shared.
class MeetupOwnSpotCardTile extends ConsumerStatefulWidget {
  final MeetupSpotCard card;
  final String matchId;

  const MeetupOwnSpotCardTile({
    super.key,
    required this.card,
    required this.matchId,
  });

  @override
  ConsumerState<MeetupOwnSpotCardTile> createState() =>
      _MeetupOwnSpotCardTileState();
}

class _MeetupOwnSpotCardTileState extends ConsumerState<MeetupOwnSpotCardTile> {
  Uint8List? _photoBytes;

  // Passed to SignedImage as a method tear-off: its notification dedupe
  // compares callback identity, and a fresh lambda per build would defeat
  // the guard and re-notify every frame (endless rebuild loop). Dart
  // tear-offs of the same method are == across evaluations.
  void _handlePhotoBytes(Uint8List? bytes) {
    if (!mounted) return;
    setState(() => _photoBytes = bytes);
  }

  Future<void> _delete() async {
    final l10n = ref.read(localizationProvider);
    final error = await ref
        .read(meetupProvider(widget.matchId).notifier)
        .deleteSpot(widget.card.id);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.getString(error))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final theme = Theme.of(context);
    final outfitLines = _outfitLines(l10n);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.person, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l10n.getString('meetupSpotMeFromYou'),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (widget.card.kind == 'meeting_point')
                  Icon(
                    Icons.place_outlined,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
              ],
            ),
            if (widget.card.storagePath.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: MouseRegion(
                  cursor: _photoBytes == null
                      ? MouseCursor.defer
                      : SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: _photoBytes == null
                        ? null
                        : () =>
                              showMeetupSpotPhoto(context, bytes: _photoBytes),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 320),
                        // SignedImage (the app's standard photo pipeline)
                        // instead of a raw Image.network: it retries, shows
                        // a spinner while loading and an error icon instead
                        // of failing silently, and caches the bytes so the
                        // photo survives relaunches.
                        child: SignedImage(
                          key: ValueKey('spot-photo-${widget.card.id}'),
                          source: widget.card.storagePath,
                          bucket: MeetupService.spotBucket,
                          fit: BoxFit.contain,
                          // Fixed TTL skips the app-config lookup inside
                          // resolveImageRequest (a potentially slow DB read
                          // on degraded networks) and matches the 10-minute
                          // window the spot flow always used.
                          ttlSeconds: 600,
                          onBytesLoaded: _handlePhotoBytes,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            if (outfitLines.isNotEmpty) ...[
              const SizedBox(height: 10),
              for (final line in outfitLines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(line, style: theme.textTheme.bodyMedium),
                ),
            ],
            if (widget.card.note?.trim().isNotEmpty ?? false) ...[
              const SizedBox(height: 8),
              Text(
                widget.card.note!.trim(),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
            const SizedBox(height: 6),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                onPressed: _delete,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: Text(l10n.getString('meetupSpotMeDelete')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<String> _outfitLines(LocalizationState l10n) {
    final outfit = widget.card.outfit;
    final lines = <String>[];
    void add(String labelKey, String typeKey, String colorKey) {
      final type = outfit[typeKey]?.toString();
      final color = outfit[colorKey]?.toString().trim();
      if ((type == null || type.isEmpty) && (color == null || color.isEmpty)) {
        return;
      }
      final parts = <String>[
        if (type != null && type.isNotEmpty)
          l10n.getString(meetupOutfitLabelKey(type)),
        if (color != null && color.isNotEmpty)
          meetupOutfitColorDisplay(color, l10n),
      ];
      lines.add('${l10n.getString(labelKey)}: ${parts.join(', ')}');
    }

    add('meetupOutfitShirt', 'shirt', 'shirt_color');
    add('meetupOutfitPants', 'pants', 'pants_color');
    add('meetupOutfitShoes', 'shoes', 'shoes_color');
    return lines;
  }
}

/// Incoming gesture, beacon and Spot me cards, plus the signal you sent.
/// Renders nothing when there is
/// nothing to show, so it can sit at the end of any screen.
class MeetupCoordinationFeed extends ConsumerWidget {
  final String matchId;
  final String otherUserId;
  final String otherUserName;

  const MeetupCoordinationFeed({
    super.key,
    required this.matchId,
    required this.otherUserId,
    required this.otherUserName,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(meetupProvider(matchId));
    final l10n = ref.watch(localizationProvider);
    final children = <Widget>[];
    final beaconSeed = state.session?.id ?? matchId;

    final signal = state.incomingWave;
    if (signal != null) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: MeetupIncomingSignalCard(
            gesture: meetupSignalGesture(signal),
            otherUserName: otherUserName,
            l10n: l10n,
            onReply: () => showMeetupGesturePicker(context, ref, matchId),
            onDismiss: () => ref
                .read(meetupProvider(matchId).notifier)
                .dismissSignal(signal.id),
          ),
        ),
      );
    }

    final outgoing = state.myWave;
    if (outgoing != null) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: MeetupOutgoingSignalCard(
            signal: outgoing,
            otherUserName: otherUserName,
            l10n: l10n,
            onDismiss: () => ref
                .read(meetupProvider(matchId).notifier)
                .dismissSignal(outgoing.id),
          ),
        ),
      );
    }

    final beacon = state.incomingBeacon;
    if (beacon != null) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: MeetupIncomingBeaconCard(
            beaconSeed: beaconSeed,
            otherUserName: otherUserName,
            l10n: l10n,
            onOpen: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => MeetupBeaconScreen(
                  matchId: matchId,
                  otherUserName: otherUserName,
                  mine: false,
                ),
              ),
            ),
            onDismiss: () => ref
                .read(meetupProvider(matchId).notifier)
                .dismissSignal(beacon.id),
          ),
        ),
      );
    }

    final cards = state.incomingSpotCards;
    final mine = state.mySpotCards;
    if (cards.isNotEmpty || mine.isNotEmpty) {
      children.add(const SizedBox(height: 18));
      children.add(
        Text(
          l10n.getString('meetupSpotMeTitle'),
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
      );
      children.add(const SizedBox(height: 8));
      for (final card in cards) {
        children.add(
          MeetupIncomingSpotCard(
            key: ValueKey('spot-${card.id}'),
            card: card,
            matchId: matchId,
            otherUserId: otherUserId,
            otherUserName: otherUserName,
          ),
        );
      }
      for (final card in mine) {
        children.add(
          MeetupOwnSpotCardTile(
            key: ValueKey('spot-${card.id}'),
            card: card,
            matchId: matchId,
          ),
        );
      }
    }

    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}
