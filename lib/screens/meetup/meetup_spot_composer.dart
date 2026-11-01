import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/meetup_models.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/meetup_provider.dart';
import 'package:matchme/services/meetup_selfie.dart';
import 'package:matchme/services/photo_prescreen_service.dart';
import 'package:matchme/utils/meetup_display.dart';
import 'package:matchme/widgets/photo_editor_widget.dart';
import 'package:matchme/widgets/safe_text.dart';

Future<bool> showMeetupSpotComposer(
  BuildContext context, {
  required String matchId,
  required String otherUserName,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) =>
        MeetupSpotComposerSheet(matchId: matchId, otherUserName: otherUserName),
  );
  return result ?? false;
}

/// Full-size, zoomable view of a Spot me photo, opened from the composer
/// preview and from shared spot cards on both devices.
void showMeetupSpotPhoto(
  BuildContext context, {
  String? url,
  Uint8List? bytes,
}) {
  assert(url != null || bytes != null, 'a photo source is required');
  showDialog<void>(
    context: context,
    barrierColor: Colors.black,
    builder: (dialogContext) => Dialog(
      insetPadding: EdgeInsets.zero,
      backgroundColor: Colors.black,
      child: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 5,
                child: Center(
                  child: bytes != null
                      ? Image.memory(bytes, fit: BoxFit.contain)
                      : Image.network(
                          url!,
                          fit: BoxFit.contain,
                          loadingBuilder: (_, child, progress) =>
                              progress == null
                              ? child
                              : const Center(
                                  child: CircularProgressIndicator(),
                                ),
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.broken_image_outlined,
                            color: Colors.white70,
                            size: 48,
                          ),
                        ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Material(
                color: Colors.black54,
                shape: const CircleBorder(),
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  tooltip: MaterialLocalizations.of(
                    dialogContext,
                  ).closeButtonTooltip,
                  onPressed: () => Navigator.of(dialogContext).maybePop(),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class MeetupSpotComposerSheet extends ConsumerStatefulWidget {
  final String matchId;
  final String otherUserName;

  const MeetupSpotComposerSheet({
    super.key,
    required this.matchId,
    required this.otherUserName,
  });

  @override
  ConsumerState<MeetupSpotComposerSheet> createState() =>
      _MeetupSpotComposerSheetState();
}

class _MeetupSpotComposerSheetState
    extends ConsumerState<MeetupSpotComposerSheet> {
  final _note = TextEditingController();

  String? _shirt;
  String? _pants;
  String? _shoes;
  String? _shirtColor;
  String? _pantsColor;
  String? _shoesColor;
  Uint8List? _photo;
  String? _selfieNoticeKey;
  String? _shareErrorKey;
  final _selfieNoticeAnchor = GlobalKey();
  final _contentNoticeAnchor = GlobalKey();
  final _shareErrorAnchor = GlobalKey();
  bool _picking = false;
  bool _checking = false;
  bool _sharing = false;

  /// A note is a clue attached to the card, not content on its own: sharing
  /// needs a selfie or at least one outfit value.
  bool get _canShare =>
      _photo != null ||
      _shirt != null ||
      _pants != null ||
      _shoes != null ||
      _shirtColor != null ||
      _pantsColor != null ||
      _shoesColor != null;

  Map<String, dynamic> _outfit() {
    final outfit = <String, dynamic>{};
    if (_shirt != null) outfit['shirt'] = _shirt;
    if (_shirtColor != null) outfit['shirt_color'] = _shirtColor;
    if (_pants != null) outfit['pants'] = _pants;
    if (_pantsColor != null) outfit['pants_color'] = _pantsColor;
    if (_shoes != null) outfit['shoes'] = _shoes;
    if (_shoesColor != null) outfit['shoes_color'] = _shoesColor;
    return outfit;
  }

  static String _cameraErrorKeyFor(String? code) {
    switch (code) {
      case 'denied':
        return 'meetupSpotMeCameraDenied';
      case 'failed':
        return 'meetupSpotMeCaptureFailed';
      default:
        return 'meetupSpotMeCameraUnavailable';
    }
  }

  Future<void> _takeSelfie() async {
    if (_picking || _checking) return;
    setState(() {
      _picking = true;
      _selfieNoticeKey = null;
    });
    final result = await captureMeetupSelfie(
      context: context,
      l10n: ref.read(localizationProvider),
    );
    if (!mounted) return;
    if (!result.isCaptured) {
      setState(() {
        _picking = false;
        if (!result.isCancelled) {
          _selfieNoticeKey = _cameraErrorKeyFor(result.error);
        }
      });
      if (!result.isCancelled) _reveal(_selfieNoticeAnchor);
      return;
    }
    setState(() {
      _picking = false;
      _checking = true;
    });
    await _checkSelfie(result.bytes!);
  }

  /// Local single-person gate before the photo can be shared: exactly one
  /// face or one body, never a group. There is no server-side AI fallback, so
  /// a missing detector fails closed (the outfit/note path stays available).
  Future<void> _checkSelfie(Uint8List bytes) async {
    PhotoPrescreenResult result;
    try {
      result = await ref
          .read(photoPrescreenServiceProvider)
          .prescreenPhoto(bytes, singlePersonOnly: true);
    } catch (_) {
      result = PhotoPrescreenResult.failed(reasons: const []);
    }
    if (!mounted) return;
    final unavailable = result.failureReasons.contains(
      PrescreenFailureReason.personCheckUnavailable,
    );
    setState(() {
      _checking = false;
      if (result.passed) {
        _photo = bytes;
        _selfieNoticeKey = null;
      } else {
        _selfieNoticeKey = result.failureReasons.isNotEmpty
            ? prescreenFailureL10nKey(result.failureReasons.first)
            : 'photoErrorGeneral';
      }
    });
    if (result.passed) return;
    if (unavailable) {
      _reveal(_selfieNoticeAnchor);
      return;
    }
    final action = await showPrescreenFailureDialog(
      context,
      result,
      ref,
      photoBytes: bytes,
      retakeMode: true,
    );
    if (!mounted) return;
    if (action == PrescreenFailureAction.retake) {
      await _takeSelfie();
    } else {
      _reveal(_selfieNoticeAnchor);
    }
  }

  Future<void> _share() async {
    if (_sharing || _picking || _checking || !_canShare) return;
    setState(() {
      _sharing = true;
      _shareErrorKey = null;
    });
    final note = _note.text.trim();
    final error = await ref
        .read(meetupProvider(widget.matchId).notifier)
        .shareSpot(
          kind: 'self',
          photoBytes: _photo,
          outfit: _outfit().map((key, value) => MapEntry(key, '$value')),
          note: note.isEmpty ? null : note,
        );
    if (!mounted) return;
    setState(() {
      _sharing = false;
      if (error != null) _shareErrorKey = error;
    });
    if (error != null) {
      _reveal(_shareErrorAnchor);
      return;
    }
    Navigator.of(context).pop(true);
  }

  // Inline banners only: a root SnackBar renders behind the modal sheet.
  void _reveal(GlobalKey anchor) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final anchorContext = anchor.currentContext;
      if (anchorContext == null) return;
      Scrollable.ensureVisible(
        anchorContext,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: 0.1,
      );
    });
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final theme = Theme.of(context);
    final selfieBusy = _picking || _checking;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              l10n.getString('meetupSpotMeTitle'),
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.getString('meetupSpotMeHint'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            if (_photo != null) ...[
              Stack(
                children: [
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => showMeetupSpotPhoto(context, bytes: _photo),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 260),
                          child: Image.memory(_photo!, fit: BoxFit.contain),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: IconButton.filledTonal(
                      tooltip: l10n.getString('meetupClose'),
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _photo = null),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],
            if (_selfieNoticeKey != null) ...[
              const SizedBox(height: 8),
              _SpotNotice(
                anchorKey: _selfieNoticeAnchor,
                icon: Icons.info_outline,
                background: theme.colorScheme.tertiaryContainer,
                foreground: theme.colorScheme.onTertiaryContainer,
                message: l10n.getString(_selfieNoticeKey!),
              ),
            ],
            FilledButton.tonalIcon(
              onPressed: selfieBusy ? null : _takeSelfie,
              icon: selfieBusy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.photo_camera_front_outlined),
              label: Text(
                l10n.getString(
                  _checking
                      ? 'meetupSpotMeChecking'
                      : _photo == null
                      ? 'meetupSpotMeSelfie'
                      : 'meetupSpotMeRetake',
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              l10n.getString('meetupSpotMeSelfieHint'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              l10n.getString('meetupSpotMeOutfit'),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            _OutfitRow(
              label: l10n.getString('meetupOutfitShirt'),
              type: _shirt,
              color: _shirtColor,
              options: const [
                _OutfitOption('long_sleeve', 'meetupOutfitLongSleeve'),
                _OutfitOption('short_sleeve', 'meetupOutfitShortSleeve'),
                _OutfitOption('jacket', 'meetupOutfitJacket'),
                _OutfitOption('dress', 'meetupOutfitDress'),
                _OutfitOption('other', 'meetupOutfitOther'),
              ],
              onTypeChanged: (value) => setState(() => _shirt = value),
              onColorChanged: (value) => setState(() => _shirtColor = value),
            ),
            const SizedBox(height: 10),
            _OutfitRow(
              label: l10n.getString('meetupOutfitPants'),
              type: _pants,
              color: _pantsColor,
              options: const [
                _OutfitOption('shorts', 'meetupOutfitShorts'),
                _OutfitOption('trousers', 'meetupOutfitTrousers'),
                _OutfitOption('skirt', 'meetupOutfitSkirt'),
                _OutfitOption('other', 'meetupOutfitOther'),
              ],
              onTypeChanged: (value) => setState(() => _pants = value),
              onColorChanged: (value) => setState(() => _pantsColor = value),
            ),
            const SizedBox(height: 10),
            _OutfitRow(
              label: l10n.getString('meetupOutfitShoes'),
              type: _shoes,
              color: _shoesColor,
              options: const [
                _OutfitOption('sneakers', 'meetupOutfitSneakers'),
                _OutfitOption('boots', 'meetupOutfitBoots'),
                _OutfitOption('sandals', 'meetupOutfitSandals'),
                _OutfitOption('other', 'meetupOutfitOther'),
              ],
              onTypeChanged: (value) => setState(() => _shoes = value),
              onColorChanged: (value) => setState(() => _shoesColor = value),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _note,
              maxLength: 280,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: l10n.getString('meetupSpotMeNote'),
                hintText: l10n.getString('meetupSpotMeNoteHint'),
                border: const OutlineInputBorder(),
              ),
            ),
            if (!_canShare && _note.text.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              _SpotNotice(
                anchorKey: _contentNoticeAnchor,
                icon: Icons.info_outline,
                background: theme.colorScheme.tertiaryContainer,
                foreground: theme.colorScheme.onTertiaryContainer,
                message: l10n.getString('meetupSpotMeContentRequired'),
              ),
            ],
            if (_shareErrorKey != null) ...[
              const SizedBox(height: 8),
              _SpotNotice(
                anchorKey: _shareErrorAnchor,
                icon: Icons.error_outline,
                background: theme.colorScheme.errorContainer,
                foreground: theme.colorScheme.onErrorContainer,
                message: l10n.getString(
                  _shareErrorKey!,
                  params: {'name': widget.otherUserName},
                ),
              ),
            ],
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _sharing || selfieBusy || !_canShare ? null : _share,
              icon: _sharing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
              label: Text(
                _sharing
                    ? l10n.getString('meetupSpotMeSharing')
                    : l10n.getString('meetupSpotMeShare'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SpotNotice extends StatelessWidget {
  final GlobalKey anchorKey;
  final IconData icon;
  final Color background;
  final Color foreground;
  final String message;

  const _SpotNotice({
    required this.anchorKey,
    required this.icon,
    required this.background,
    required this.foreground,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Container(
        key: anchorKey,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: foreground),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: foreground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OutfitOption {
  final String token;
  final String labelKey;

  const _OutfitOption(this.token, this.labelKey);
}

class _OutfitRow extends ConsumerWidget {
  final String label;
  final String? type;
  final String? color;
  final List<_OutfitOption> options;
  final ValueChanged<String?> onTypeChanged;
  final ValueChanged<String?> onColorChanged;

  const _OutfitRow({
    required this.label,
    required this.type,
    required this.color,
    required this.options,
    required this.onTypeChanged,
    required this.onColorChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 4,
          child: DropdownButtonFormField<String>(
            initialValue: type,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: label,
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
            items: options
                .map(
                  (option) => DropdownMenuItem(
                    value: option.token,
                    child: ShrinkText(l10n.getString(option.labelKey)),
                  ),
                )
                .toList(growable: false),
            onChanged: onTypeChanged,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: DropdownButtonFormField<String>(
            initialValue: color ?? kMeetupColorNone,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: l10n.getString('meetupOutfitColor'),
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
            items: [
              DropdownMenuItem(
                value: kMeetupColorNone,
                child: ShrinkText(
                  l10n.getString('meetupOutfitColorUnspecified'),
                ),
              ),
              for (final token in kMeetupColorTokens)
                DropdownMenuItem(
                  value: token,
                  child: ShrinkText(meetupOutfitColorDisplay(token, l10n)),
                ),
            ],
            onChanged: (value) =>
                onColorChanged(value == kMeetupColorNone ? null : value),
          ),
        ),
      ],
    );
  }
}

String meetupOutfitLabelKey(String value) {
  switch (value) {
    case 'long_sleeve':
      return 'meetupOutfitLongSleeve';
    case 'short_sleeve':
      return 'meetupOutfitShortSleeve';
    case 'jacket':
      return 'meetupOutfitJacket';
    case 'dress':
      return 'meetupOutfitDress';
    case 'shorts':
      return 'meetupOutfitShorts';
    case 'trousers':
      return 'meetupOutfitTrousers';
    case 'skirt':
      return 'meetupOutfitSkirt';
    case 'sneakers':
      return 'meetupOutfitSneakers';
    case 'boots':
      return 'meetupOutfitBoots';
    case 'sandals':
      return 'meetupOutfitSandals';
    default:
      return 'meetupOutfitOther';
  }
}
