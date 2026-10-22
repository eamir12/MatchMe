import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/offline_cache_manager.dart';
import 'package:matchme/services/storage_helper.dart';
import 'package:matchme/services/translation_text_cache.dart';
import 'package:matchme/services/verification_service.dart';
import 'package:matchme/services/voice_guidance_service.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/theme/semantic_colors.dart';
import 'package:matchme/services/translation_service.dart';
import 'package:matchme/widgets/please_wait_dialog.dart';
import 'package:matchme/widgets/voice_guidance_mute_button.dart';
import 'package:matchme/services/verification_mediapipe.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:matchme/widgets/safe_text.dart';

class VerificationGesture {
  final String code;
  final String titleKey;
  final String descriptionKey;
  final String aiPromptText;

  const VerificationGesture({
    required this.code,
    required this.titleKey,
    required this.descriptionKey,
    required this.aiPromptText,
  });
}

const List<VerificationGesture> _availableVerificationGestures = [
  VerificationGesture(
    code: 'CLOSED_FIST_RIGHT_HAND',
    titleKey: 'verificationGestureClosedFistTitle',
    descriptionKey: 'verificationGestureClosedFistDescription',
    aiPromptText:
        'The person must clearly show a closed fist with their right hand next to their face, with the fist fully visible.',
  ),
  VerificationGesture(
    code: 'OPEN_PALM_RIGHT_HAND',
    titleKey: 'verificationGestureOpenPalmTitle',
    descriptionKey: 'verificationGestureOpenPalmDescription',
    aiPromptText:
        'The person must clearly show an open palm with their right hand next to their face, with all fingers visible.',
  ),
  VerificationGesture(
    code: 'PEACE_SIGN_RIGHT_HAND',
    titleKey: 'verificationGesturePeaceSignTitle',
    descriptionKey: 'verificationGesturePeaceSignDescription',
    aiPromptText:
        'The person must clearly show a V-shaped peace sign with their right hand next to their face, with the fingers clearly visible.',
  ),
  VerificationGesture(
    code: 'POINTING_UP_RIGHT_HAND',
    titleKey: 'verificationGesturePointingUpTitle',
    descriptionKey: 'verificationGesturePointingUpDescription',
    aiPromptText:
        'The person must clearly show a pointing up gesture with their right hand next to their face, with the index finger extended upward.',
  ),
  VerificationGesture(
    code: 'THUMBS_DOWN_RIGHT_HAND',
    titleKey: 'verificationGestureThumbsDownTitle',
    descriptionKey: 'verificationGestureThumbsDownDescription',
    aiPromptText:
        'The person must clearly show a thumbs-down with their right hand next to their face, with the thumb pointing down.',
  ),
  VerificationGesture(
    code: 'THUMBS_UP_RIGHT_HAND',
    titleKey: 'verificationGestureThumbsUpTitle',
    descriptionKey: 'verificationGestureThumbsUpDescription',
    aiPromptText:
        'The person must clearly show a thumbs-up with their right hand next to their face, with the thumb clearly visible.',
  ),
  VerificationGesture(
    code: 'CLOSED_FIST_LEFT_HAND',
    titleKey: 'verificationGestureClosedFistLeftTitle',
    descriptionKey: 'verificationGestureClosedFistLeftDescription',
    aiPromptText:
        'The person must clearly show a closed fist with their left hand next to their face, with the fist fully visible.',
  ),
  VerificationGesture(
    code: 'OPEN_PALM_LEFT_HAND',
    titleKey: 'verificationGestureOpenPalmLeftTitle',
    descriptionKey: 'verificationGestureOpenPalmLeftDescription',
    aiPromptText:
        'The person must clearly show an open palm with their left hand next to their face, with all fingers visible.',
  ),
  VerificationGesture(
    code: 'PEACE_SIGN_LEFT_HAND',
    titleKey: 'verificationGesturePeaceSignLeftTitle',
    descriptionKey: 'verificationGesturePeaceSignLeftDescription',
    aiPromptText:
        'The person must clearly show a V-shaped peace sign with their left hand next to their face, with the fingers clearly visible.',
  ),
  VerificationGesture(
    code: 'POINTING_UP_LEFT_HAND',
    titleKey: 'verificationGesturePointingUpLeftTitle',
    descriptionKey: 'verificationGesturePointingUpLeftDescription',
    aiPromptText:
        'The person must clearly show a pointing up gesture with their left hand next to their face, with the index finger extended upward.',
  ),
  VerificationGesture(
    code: 'THUMBS_DOWN_LEFT_HAND',
    titleKey: 'verificationGestureThumbsDownLeftTitle',
    descriptionKey: 'verificationGestureThumbsDownLeftDescription',
    aiPromptText:
        'The person must clearly show a thumbs-down with their left hand next to their face, with the thumb pointing down.',
  ),
  VerificationGesture(
    code: 'THUMBS_UP_LEFT_HAND',
    titleKey: 'verificationGestureThumbsUpLeftTitle',
    descriptionKey: 'verificationGestureThumbsUpLeftDescription',
    aiPromptText:
        'The person must clearly show a thumbs-up with their left hand next to their face, with the thumb clearly visible.',
  ),
];

VerificationGesture? _cachedVerificationGesture;
final Random _gestureRandom = Random();

/// One AI-marked mismatch region from `verification_ai_analysis.mismatchRegions`.
/// Boxes are normalized fractions (0-1) of each photo's own width/height and
/// are approximate by design — Gemini estimates them from the image pair.
class _ComparisonRegion {
  final String feature;
  final String description;
  final List<double>? profileBox;
  final List<double>? verificationBox;

  const _ComparisonRegion({
    required this.feature,
    required this.description,
    this.profileBox,
    this.verificationBox,
  });

  static double? _num(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  static List<double>? _box(dynamic raw) {
    if (raw is! Map) return null;
    final x = _num(raw['x']);
    final y = _num(raw['y']);
    final w = _num(raw['width']);
    final h = _num(raw['height']);
    if (x == null || y == null || w == null || h == null) return null;
    final cx = x.clamp(0.0, 1.0).toDouble();
    final cy = y.clamp(0.0, 1.0).toDouble();
    final cw = w.clamp(0.0, 1.0 - cx).toDouble();
    final ch = h.clamp(0.0, 1.0 - cy).toDouble();
    if (cw <= 0 || ch <= 0) return null;
    return <double>[cx, cy, cw, ch];
  }

  static _ComparisonRegion? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final description = raw['description']?.toString().trim() ?? '';
    final feature = raw['feature']?.toString().trim() ?? '';
    if (description.isEmpty && feature.isEmpty) return null;
    return _ComparisonRegion(
      feature: feature,
      description: description,
      profileBox: _box(raw['profileBox']),
      verificationBox: _box(raw['verificationBox']),
    );
  }
}

/// Paints the AI mismatch rectangles plus a numbered badge over each photo.
/// Coordinates are approximate (normalized 0-1, mapped onto a frame that
/// matches the photo's own aspect ratio), so boxes are indicative rather than
/// pixel-exact.
class _MismatchBoxesPainter extends CustomPainter {
  final List<List<double>?> boxes;

  const _MismatchBoxesPainter(this.boxes);

  static const double _badgeRadius = 11;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final placedBadges = <Rect>[];
    for (var i = 0; i < boxes.length; i++) {
      final box = boxes[i];
      if (box == null) continue;
      final rawRect = Rect.fromLTWH(
        box[0] * size.width,
        box[1] * size.height,
        box[2] * size.width,
        box[3] * size.height,
      );
      // Keep tiny AI boxes visible without moving them off their feature.
      final padded = rawRect.width < 18 || rawRect.height < 18
          ? Rect.fromCenter(
              center: rawRect.center,
              width: max(rawRect.width, 18),
              height: max(rawRect.height, 18),
            )
          : rawRect;
      final rect = padded.intersect(Offset.zero & size);
      if (rect.isEmpty) continue;
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(6));
      canvas.drawRRect(
        rrect,
        Paint()..color = Colors.red.withValues(alpha: 0.15),
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = Colors.red
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
      final badgeCenter = _placeBadge(rect, size, placedBadges);
      placedBadges.add(
        Rect.fromCircle(center: badgeCenter, radius: _badgeRadius + 1),
      );
      canvas.drawCircle(
        badgeCenter,
        _badgeRadius,
        Paint()..color = const Color(0xFFD32F2F),
      );
      final label = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(
        canvas,
        badgeCenter - Offset(label.width / 2, label.height / 2),
      );
    }
  }

  /// Picks a badge corner that does not overlap a badge already placed for a
  /// previous (possibly overlapping) rectangle.
  Offset _placeBadge(Rect rect, Size size, List<Rect> placed) {
    final candidates = <Offset>[
      Offset(rect.left + _badgeRadius + 2, rect.top + _badgeRadius + 2),
      Offset(rect.right - _badgeRadius - 2, rect.top + _badgeRadius + 2),
      Offset(rect.left + _badgeRadius + 2, rect.bottom - _badgeRadius - 2),
      Offset(rect.right - _badgeRadius - 2, rect.bottom - _badgeRadius - 2),
      Offset(rect.center.dx, rect.top - _badgeRadius - 2),
      Offset(rect.center.dx, rect.bottom + _badgeRadius + 2),
      Offset(rect.left - _badgeRadius - 2, rect.center.dy),
      Offset(rect.right + _badgeRadius + 2, rect.center.dy),
    ];
    final margin = min(_badgeRadius + 1, min(size.width, size.height) / 2);
    for (final candidate in candidates) {
      final center = Offset(
        candidate.dx.clamp(margin, size.width - margin),
        candidate.dy.clamp(margin, size.height - margin),
      );
      final bounds = Rect.fromCircle(center: center, radius: _badgeRadius + 1);
      if (!placed.any((other) => other.overlaps(bounds))) return center;
    }
    return Offset(
      (rect.left + margin).clamp(margin, size.width - margin),
      (rect.top + margin).clamp(margin, size.height - margin),
    );
  }

  @override
  bool shouldRepaint(_MismatchBoxesPainter oldDelegate) =>
      oldDelegate.boxes != boxes;
}

/// One comparison photo, sized to its real aspect ratio (never cropped),
/// capped by the responsive width/height the parent computes. Tapping opens a
/// full-screen pinch-zoom viewer; the AI boxes are only painted once the
/// intrinsic size is known so they always land on the correct feature.
class _ComparisonPhoto extends StatefulWidget {
  final String label;
  final String? path;
  final String bucket;
  final List<List<double>?> boxes;
  final double maxWidth;
  final double maxHeight;

  const _ComparisonPhoto({
    super.key,
    required this.label,
    required this.path,
    required this.bucket,
    required this.boxes,
    required this.maxWidth,
    required this.maxHeight,
  });

  @override
  State<_ComparisonPhoto> createState() => _ComparisonPhotoState();
}

class _ComparisonPhotoState extends State<_ComparisonPhoto> {
  // Portrait-ish frame used until the real image dimensions are decoded.
  static const double _fallbackAspect = 0.78;

  double _aspectRatio = _fallbackAspect;
  bool _hasMeasuredAspect = false;
  int _measureGeneration = 0;

  bool get _hasPhoto => widget.path != null && widget.path!.isNotEmpty;

  @override
  void didUpdateWidget(covariant _ComparisonPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path || oldWidget.bucket != widget.bucket) {
      _measureGeneration++;
      _aspectRatio = _fallbackAspect;
      _hasMeasuredAspect = false;
    }
  }

  Future<void> _handleBytes(Uint8List? bytes) async {
    if (bytes == null || bytes.isEmpty) return;
    final generation = ++_measureGeneration;
    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(bytes, targetWidth: 720);
      final frame = await codec.getNextFrame();
      final width = frame.image.width.toDouble();
      final height = frame.image.height.toDouble();
      frame.image.dispose();
      if (!mounted || generation != _measureGeneration) return;
      if (width <= 0 || height <= 0) return;
      final ratio = width / height;
      if (_hasMeasuredAspect && (ratio - _aspectRatio).abs() < 0.001) {
        return;
      }
      setState(() {
        _aspectRatio = ratio;
        _hasMeasuredAspect = true;
      });
    } catch (_) {
      // Keep the fallback frame; the image itself still renders.
    } finally {
      codec?.dispose();
    }
  }

  Size _frameSize(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final maxWidth = widget.maxWidth.isFinite && widget.maxWidth > 0
        ? widget.maxWidth
        : screenWidth;
    final maxHeight = widget.maxHeight.isFinite && widget.maxHeight > 0
        ? widget.maxHeight
        : maxWidth / _aspectRatio;
    var width = maxWidth;
    var height = width / _aspectRatio;
    if (height > maxHeight) {
      height = maxHeight;
      width = height * _aspectRatio;
    }
    return Size(width, height);
  }

  void _openFullScreen() {
    final path = widget.path;
    if (path == null || path.isEmpty) return;
    showDialog<void>(
      context: context,
      barrierColor: Colors.black,
      builder: (dialogContext) {
        return Dialog(
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
                      child: AspectRatio(
                        aspectRatio: _aspectRatio,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            SignedImage(
                              source: path,
                              bucket: widget.bucket,
                              fit: BoxFit.contain,
                              errorWidget: const Icon(
                                Icons.broken_image_outlined,
                                color: Colors.white70,
                                size: 48,
                              ),
                              placeholder: const Center(
                                child: CircularProgressIndicator(),
                              ),
                            ),
                            if (_hasMeasuredAspect)
                              IgnorePointer(
                                child: CustomPaint(
                                  painter: _MismatchBoxesPainter(widget.boxes),
                                ),
                              ),
                          ],
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
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final frameSize = _frameSize(context);
    final borderColor = theme.dividerColor.withValues(alpha: 0.6);

    return Semantics(
      container: true,
      label: widget.label,
      image: true,
      button: _hasPhoto,
      child: MouseRegion(
        cursor: _hasPhoto ? SystemMouseCursors.click : MouseCursor.defer,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _hasPhoto ? _openFullScreen : null,
          child: Container(
            width: frameSize.width,
            height: frameSize.height,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.3,
              ),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: borderColor),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_hasPhoto)
                  SignedImage(
                    source: widget.path!,
                    bucket: widget.bucket,
                    fit: BoxFit.contain,
                    filterQualityLow: true,
                    width: frameSize.width,
                    onBytesLoaded: _handleBytes,
                    errorWidget: Icon(
                      Icons.photo_library_outlined,
                      color: theme.disabledColor,
                    ),
                  )
                else
                  Center(
                    child: Icon(
                      Icons.photo_library_outlined,
                      color: theme.disabledColor,
                    ),
                  ),
                if (_hasPhoto && _hasMeasuredAspect)
                  IgnorePointer(
                    child: CustomPaint(
                      painter: _MismatchBoxesPainter(widget.boxes),
                    ),
                  ),
                if (_hasPhoto)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(
                          Icons.open_in_full,
                          size: 14,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bundled gesture artwork (Microsoft Fluent Emoji 3D, MIT), keyed by the
/// gesture base code. See assets/verification_gestures/README.md.
const Map<String, String> _verificationGestureAssetByBase = <String, String>{
  'CLOSED_FIST': 'assets/verification_gestures/closed_fist.png',
  'OPEN_PALM': 'assets/verification_gestures/open_palm.png',
  'PEACE_SIGN': 'assets/verification_gestures/peace_sign.png',
  'POINTING_UP': 'assets/verification_gestures/pointing_up.png',
  'THUMBS_DOWN': 'assets/verification_gestures/thumbs_down.png',
  'THUMBS_UP': 'assets/verification_gestures/thumbs_up.png',
};

/// Whether the bundled Fluent Emoji artwork for [code] must be mirrored to
/// depict the hand that [code] asks for.
///
/// The app pins one frozen artwork set (Microsoft Fluent Emoji 3D, MIT,
/// bundled under assets/verification_gestures) on every platform, because
/// system emoji fonts disagree about handedness and change it per OS version.
/// Five of the six drawings read as a LEFT hand: fist, palm, peace and
/// pointing were validated per gesture against the real left hand in the
/// mirrored camera preview; thumbs-up was user-verified (its mirrored copy
/// matched the right hand next to the mirrored selfie photo). Thumbs-down is
/// the exception: it only resembles a 180-degree rotation of the up art in
/// silhouette, but actually reads right-handed when shown raw (user-reported
/// on THUMBS_DOWN_LEFT_HAND), so it is mirrored for LEFT-hand requests
/// instead. The capture pages apply the same rule (with an explanatory
/// comment); keep the sites in sync when changing artwork.
bool _gestureGlyphNeedsMirror(String code) {
  if (code.startsWith('THUMBS_DOWN')) {
    return code.endsWith('_LEFT_HAND');
  }
  return !code.endsWith('_LEFT_HAND');
}

VerificationGesture _getSessionVerificationGesture() {
  if (_cachedVerificationGesture != null) {
    return _cachedVerificationGesture!;
  }
  if (_availableVerificationGestures.isEmpty) {
    throw StateError('No verification gestures configured');
  }
  _cachedVerificationGesture =
      _availableVerificationGestures[_gestureRandom.nextInt(
        _availableVerificationGestures.length,
      )];
  return _cachedVerificationGesture!;
}

class VerificationScreen extends ConsumerStatefulWidget {
  const VerificationScreen({super.key});

  @override
  ConsumerState<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends ConsumerState<VerificationScreen> {
  final VerificationService _verificationService = VerificationService();
  final ScrollController _scrollController = ScrollController();

  Uint8List? _selectedImage;
  bool _isSubmitting = false;
  bool _isRequestingManualReview = false;
  bool _didSpeakIntro = false;
  bool _didSpeakTakePhotoHint = false;

  /// Latest verification status payload (server truth, or the on-device copy
  /// of it). Held in state so the screen renders the full result — AI
  /// analysis, verification photo, rejection reason — as soon as it is
  /// entered, instead of waiting for the network round-trip.
  Map<String, dynamic>? _statusData;

  /// True until the first status payload (cached or fetched) is available.
  bool _isLoadingStatus = true;

  /// Signature of the last profile-cache heal that was requested, so the
  /// sync is not re-triggered on every rebuild.
  String? _lastStatusSyncSignature;

  /// In-flight translations, keyed by the (text, locale) cache key.
  ///
  /// One entry per distinct text: the reasoning and every mismatch-region
  /// description are translated separately, and each of them must be
  /// translated only once — not once per rebuild.
  final Map<String, Future<String>> _reasoningTranslations =
      <String, Future<String>>{};

  // Accessibility: content on this screen is also spoken, in visual order.
  // Announcements are serialized on one queue so two sources scheduled in the
  // same frame cannot race each other into the 2-second rate limiter and get
  // dropped; each source dedupes with its own signature so rebuilds never
  // repeat a sentence, and again on the built text so a stale queued item
  // whose content was already spoken (state changed while queued) is skipped.
  // Titles, section headers and button labels are deliberately never spoken.
  Future<void> _spokenQueue = Future<void>.value();
  final Map<String, String> _lastSpokenBySource = <String, String>{};
  String? _lastStatusDetailsSpokenSig;
  String? _lastInstructionsSpokenSig;
  String? _lastSubmissionSpokenSig;
  String? _lastApprovedSpokenSig;

  VerificationGesture? _currentGesture;

  void _enqueueSpoken(
    String source,
    Future<String> Function() buildText, {
    bool Function()? isRelevant,
  }) {
    if (!VoiceGuidanceService.instance.enabled) return;
    _spokenQueue = _spokenQueue
        .then((_) async {
          if (!mounted) return;
          if (ModalRoute.of(context)?.isCurrent != true) return;
          String text;
          try {
            text = (await buildText()).trim();
          } catch (_) {
            return;
          }
          if (text.isEmpty || !mounted) return;
          if (ModalRoute.of(context)?.isCurrent != true) return;
          if (isRelevant != null && !isRelevant()) return;
          if (_lastSpokenBySource[source] == text) return;
          await VoiceGuidanceService.instance.speakTextAfterCurrent(text);
          _lastSpokenBySource[source] = text;
          // Hold the queue until this utterance finished so the next
          // announcement can never start on top of it.
          await VoiceGuidanceService.instance.waitUntilCurrentSpeechFinished();
        })
        .catchError((_) {});
  }

  void _openSelectedImagePreview() {
    final bytes = _selectedImage;
    if (bytes == null) return;

    showDialog<void>(
      context: context,
      barrierColor: Colors.black,
      builder: (context) {
        return Dialog(
          insetPadding: EdgeInsets.zero,
          backgroundColor: Colors.black,
          child: SafeArea(
            child: Stack(
              children: [
                Positioned.fill(
                  child: InteractiveViewer(
                    child: Center(
                      child: Image.memory(bytes, fit: BoxFit.contain),
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _selectRandomGestureIfNeeded();
    unawaited(_loadVerificationStatus());
  }

  @override
  void dispose() {
    // Leaving the screen silences any guidance mid-sentence.
    unawaited(VoiceGuidanceService.instance.stop());
    _scrollController.dispose();
    super.dispose();
  }

  void _selectRandomGestureIfNeeded() {
    if (_currentGesture != null) {
      return;
    }
    setState(() {
      _currentGesture = _getSessionVerificationGesture();
    });
  }

  Future<void> _pickImage() async {
    print('VERIFICATION SCREEN: _pickImage called');
    _selectRandomGestureIfNeeded();
    if (_currentGesture == null) {
      print('VERIFICATION SCREEN: _currentGesture is null');
      return;
    }
    print('VERIFICATION SCREEN: Gesture selected: ${_currentGesture!.code}');
    final l10n = ref.read(localizationProvider);
    final gestureLabel = l10n.getString(_currentGesture!.titleKey);
    final gestureDescription = l10n.getString(_currentGesture!.descriptionKey);
    print('VERIFICATION SCREEN: Gesture label: $gestureLabel');

    // Voice guidance: describe the required gesture before the capture page
    // opens so the user knows exactly what to do. speakAndWait (not speakKey)
    // so a fresh tap is always heard: it interrupts any pending screen
    // announcement instead of being dropped by the 2-second rate limiter.
    final gestureSpeech = l10n.getString(
      'voiceGuidanceVerificationGesture',
      params: {'gesture': gestureLabel, 'description': gestureDescription},
    );
    unawaited(
      VoiceGuidanceService.instance.speakAndWait(
        gestureSpeech.startsWith('[')
            ? '$gestureLabel. $gestureDescription'
            : gestureSpeech,
      ),
    );

    openMediaPipeVerificationCapture(
      gestureCode: _currentGesture!.code,
      gestureLabel: gestureLabel,
      gestureDescription: gestureDescription,
      localeCode: l10n.currentLocale.languageCode,
      captureStrings: <String, String>{
        'verificationCaptureLoading': l10n.getString(
          'verificationCaptureLoading',
        ),
        'verificationCaptureInstruction': l10n.getString(
          'verificationCaptureInstruction',
        ),
        'verificationCaptureStatusShowGesture': l10n.getString(
          'verificationCaptureStatusShowGesture',
        ),
        'verificationCaptureStatusShowFace': l10n.getString(
          'verificationCaptureStatusShowFace',
        ),
        'verificationCaptureStatusAlignFace': l10n.getString(
          'verificationCaptureStatusAlignFace',
        ),
        'verificationCaptureStatusPositionHand': l10n.getString(
          'verificationCaptureStatusPositionHand',
        ),
        'verificationCaptureStatusHoldSteady': l10n.getString(
          'verificationCaptureStatusHoldSteady',
        ),
        'verificationCaptureStatusCapturingBestFrame': l10n.getString(
          'verificationCaptureStatusCapturingBestFrame',
        ),
        'verificationCaptureStatusGestureDetected': l10n.getString(
          'verificationCaptureStatusGestureDetected',
        ),
        'verificationCaptureStatusUseCorrectHand': l10n.getString(
          'verificationCaptureStatusUseCorrectHand',
        ),
        'verificationCaptureChecklistFaceVisible': l10n.getString(
          'verificationCaptureChecklistFaceVisible',
        ),
        'verificationCaptureChecklistHandPositioned': l10n.getString(
          'verificationCaptureChecklistHandPositioned',
        ),
        'verificationCaptureChecklistGestureRecognized': l10n.getString(
          'verificationCaptureChecklistGestureRecognized',
        ),
        'verificationCaptureChecklistLighting': l10n.getString(
          'verificationCaptureChecklistLighting',
        ),
        'verificationCaptureStatusTooDark': l10n.getString(
          'verificationCaptureStatusTooDark',
        ),
        'verificationCaptureHandLeft': l10n.getString(
          'verificationCaptureHandLeft',
        ),
        'verificationCaptureHandRight': l10n.getString(
          'verificationCaptureHandRight',
        ),
        'verificationCaptureHandLeftBadge': l10n.getString(
          'verificationCaptureHandLeftBadge',
        ),
        'verificationCaptureHandRightBadge': l10n.getString(
          'verificationCaptureHandRightBadge',
        ),
        'verificationCaptureCameraOrModelError': l10n.getString(
          'verificationCaptureCameraOrModelError',
        ),
        'verificationCaptureFailedToLoad': l10n.getString(
          'verificationCaptureFailedToLoad',
        ),
        'verificationCaptureCameraPermissionDenied': l10n.getString(
          'verificationCaptureCameraPermissionDenied',
        ),
        // Only pass the retry label when a real translation exists;
        // otherwise the capture page falls back to its built-in English.
        'verificationCaptureRetry': l10n.containsKey('verificationCaptureRetry')
            ? l10n.getString('verificationCaptureRetry')
            : 'Retry',
      },
      context: context,
      onPhoto: (Uint8List? bytes) async {
        print(
          'VERIFICATION SCREEN: onPhoto called with bytes: ${bytes != null ? bytes.length : 'null'}',
        );
        if (bytes != null && mounted) {
          if (VoiceGuidanceService.instance.isSpeaking) {
            await VoiceGuidanceService.instance
                .waitUntilCurrentSpeechFinished();
          }
          if (!mounted) return;
          setState(() {
            _selectedImage = bytes;
          });
          unawaited(
            VoiceGuidanceService.instance.speakKey(
              'voiceGuidanceVerificationCaptured',
            ),
          );
          _scrollToCapturedPhoto();
        } else {
          print('VERIFICATION SCREEN: No bytes received or not mounted');
        }
      },
    );
    print('VERIFICATION SCREEN: openMediaPipeVerificationCapture called');
  }

  Future<void> _submitVerification() async {
    if (_selectedImage == null) return;

    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    final l10n = ref.read(localizationProvider);
    final profileNotifier = ref.read(profileEditProvider(user.id).notifier);
    final previousProfile = ref
        .read(userProfileProvider(user.id))
        .asData
        ?.value;

    setState(() {
      _isSubmitting = true;
    });
    unawaited(
      VoiceGuidanceService.instance.speakAndWait(
        l10n.getString('voiceGuidanceVerificationSubmitting'),
      ),
    );

    await profileNotifier.applyLocalVerificationUpdate(
      verificationStatus: 'analyzing',
      isVerified: false,
      verificationSubmittedAt:
          previousProfile?.verificationSubmittedAt ?? DateTime.now().toUtc(),
      verificationReviewedAt: previousProfile?.verificationReviewedAt,
    );
    if (!mounted) return;

    // Show loading dialog
    PleaseWaitDialog.show(context);

    try {
      await _verificationService.submitVerificationPhoto(
        user.id,
        _selectedImage!,
        gestureCode: _currentGesture?.code,
        gesturePrompt: _currentGesture?.aiPromptText,
      );

      final statusData = await _verificationService.getVerificationStatus(
        user.id,
      );
      final status = statusData?['verification_status'] as String?;

      if (mounted && statusData != null) {
        setState(() {
          _statusData = statusData;
        });
      }

      if (status != null) {
        await profileNotifier.applyLocalVerificationUpdate(
          verificationStatus: status,
          isVerified: statusData?['is_verified'] == true,
          verificationSubmittedAt:
              _parseDateTime(statusData?['verification_submitted_at']) ??
              previousProfile?.verificationSubmittedAt,
          verificationReviewedAt:
              _parseDateTime(statusData?['verification_reviewed_at']) ??
              previousProfile?.verificationReviewedAt,
        );
      }

      if (mounted) {
        setState(() {
          _selectedImage = null;
        });

        final message = (status == 'rejected')
            ? l10n.getString('verificationNotApproved')
            : l10n.getString('verificationSubmittedSuccess');
        final semantic = SemanticColors.of(context);
        final colorScheme = Theme.of(context).colorScheme;
        final isRejectMessage = status == 'rejected';
        final bg = isRejectMessage ? colorScheme.error : semantic.success;
        final fg = isRejectMessage ? colorScheme.onError : semantic.onSuccess;

        // The snackbar text is shown, so it is spoken — queued behind any
        // announcement already in progress so it can never be dropped.
        _enqueueSpoken('submitResult', () => Future.value(message));

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message, style: TextStyle(color: fg)),
            backgroundColor: bg,
          ),
        );
      }
    } catch (e) {
      if (previousProfile != null) {
        await profileNotifier.applyLocalVerificationUpdate(
          verificationStatus: previousProfile.verificationStatus,
          isVerified: previousProfile.isVerified,
          verificationSubmittedAt: previousProfile.verificationSubmittedAt,
          verificationReviewedAt: previousProfile.verificationReviewedAt,
        );
      }
      if (mounted) {
        final errorShown =
            '${l10n.getString('failedToSubmitVerification')}: $e';
        // Errors are urgent: they interrupt instead of queueing, and the
        // full shown text (including the error detail) is spoken.
        unawaited(VoiceGuidanceService.instance.speakAndWait(errorShown));
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(errorShown)));
      }
    } finally {
      // Hide loading dialog
      if (mounted) {
        PleaseWaitDialog.hide(context);
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  DateTime? _parseDateTime(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    return DateTime.tryParse(value.toString());
  }

  String _resolveVerificationStatus({
    required Map<String, dynamic>? statusData,
    required String fallbackStatus,
  }) {
    if (statusData?['is_verified'] == true) {
      return 'approved';
    }
    final remoteStatus = statusData?['verification_status'];
    if (remoteStatus is String && remoteStatus.isNotEmpty) {
      return remoteStatus;
    }
    return fallbackStatus;
  }

  /// Warms the encrypted image cache for the two photos the rejection card
  /// compares: the user's primary profile photo and the verification selfie.
  /// Both then render from local bytes when opened offline.
  Future<void> _prefetchComparisonPhotos(
    String userId,
    Map<String, dynamic>? statusData,
  ) async {
    try {
      final verificationPath = statusData?['verification_photo_path']
          ?.toString()
          .trim();
      if (verificationPath != null && verificationPath.isNotEmpty) {
        unawaited(
          StorageHelper.prefetchImageSource(
            verificationPath,
            bucket: 'verification-photos',
          ),
        );
      }
      final localDb = await LocalDbService.instance;
      final localProfile = await localDb.getLocalProfile(userId);
      final photos = localProfile?['photos'];
      if (photos is List && photos.isNotEmpty) {
        final primary = photos.first.toString().trim();
        if (primary.isNotEmpty) {
          unawaited(StorageHelper.prefetchImageSource(primary));
        }
      }
    } catch (_) {}
  }

  /// Loads the verification status for the signed-in user.
  ///
  /// The on-device copy of the payload is applied first, so re-entering the
  /// screen after a rejection renders the AI analysis and the verification
  /// photo immediately. The server copy then refreshes it in the background,
  /// so a decision taken elsewhere (e.g. an admin review) still lands.
  Future<void> _loadVerificationStatus({bool preferCache = true}) async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      if (mounted) {
        setState(() {
          _isLoadingStatus = false;
        });
      }
      return;
    }

    if (preferCache) {
      final cached = await _verificationService.getCachedVerificationStatus(
        userId,
      );
      if (!mounted) return;
      if (cached != null) {
        setState(() {
          _statusData = cached;
          _isLoadingStatus = false;
        });
        unawaited(_prefetchComparisonPhotos(userId, cached));
      }
    }

    // Offline: the copy on disk is all there is, and waiting for the network
    // would only keep the placeholder spinning.
    if (OfflineCacheManager.instance.shouldUseCachedData()) {
      if (mounted) {
        setState(() {
          _isLoadingStatus = false;
        });
      }
      return;
    }

    Map<String, dynamic>? fresh;
    try {
      fresh = await _verificationService
          .getVerificationStatus(userId)
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      fresh = null;
    }
    if (!mounted) return;
    setState(() {
      if (fresh != null) {
        _statusData = fresh;
      }
      _isLoadingStatus = false;
    });
    if (fresh != null) {
      unawaited(_prefetchComparisonPhotos(userId, fresh));
    }
  }

  Future<void> _handleRequestManualReview() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null || _isRequestingManualReview) return;

    final l10n = ref.read(localizationProvider);

    // Accessibility: only the dialog's message content is read — titles and
    // button labels are never spoken — and only while the dialog is actually
    // on screen.
    var dialogVisible = true;
    _enqueueSpoken('manualReviewDialog', () {
      final l = ref.read(localizationProvider);
      return Future.value(l.getString('manualReviewRequestConfirmMessage'));
    }, isRelevant: () => dialogVisible);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(l10n.getString('manualReviewRequestConfirmTitle')),
          content: Text(l10n.getString('manualReviewRequestConfirmMessage')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.getString('cancel')),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.getString('manualReviewRequestButton')),
            ),
          ],
        );
      },
    );
    dialogVisible = false;

    if (confirmed != true || !mounted) return;

    setState(() {
      _isRequestingManualReview = true;
    });
    PleaseWaitDialog.show(context);

    try {
      await _verificationService.requestManualReview();
      final profileNotifier = ref.read(profileEditProvider(user.id).notifier);
      await profileNotifier.applyLocalVerificationUpdate(
        verificationStatus: 'pending',
        isVerified: false,
      );
      // Pull the new server state (pending + no AI rejection details) so the
      // card stops showing the stale rejection content right away.
      await _loadVerificationStatus(preferCache: false);
      try {
        await ref
            .read(profileSyncProvider)
            .syncProfile(user.id, source: 'manual-review-request');
      } catch (_) {}

      if (mounted) {
        final successText = l10n.getString('manualReviewRequestedSuccess');
        _enqueueSpoken('manualReviewResult', () => Future.value(successText));
        final semantic = SemanticColors.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              successText,
              style: TextStyle(color: semantic.onSuccess),
            ),
            backgroundColor: semantic.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        final errorShown =
            '${l10n.getString('failedToSubmitVerification')}: $e';
        // Errors are urgent: they interrupt instead of queueing, and the
        // full shown text (including the error detail) is spoken.
        unawaited(VoiceGuidanceService.instance.speakAndWait(errorShown));
        final colorScheme = Theme.of(context).colorScheme;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              errorShown,
              style: TextStyle(color: colorScheme.onError),
            ),
            backgroundColor: colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        PleaseWaitDialog.hide(context);
        setState(() {
          _isRequestingManualReview = false;
        });
      }
    }
  }

  Widget _buildStatusCard({
    required Map<String, dynamic>? statusData,
    required String fallbackStatus,
    bool isLoading = false,
  }) {
    final l10n = ref.watch(localizationProvider);
    final translationService = ref.watch(translationServiceProvider);

    // Nothing is known about the status yet. Show a placeholder instead of a
    // half-built card: a rejected status without its AI analysis and its
    // verification photo would show the wrong explanation.
    if (isLoading) {
      return Card(
        margin: const EdgeInsets.all(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
          child: const Center(child: CircularProgressIndicator()),
        ),
      );
    }

    Color statusColor;
    IconData statusIcon;
    String statusText;
    String statusDescription;
    Widget? geminiReasoning;
    final mismatchRegions = <_ComparisonRegion>[];

    final userId = Supabase.instance.client.auth.currentUser?.id;
    final profile = userId == null
        ? null
        : ref.watch(userProfileProvider(userId)).asData?.value;
    final profilePhotoPath = (profile != null && profile.photos.isNotEmpty)
        ? profile.photos.first
        : null;
    final verificationPhotoRaw = statusData?['verification_photo_path']
        ?.toString();
    final verificationPhotoPath =
        (verificationPhotoRaw == null || verificationPhotoRaw.trim().isEmpty)
        ? null
        : verificationPhotoRaw;

    final status = _resolveVerificationStatus(
      statusData: statusData,
      fallbackStatus: fallbackStatus,
    );
    final similarityScore = statusData?['verification_similarity_score'];
    final autoRejected = statusData?['verification_auto_rejected'] == true;
    final aiAnalysis = statusData?['verification_ai_analysis'];
    final rejectionReason = aiAnalysis?['reasoning'] as String?;

    // Debug logging for rejection data
    if (status == 'rejected') {
      print('VERIFICATION STATUS DEBUG:');
      print('  - autoRejected: $autoRejected');
      print('  - rejectionReason: $rejectionReason');
      print('  - aiAnalysis: $aiAnalysis');
      print('  - similarityScore: $similarityScore');
    }

    final isDarkTheme = Theme.of(context).brightness == Brightness.dark;
    switch (status) {
      case 'analyzing':
        statusColor = isDarkTheme
            ? Colors.lightBlue.shade300
            : Colors.blue.shade700;
        statusIcon = Icons.hourglass_top;
        statusText = l10n.getString('analyzingPhotos');
        statusDescription = l10n.getString('analyzingPhotosDescription');
        break;
      case 'approved':
        statusColor = SemanticColors.of(context).success;
        statusIcon = Icons.verified;
        statusText = l10n.getString('verified');
        statusDescription = l10n.getString('verifiedDescription');
        break;
      case 'pending':
        // Amber needs opposite ends of the shade ramp per mode to stay
        // readable: dark brown-amber on white, light amber on dark fills.
        statusColor = isDarkTheme
            ? Colors.amber.shade400
            : const Color(0xFF92400E);
        statusIcon = Icons.pending;
        statusText = l10n.getString('underReview');
        statusDescription = l10n.getString('underReviewDescription');
        break;
      case 'rejected':
        statusColor = Theme.of(context).colorScheme.error;
        statusIcon = Icons.error;
        statusText = l10n.getString('verificationRejected');
        statusDescription = autoRejected
            ? l10n.getString('aiDetectedMismatch')
            : l10n.getString('verificationNotApproved');

        // Only show AI Analysis if this was an auto rejection by AI, not manual admin rejection
        if (autoRejected &&
            rejectionReason != null &&
            rejectionReason.isNotEmpty) {
          geminiReasoning = _buildGeminiReasoning(
            rejectionReason,
            l10n,
            translationService,
          );
        }

        // AI-marked mismatch regions (auto rejections only): drawn on top of
        // the two photos below so the user sees exactly what differed.
        final regionsRaw = aiAnalysis is Map
            ? aiAnalysis['mismatchRegions']
            : null;
        if (regionsRaw is List) {
          for (final raw in regionsRaw) {
            final region = _ComparisonRegion.tryParse(raw);
            if (region != null) mismatchRegions.add(region);
          }
        }

        break;
      default:
        statusColor = Theme.of(context).colorScheme.onSurfaceVariant;
        statusIcon = Icons.verified_user;
        statusText = l10n.getString('notVerified');
        statusDescription = l10n.getString('notVerifiedDescription');
    }

    // Accessibility: the current status itself (heading + description) is
    // deliberately NOT spoken. Only the rejection details — AI analysis,
    // photo comparison, review hint — are announced, once per distinct
    // shown content.
    final showComparison =
        status == 'rejected' &&
        (profilePhotoPath != null || verificationPhotoPath != null);
    final statusDetailsSpokenSig =
        '$status|$autoRejected|${rejectionReason ?? ''}|'
        '${mismatchRegions.length}|$profilePhotoPath|$verificationPhotoPath';
    if (_lastStatusDetailsSpokenSig != statusDetailsSpokenSig) {
      _lastStatusDetailsSpokenSig = statusDetailsSpokenSig;
      _enqueueSpoken(
        'statusDetails',
        () => _buildStatusDetailsSpokenText(
          status: status,
          showAnalysis:
              autoRejected &&
              rejectionReason != null &&
              rejectionReason.isNotEmpty,
          rejectionReason: rejectionReason ?? '',
          regions: mismatchRegions,
          showComparison: showComparison,
          showNoBoxesNote: autoRejected,
          l10n: l10n,
          translationService: translationService,
        ),
      );
    }

    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(statusIcon, size: 48, color: statusColor),
            const SizedBox(height: 16),
            Text(
              statusText,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: statusColor,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              statusDescription,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            if (geminiReasoning != null) ...[
              const SizedBox(height: 12),
              geminiReasoning,
            ],
            if (status == 'rejected' &&
                (profilePhotoPath != null ||
                    verificationPhotoPath != null)) ...[
              const SizedBox(height: 12),
              _buildRejectedPhotoComparison(
                regions: mismatchRegions,
                showNoBoxesNote: autoRejected,
                profilePhotoPath: profilePhotoPath,
                verificationPhotoPath: verificationPhotoPath,
                l10n: l10n,
                translationService: translationService,
              ),
            ],
            if (status == 'rejected') ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).dividerColor.withValues(alpha: 0.5),
                  ),
                ),
                child: Column(
                  children: [
                    Text(
                      l10n.getString('requestManualReviewHint'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: _isRequestingManualReview
                          ? null
                          : _handleRequestManualReview,
                      icon: const Icon(Icons.person_search, size: 18),
                      label: Text(l10n.getString('requestManualReview')),
                    ),
                  ],
                ),
              ),
            ],
            if (status == 'analyzing') ...[
              const SizedBox(height: 16),
              const CircularProgressIndicator(),
            ],
          ],
        ),
      ),
    );
  }

  /// Builds the spoken form of the rejection details shown under the status
  /// heading: the AI analysis (translated to the UI language), the
  /// photo-comparison block with each numbered mismatch, and the
  /// manual-review hint. The heading itself is a separate announcement so it
  /// is never repeated when only these details change. Returns an empty
  /// string when there are no details to speak (non-rejected statuses).
  Future<String> _buildStatusDetailsSpokenText({
    required String status,
    required bool showAnalysis,
    required String rejectionReason,
    required List<_ComparisonRegion> regions,
    required bool showComparison,
    required bool showNoBoxesNote,
    required LocalizationState l10n,
    required TranslationService translationService,
  }) async {
    final parts = <String>[];
    if (showAnalysis && rejectionReason.isNotEmpty) {
      parts
        ..add(l10n.getString('aiAnalysisPrefix'))
        ..add(
          await _translateGeminiReasoning(
            rejectionReason,
            l10n,
            translationService,
          ),
        );
    }
    if (showComparison) {
      parts.add(l10n.getString('verificationComparisonTitle'));
      if (regions.isEmpty && showNoBoxesNote) {
        parts.add(l10n.getString('verificationComparisonNoBoxes'));
      } else if (regions.isNotEmpty) {
        parts.add(l10n.getString('verificationComparisonMismatchHeader'));
        for (var i = 0; i < regions.length; i++) {
          final region = regions[i];
          final raw = region.description.isNotEmpty
              ? region.description
              : region.feature;
          if (raw.isEmpty) continue;
          final translated = await _translateGeminiReasoning(
            raw,
            l10n,
            translationService,
          );
          parts.add('${i + 1}. $translated');
        }
      }
    }
    if (status == 'rejected') {
      parts.add(l10n.getString('requestManualReviewHint'));
    }
    return parts.join('. ');
  }

  Widget _buildApprovedState(LocalizationState l10n) {
    final colorScheme = Theme.of(context).colorScheme;
    final semantic = SemanticColors.of(context);

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 32,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 88,
                        height: 88,
                        decoration: BoxDecoration(
                          color: semantic.success.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.verified_rounded,
                          size: 52,
                          color: semantic.success,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        l10n.getString('verified'),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(
                              color: semantic.success,
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        l10n.getString('verifiedDescription'),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back),
                  label: Text(l10n.getString('generalBack')),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: semantic.success,
                    foregroundColor: semantic.onSuccess,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    textStyle: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGeminiReasoning(
    String reasoning,
    LocalizationState l10n,
    TranslationService translationService,
  ) {
    return FutureBuilder<String>(
      future: _memoizedReasoningTranslation(
        reasoning,
        l10n,
        translationService,
      ),
      builder: (context, snapshot) {
        final translatedReasoning = snapshot.data ?? reasoning;
        final errorColor = Theme.of(context).colorScheme.error;

        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: errorColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: errorColor.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.smart_toy, color: errorColor, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    l10n.getString('aiAnalysisPrefix'),
                    style: TextStyle(
                      color: errorColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                translatedReasoning,
                style: TextStyle(color: errorColor, fontSize: 14),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Keeps one in-flight translation per (text, locale) pair.
  ///
  /// The reasoning card is rebuilt whenever the screen rebuilds, so creating
  /// the future inline would re-run the translation on every build.
  Future<String> _memoizedReasoningTranslation(
    String reasoning,
    LocalizationState l10n,
    TranslationService translationService,
  ) {
    final key = TranslationTextCache.cacheKey(
      reasoning,
      l10n.currentLocale.languageCode,
    );
    return _reasoningTranslations.putIfAbsent(
      key,
      () => _translateGeminiReasoning(reasoning, l10n, translationService),
    );
  }

  Future<String> _translateGeminiReasoning(
    String reasoning,
    LocalizationState l10n,
    TranslationService translationService,
  ) async {
    final currentLocale = l10n.currentLocale.languageCode;

    // If UI is English, return reasoning as-is
    if (currentLocale == 'en') {
      return reasoning;
    }

    // The translation is cached on the device (and in memory for this
    // session), so the text is sent to DeepL only once per language.
    return TranslationTextCache.instance.translate(
      reasoning,
      currentLocale,
      () async {
        // Try to identify the language of the reasoning (should be English
        // from Gemini).
        final sourceLang = await translationService.identifyLanguage(reasoning);

        // If already in target language, return as-is (and cache it).
        if (sourceLang == currentLocale) {
          await TranslationTextCache.instance.write(
            reasoning,
            currentLocale,
            reasoning,
          );
          return reasoning;
        }

        // Translate to current UI language
        return translationService.translateText(
          reasoning,
          sourceLang,
          currentLocale,
        );
      },
      // Older builds cached the translation under a key built from
      // `String.hashCode`. Adopt that entry instead of paying for another
      // DeepL request.
      legacyStorageKey: 'gemini_reasoning_${reasoning.hashCode}_$currentLocale',
      // A failed request comes back as the untranslated source text. It is
      // not a translation, so it must not be cached: the next attempt should
      // try again.
      shouldCache: (translated) => translated != reasoning,
    );
  }

  /// Rejected-result comparison: shows the profile photo alongside (or stacked
  /// above, on narrow screens) the verification selfie with the AI's mismatch
  /// rectangles (numbered badges) and a translated, numbered explanation of
  /// each difference.
  Widget _buildRejectedPhotoComparison({
    required List<_ComparisonRegion> regions,
    required bool showNoBoxesNote,
    required String? profilePhotoPath,
    required String? verificationPhotoPath,
    required LocalizationState l10n,
    required TranslationService translationService,
  }) {
    final comparisonErrorColor = Theme.of(context).colorScheme.error;
    final labelStyle = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600);
    final profileLabel = l10n.getString(
      'verificationComparisonProfilePhotoLabel',
    );
    final verificationLabel = l10n.getString(
      'verificationComparisonVerificationPhotoLabel',
    );
    final profileBoxes = regions
        .map((region) => region.profileBox)
        .toList(growable: false);
    final verificationBoxes = regions
        .map((region) => region.verificationBox)
        .toList(growable: false);

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        // On phones the two photos are stacked so both faces stay readable;
        // tablets and desktop keep the classic side-by-side comparison.
        final sideBySide = availableWidth >= 340;
        final gap = sideBySide ? 8.0 : 14.0;
        final photoMaxWidth = sideBySide
            ? min((availableWidth - gap) / 2, 360.0)
            : min(availableWidth, 360.0);
        final screenHeight = MediaQuery.sizeOf(context).height;
        final isLandscape =
            MediaQuery.orientationOf(context) == Orientation.landscape;
        final maxPhotoHeight = isLandscape
            ? (screenHeight * 0.35).clamp(220.0, 360.0).toDouble()
            : (screenHeight * 0.40).clamp(280.0, 360.0).toDouble();

        Widget photo(
          String label,
          String? path,
          String bucket,
          List<List<double>?> boxes,
        ) {
          return _ComparisonPhoto(
            key: ValueKey<String>('$bucket|${path ?? ''}'),
            label: label,
            path: path,
            bucket: bucket,
            boxes: boxes,
            maxWidth: photoMaxWidth,
            maxHeight: maxPhotoHeight,
          );
        }

        final profilePhoto = photo(
          profileLabel,
          profilePhotoPath,
          'profile-photos',
          profileBoxes,
        );
        final verificationPhoto = photo(
          verificationLabel,
          verificationPhotoPath,
          'verification-photos',
          verificationBoxes,
        );

        final photos = sideBySide
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          profileLabel,
                          textAlign: TextAlign.center,
                          style: labelStyle,
                        ),
                      ),
                      SizedBox(width: gap),
                      Expanded(
                        child: Text(
                          verificationLabel,
                          textAlign: TextAlign.center,
                          style: labelStyle,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: Center(child: profilePhoto)),
                      SizedBox(width: gap),
                      Expanded(child: Center(child: verificationPhoto)),
                    ],
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    profileLabel,
                    textAlign: TextAlign.center,
                    style: labelStyle,
                  ),
                  const SizedBox(height: 4),
                  Center(child: profilePhoto),
                  const SizedBox(height: 14),
                  Text(
                    verificationLabel,
                    textAlign: TextAlign.center,
                    style: labelStyle,
                  ),
                  const SizedBox(height: 4),
                  Center(child: verificationPhoto),
                ],
              );

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: comparisonErrorColor.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: comparisonErrorColor.withValues(alpha: 0.25),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.compare, color: comparisonErrorColor, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.getString('verificationComparisonTitle'),
                      style: TextStyle(
                        color: comparisonErrorColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: photos,
                ),
              ),
              const SizedBox(height: 10),
              if (regions.isEmpty && showNoBoxesNote)
                Text(
                  l10n.getString('verificationComparisonNoBoxes'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).textTheme.bodySmall?.color,
                  ),
                )
              else if (regions.isNotEmpty) ...[
                Text(
                  l10n.getString('verificationComparisonMismatchHeader'),
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 6),
                for (var i = 0; i < regions.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 20,
                          height: 20,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.error,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            '${i + 1}',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onError,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _buildTranslatedRegionText(
                            regions[i],
                            l10n,
                            translationService,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildTranslatedRegionText(
    _ComparisonRegion region,
    LocalizationState l10n,
    TranslationService translationService,
  ) {
    final text = region.description.isNotEmpty
        ? region.description
        : region.feature;
    if (text.isEmpty) return const SizedBox.shrink();
    return FutureBuilder<String>(
      // Memoized: the comparison block is rebuilt on every screen rebuild,
      // and an inline future would start a new translation each time.
      future: _memoizedReasoningTranslation(text, l10n, translationService),
      builder: (context, snapshot) {
        return Text(
          snapshot.data ?? text,
          style: Theme.of(context).textTheme.bodySmall,
        );
      },
    );
  }

  Widget _buildVerificationInstructions(
    LocalizationState l10n, {
    required bool showTakePhotoHint,
  }) {
    // Accessibility: speak the requirements card content (each item title +
    // description + gesture instruction) once per gesture/locale shown —
    // the card header is a title and is not spoken.
    final instructionsSpokenSig =
        'instructions|${_currentGesture?.code ?? 'none'}|'
        '${l10n.currentLocale.languageCode}';
    if (_lastInstructionsSpokenSig != instructionsSpokenSig) {
      _lastInstructionsSpokenSig = instructionsSpokenSig;
      _enqueueSpoken('instructions', () {
        final l = ref.read(localizationProvider);
        final parts = <String>[
          '${l.getString('clearSelfiePhoto')}. ${l.getString('clearSelfiePhotoDescription')}',
          '${l.getString('goodLighting')}. ${l.getString('goodLightingDescription')}',
          '${l.getString('noFiltersOrEdits')}. ${l.getString('noFiltersOrEditsDescription')}',
        ];
        final gesture = _currentGesture;
        if (gesture != null) {
          parts.add(
            '${l.getString(gesture.titleKey)}. ${l.getString(gesture.descriptionKey)}',
          );
        }
        return Future.value(parts.join('. '));
      });
    }
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.getString('verificationRequirements'),
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            if (showTakePhotoHint && _selectedImage == null) ...[
              const SizedBox(height: 12),
              _buildTakePhotoHint(l10n),
            ],
            const SizedBox(height: 16),
            _buildInstructionItem(
              Icons.face,
              l10n.getString('clearSelfiePhoto'),
              l10n.getString('clearSelfiePhotoDescription'),
            ),
            const SizedBox(height: 12),
            _buildInstructionItem(
              Icons.light_mode,
              l10n.getString('goodLighting'),
              l10n.getString('goodLightingDescription'),
            ),
            const SizedBox(height: 12),
            _buildInstructionItem(
              Icons.no_accounts,
              l10n.getString('noFiltersOrEdits'),
              l10n.getString('noFiltersOrEditsDescription'),
            ),
            const SizedBox(height: 12),
            if (_currentGesture != null)
              _buildInstructionItem(
                Icons.gesture,
                l10n.getString(_currentGesture!.titleKey),
                l10n.getString(_currentGesture!.descriptionKey),
              ),
            if (_currentGesture != null) const SizedBox(height: 12),
            if (_currentGesture != null)
              _buildGestureReferencePreview(_currentGesture!),
            if (_currentGesture != null) const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _buildTakePhotoHint(LocalizationState l10n) {
    final colorScheme = Theme.of(context).colorScheme;
    final hint = l10n.getString(
      'verificationTakePhotoHint',
      params: {'button': l10n.getString('takePhoto')},
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.touch_app_outlined, size: 20, color: colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              hint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            Icons.arrow_downward_rounded,
            size: 20,
            color: colorScheme.primary,
          ),
        ],
      ),
    );
  }

  Widget _buildPinnedActionBar(
    LocalizationState l10n,
    bool canSubmit,
    SemanticColors semantic,
  ) {
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _pickImage,
                  icon: const Icon(Icons.camera_alt),
                  label: Text(
                    _selectedImage == null
                        ? l10n.getString('takePhoto')
                        : l10n.getString('retakePhoto'),
                  ),
                ),
              ),
              if (_selectedImage != null) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: canSubmit ? _submitVerification : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: semantic.success,
                      foregroundColor: semantic.onSuccess,
                    ),
                    child: _isSubmitting
                        ? SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                semantic.onSuccess,
                              ),
                            ),
                          )
                        : Text(l10n.getString('submitForReview')),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGestureReferencePreview(VerificationGesture gesture) {
    final base = gesture.code.replaceFirst(RegExp(r'_(LEFT|RIGHT)_HAND$'), '');
    final asset = _verificationGestureAssetByBase[base];
    // Pin the bundled Fluent Emoji artwork so the icon's handedness never
    // depends on the platform's emoji font: see [_gestureGlyphNeedsMirror].
    final mirrored = _gestureGlyphNeedsMirror(gesture.code);
    Widget glyph = asset == null
        ? const SizedBox(width: 96, height: 96)
        : Image.asset(
            asset,
            width: 96,
            height: 96,
            fit: BoxFit.contain,
            excludeFromSemantics: true,
          );
    if (mirrored) {
      glyph = Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(-1, 1, 1),
        child: glyph,
      );
    }
    final colorScheme = Theme.of(context).colorScheme;
    final isLeftHand = gesture.code.endsWith('_LEFT_HAND');
    final handLabel = ref
        .read(localizationProvider)
        .getString(
          isLeftHand
              ? 'verificationCaptureHandLeftBadge'
              : 'verificationCaptureHandRightBadge',
        );
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: colorScheme.primary.withValues(alpha: 0.5),
          width: 2,
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          glyph,
          const SizedBox(height: 14),
          // Hand badge (LEFT / RIGHT) so the requested hand is unmistakable
          // at a glance, in the user's language.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: colorScheme.primary,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              handLabel.toUpperCase(),
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: colorScheme.onPrimary,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _scrollToCapturedPhoto() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 180));
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
      final target = _scrollController.position.maxScrollExtent;
      await _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Widget _buildInstructionItem(
    IconData icon,
    String title,
    String description,
  ) {
    return Row(
      children: [
        Icon(icon, size: 24, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
              ),
              Text(
                description,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(
                    context,
                  ).textTheme.bodySmall?.color?.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final semantic = SemanticColors.of(context);
    final userId = Supabase.instance.client.auth.currentUser?.id;
    final profile = userId == null
        ? null
        : ref.watch(userProfileProvider(userId)).asData?.value;
    final cachedVerificationStatus = profile?.isVerified == true
        ? 'approved'
        : profile?.verificationStatus ?? 'unverified';

    return Scaffold(
      appBar: AppBar(
        title: ShrinkText(l10n.getString('verification')),
        actions: const [VoiceGuidanceMuteButton()],
      ),
      body: Builder(
        builder: (context) {
          final statusData = _statusData;
          final effectiveVerificationStatus = _resolveVerificationStatus(
            statusData: statusData,
            fallbackStatus: cachedVerificationStatus,
          );
          // Heal a stale local profile cache (e.g. admin reset the status
          // while the app held an old `pending` value, which previously left
          // the submit button greyed out). The submit button must depend on
          // the fresh server status, not the cached profile.
          if (statusData != null &&
              userId != null &&
              profile != null &&
              (profile.verificationStatus !=
                      (statusData['verification_status']?.toString() ??
                          profile.verificationStatus) ||
                  profile.isVerified != (statusData['is_verified'] == true))) {
            final syncSignature =
                '${statusData['verification_status']}|${statusData['is_verified']}';
            if (_lastStatusSyncSignature != syncSignature) {
              _lastStatusSyncSignature = syncSignature;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                try {
                  ref
                      .read(profileSyncProvider)
                      .syncProfile(
                        userId,
                        source: 'verification-screen-refresh',
                      );
                } catch (_) {}
              });
            }
          }
          final shouldShowVerificationInstructions =
              effectiveVerificationStatus != 'approved';
          // Voice guidance: announce what verification involves once, the
          // first time the instructions are shown. Enqueued synchronously
          // (this runs before the cards below are built) so the intro heads
          // the queue instead of trailing behind the status/instructions.
          // Only the guidance text is spoken — never the AppBar title.
          if (shouldShowVerificationInstructions && !_didSpeakIntro) {
            _didSpeakIntro = true;
            _enqueueSpoken('intro', () {
              final intro = ref
                  .read(localizationProvider)
                  .getString('voiceGuidanceVerificationIntro');
              return Future.value(
                intro.isEmpty || intro.startsWith('[') ? '' : intro,
              );
            });
          }
          final shouldShowSubmissionSection =
              effectiveVerificationStatus == 'unverified' ||
              effectiveVerificationStatus == 'rejected';
          // Voice guidance: tell the user where the action lives, right after
          // the intro. The button is pinned to the bottom of the screen, so
          // this cue can no longer be invalidated by scrolling.
          if (shouldShowSubmissionSection && !_didSpeakTakePhotoHint) {
            _didSpeakTakePhotoHint = true;
            _enqueueSpoken('takePhotoHint', () {
              final l = ref.read(localizationProvider);
              final hint = l.getString(
                'voiceGuidanceVerificationTakePhotoHint',
                params: {'button': l.getString('takePhoto')},
              );
              return Future.value(hint.startsWith('[') ? '' : hint);
            });
          }
          // NOTE: canSubmit intentionally uses the fresh server status
          // (effectiveVerificationStatus), not the cached profile, so an admin
          // reset to `unverified` immediately re-enables resubmission even if
          // the local cache still holds a stale `pending`/`analyzing` value.
          final canSubmit =
              _selectedImage != null &&
              !_isSubmitting &&
              (effectiveVerificationStatus == 'unverified' ||
                  effectiveVerificationStatus == 'rejected');

          if (effectiveVerificationStatus == 'approved') {
            // Accessibility: the approved card (heading + description) is
            // spoken once per locale — the Back button is not spoken.
            final approvedSpokenSig =
                'approved|${l10n.currentLocale.languageCode}';
            if (_lastApprovedSpokenSig != approvedSpokenSig) {
              _lastApprovedSpokenSig = approvedSpokenSig;
              _enqueueSpoken('approved', () {
                final l = ref.read(localizationProvider);
                return Future.value(
                  [
                    l.getString('verified'),
                    l.getString('verifiedDescription'),
                  ].join('. '),
                );
              });
            }
            return LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  controller: _scrollController,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: _buildApprovedState(l10n),
                  ),
                );
              },
            );
          }

          return Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  controller: _scrollController,
                  child: Column(
                    children: [
                      if (userId != null)
                        _buildStatusCard(
                          statusData: statusData,
                          fallbackStatus: cachedVerificationStatus,
                          isLoading: statusData == null && _isLoadingStatus,
                        ),
                      if (shouldShowVerificationInstructions)
                        _buildVerificationInstructions(
                          l10n,
                          showTakePhotoHint: shouldShowSubmissionSection,
                        ),

                      if (shouldShowSubmissionSection) ...[
                        // Accessibility: speak the submission section's privacy
                        // notice once per locale — the section header and action
                        // buttons are titles/labels and are not spoken.
                        Builder(
                          builder: (context) {
                            final submissionSpokenSig =
                                'submission|${l10n.currentLocale.languageCode}';
                            if (_lastSubmissionSpokenSig !=
                                submissionSpokenSig) {
                              _lastSubmissionSpokenSig = submissionSpokenSig;
                              _enqueueSpoken('submission', () async {
                                final l = ref.read(localizationProvider);
                                String? privacy;
                                try {
                                  privacy = await _verificationService
                                      .getPrivacyNotice(
                                        l.currentLocale.languageCode,
                                      )
                                      .timeout(const Duration(seconds: 6));
                                } catch (_) {
                                  privacy = null;
                                }
                                if (privacy != null &&
                                    privacy.trim().isNotEmpty) {
                                  return privacy.trim();
                                }
                                return l.getString('verificationPrivacyNotice');
                              });
                            }
                            return const SizedBox.shrink();
                          },
                        ),
                        const SizedBox(height: 24),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Column(
                            children: [
                              Text(
                                l10n.getString('submitVerificationPhoto'),
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 12),

                              // Privacy notice - prefer Supabase-provided copy with fallback to local copy
                              FutureBuilder<String?>(
                                future: _verificationService.getPrivacyNotice(
                                  l10n.currentLocale.languageCode,
                                ),
                                builder: (context, snapshot) {
                                  final text =
                                      snapshot.data ??
                                      l10n.getString(
                                        'verificationPrivacyNotice',
                                      );
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4.0,
                                      vertical: 8,
                                    ),
                                    child: Text(
                                      text,
                                      textAlign: TextAlign.center,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.color
                                                ?.withValues(alpha: 0.8),
                                          ),
                                    ),
                                  );
                                },
                              ),

                              const SizedBox(height: 8),

                              if (_selectedImage != null) ...[
                                GestureDetector(
                                  onTap: _openSelectedImagePreview,
                                  child: Container(
                                    height: 300,
                                    width: double.infinity,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      image: DecorationImage(
                                        image: MemoryImage(_selectedImage!),
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],

                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
              if (shouldShowSubmissionSection)
                _buildPinnedActionBar(l10n, canSubmit, semantic),
            ],
          );
        },
      ),
    );
  }
}
