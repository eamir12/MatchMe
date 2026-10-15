import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/services/verification_service.dart';
import 'package:matchme/services/voice_guidance_service.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/translation_service.dart';
import 'package:matchme/widgets/please_wait_dialog.dart';
import 'package:matchme/widgets/voice_guidance_mute_button.dart';
import 'package:matchme/services/verification_mediapipe.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
/// Coordinates are approximate (normalized 0-1, rendered over a cover-fitted
/// image), so boxes are indicative rather than pixel-exact.
class _MismatchBoxesPainter extends CustomPainter {
  final List<List<double>?> boxes;

  const _MismatchBoxesPainter(this.boxes);

  @override
  void paint(Canvas canvas, Size size) {
    var index = 0;
    for (final box in boxes) {
      if (box == null) continue;
      index++;
      final rect = Rect.fromLTWH(
        box[0] * size.width,
        box[1] * size.height,
        box[2] * size.width,
        box[3] * size.height,
      );
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
      final badgeCenter = Offset(
        (rect.left + 13).clamp(13.0, size.width - 13.0),
        (rect.top + 13).clamp(13.0, size.height - 13.0),
      );
      canvas.drawCircle(badgeCenter, 11, Paint()..color = Colors.red);
      final label = TextPainter(
        text: TextSpan(
          text: '$index',
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

  @override
  bool shouldRepaint(_MismatchBoxesPainter oldDelegate) =>
      oldDelegate.boxes != boxes;
}

const Map<String, String> _verificationGestureEmojiByCode = <String, String>{
  'CLOSED_FIST_RIGHT_HAND': '✊',
  'OPEN_PALM_RIGHT_HAND': '✋',
  'PEACE_SIGN_RIGHT_HAND': '✌️',
  'POINTING_UP_RIGHT_HAND': '☝️',
  'THUMBS_DOWN_RIGHT_HAND': '👎',
  'THUMBS_UP_RIGHT_HAND': '👍',
  'CLOSED_FIST_LEFT_HAND': '✊',
  'OPEN_PALM_LEFT_HAND': '✋',
  'PEACE_SIGN_LEFT_HAND': '✌️',
  'POINTING_UP_LEFT_HAND': '☝️',
  'THUMBS_DOWN_LEFT_HAND': '👎',
  'THUMBS_UP_LEFT_HAND': '👍',
};

/// Whether the platform's default hand emoji must be mirrored to depict the
/// hand that [code] asks for.
///
/// Emoji sets disagree about handedness: Apple (iOS/macOS) and Microsoft
/// (Segoe, Windows) draw hands as RIGHT hands, while Google's Noto
/// (Android, Linux, ChromeOS) draws them as LEFT hands. Mirroring the side
/// that is not the platform default makes the icon match the requested hand
/// on every platform the app runs on.
bool _gestureEmojiNeedsMirror(String code) {
  final notoDefaultHandIsLeft =
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.linux;
  return notoDefaultHandIsLeft
      ? code.endsWith('_RIGHT_HAND')
      : code.endsWith('_LEFT_HAND');
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
        'verificationCaptureHandLeft': l10n.getString(
          'verificationCaptureHandLeft',
        ),
        'verificationCaptureHandRight': l10n.getString(
          'verificationCaptureHandRight',
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
            await VoiceGuidanceService.instance.waitUntilCurrentSpeechFinished();
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
          _scrollToActionButtons();
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
        final bg = (status == 'rejected') ? Colors.red : Colors.green;

        // The snackbar text is shown, so it is spoken — queued behind any
        // announcement already in progress so it can never be dropped.
        _enqueueSpoken('submitResult', () => Future.value(message));

        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message), backgroundColor: bg));
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
      try {
        await ref
            .read(profileSyncProvider)
            .syncProfile(user.id, source: 'manual-review-request');
      } catch (_) {}

      if (mounted) {
        final successText = l10n.getString('manualReviewRequestedSuccess');
        _enqueueSpoken('manualReviewResult', () => Future.value(successText));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(successText), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        final errorShown =
            '${l10n.getString('failedToSubmitVerification')}: $e';
        // Errors are urgent: they interrupt instead of queueing, and the
        // full shown text (including the error detail) is spoken.
        unawaited(VoiceGuidanceService.instance.speakAndWait(errorShown));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorShown), backgroundColor: Colors.red),
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
  }) {
    final l10n = ref.watch(localizationProvider);
    final translationService = ref.watch(translationServiceProvider);

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

    switch (status) {
      case 'analyzing':
        statusColor = Colors.blue;
        statusIcon = Icons.hourglass_top;
        statusText = l10n.getString('analyzingPhotos');
        statusDescription = l10n.getString('analyzingPhotosDescription');
        break;
      case 'approved':
        statusColor = Colors.green;
        statusIcon = Icons.verified;
        statusText = l10n.getString('verified');
        statusDescription = l10n.getString('verifiedDescription');
        break;
      case 'pending':
        statusColor = Colors.orange;
        statusIcon = Icons.pending;
        statusText = l10n.getString('underReview');
        statusDescription = l10n.getString('underReviewDescription');
        break;
      case 'rejected':
        statusColor = Colors.red;
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
        statusColor = Colors.grey;
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
      parts
        ..add(l10n.getString('verificationComparisonTitle'))
        ..add(l10n.getString('verificationComparisonProfilePhotoLabel'))
        ..add(
          l10n.getString('verificationComparisonVerificationPhotoLabel'),
        );
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
                          color: Colors.green.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.verified_rounded,
                          size: 52,
                          color: Colors.green,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        l10n.getString('verified'),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(
                              color: Colors.green,
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
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
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
      future: _translateGeminiReasoning(reasoning, l10n, translationService),
      builder: (context, snapshot) {
        final translatedReasoning = snapshot.data ?? reasoning;

        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.smart_toy, color: Colors.red, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    l10n.getString('aiAnalysisPrefix'),
                    style: const TextStyle(
                      color: Colors.red,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                translatedReasoning,
                style: const TextStyle(color: Colors.red, fontSize: 14),
              ),
            ],
          ),
        );
      },
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

    // Create a cache key based on the reasoning text and target language
    final cacheKey = 'gemini_reasoning_${reasoning.hashCode}_$currentLocale';

    try {
      // Check local storage for cached translation first
      final prefs = await SharedPreferences.getInstance();
      final cachedTranslation = prefs.getString(cacheKey);

      if (cachedTranslation != null && cachedTranslation.isNotEmpty) {
        print('Using cached Gemini reasoning translation');
        return cachedTranslation;
      }

      // No cached translation, perform translation
      // Try to identify the language of the reasoning (should be English from Gemini)
      final sourceLang = await translationService.identifyLanguage(reasoning);

      // If already in target language, return as-is
      if (sourceLang == currentLocale) {
        // Still cache it for consistency
        await prefs.setString(cacheKey, reasoning);
        return reasoning;
      }

      // Translate to current UI language
      final translated = await translationService.translateText(
        reasoning,
        sourceLang,
        currentLocale,
      );

      // Cache the translation
      await prefs.setString(cacheKey, translated);
      print('Cached new Gemini reasoning translation');

      return translated;
    } catch (e) {
      print('Failed to translate Gemini reasoning: $e');
      // Return original reasoning if translation fails
      return reasoning;
    }
  }

  /// Rejected-result comparison: shows the profile photo next to the
  /// verification selfie with the AI's mismatch rectangles (numbered badges)
  /// and a translated, numbered explanation of each difference.
  Widget _buildRejectedPhotoComparison({
    required List<_ComparisonRegion> regions,
    required bool showNoBoxesNote,
    required String? profilePhotoPath,
    required String? verificationPhotoPath,
    required LocalizationState l10n,
    required TranslationService translationService,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.compare, color: Colors.red, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.getString('verificationComparisonTitle'),
                  style: const TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _buildComparisonPhoto(
                  label: l10n.getString(
                    'verificationComparisonProfilePhotoLabel',
                  ),
                  path: profilePhotoPath,
                  bucket: 'profile-photos',
                  boxes: regions
                      .map((region) => region.profileBox)
                      .toList(growable: false),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildComparisonPhoto(
                  label: l10n.getString(
                    'verificationComparisonVerificationPhotoLabel',
                  ),
                  path: verificationPhotoPath,
                  bucket: 'verification-photos',
                  boxes: regions
                      .map((region) => region.verificationBox)
                      .toList(growable: false),
                ),
              ),
            ],
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
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
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
                      decoration: const BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '${i + 1}',
                        style: const TextStyle(
                          color: Colors.white,
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
  }

  Widget _buildComparisonPhoto({
    required String label,
    required String? path,
    required String bucket,
    required List<List<double>?> boxes,
  }) {
    final hasPhoto = path != null && path.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Container(
          height: 150,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: Theme.of(context).dividerColor.withValues(alpha: 0.6),
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (hasPhoto)
                SignedImage(
                  source: path,
                  bucket: bucket,
                  fit: BoxFit.cover,
                  filterQualityLow: true,
                  errorWidget: Icon(
                    Icons.photo_library_outlined,
                    color: Theme.of(context).disabledColor,
                  ),
                )
              else
                Center(
                  child: Icon(
                    Icons.photo_library_outlined,
                    color: Theme.of(context).disabledColor,
                  ),
                ),
              if (hasPhoto) CustomPaint(painter: _MismatchBoxesPainter(boxes)),
            ],
          ),
        ),
      ],
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
      future: _translateGeminiReasoning(text, l10n, translationService),
      builder: (context, snapshot) {
        return Text(
          snapshot.data ?? text,
          style: Theme.of(context).textTheme.bodySmall,
        );
      },
    );
  }

  Widget _buildVerificationInstructions(LocalizationState l10n) {
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

  Widget _buildGestureReferencePreview(VerificationGesture gesture) {
    final emoji = _verificationGestureEmojiByCode[gesture.code] ?? '🖐️';
    // Emoji sets disagree about handedness, so mirroring is decided per
    // platform: see [_gestureEmojiNeedsMirror].
    final mirrored = _gestureEmojiNeedsMirror(gesture.code);
    Widget glyph = Text(emoji, style: const TextStyle(fontSize: 88, height: 1.0));
    if (mirrored) {
      glyph = Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(-1, 1, 1),
        child: glyph,
      );
    }
    final colorScheme = Theme.of(context).colorScheme;
    final handLabel = ref
        .read(localizationProvider)
        .getString(
          mirrored ? 'verificationCaptureHandLeft' : 'verificationCaptureHandRight',
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

  void _scrollToActionButtons() {
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
    final userId = Supabase.instance.client.auth.currentUser?.id;
    final profile = userId == null
        ? null
        : ref.watch(userProfileProvider(userId)).asData?.value;
    final cachedVerificationStatus = profile?.isVerified == true
        ? 'approved'
        : profile?.verificationStatus ?? 'unverified';

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.getString('verification')),
        actions: const [VoiceGuidanceMuteButton()],
      ),
      body: FutureBuilder<Map<String, dynamic>?>(
        future: userId == null
            ? Future<Map<String, dynamic>?>.value(null)
            : _verificationService.getVerificationStatus(userId),
        builder: (context, snapshot) {
          final statusData = snapshot.data;
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
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              try {
                ref
                    .read(profileSyncProvider)
                    .syncProfile(userId, source: 'verification-screen-refresh');
              } catch (_) {}
            });
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

          return SingleChildScrollView(
            controller: _scrollController,
            child: Column(
              children: [
                if (userId != null)
                  _buildStatusCard(
                    statusData: statusData,
                    fallbackStatus: cachedVerificationStatus,
                  ),
                if (shouldShowVerificationInstructions)
                  _buildVerificationInstructions(l10n),

                if (shouldShowSubmissionSection) ...[
                  // Accessibility: speak the submission section's privacy
                  // notice once per locale — the section header and action
                  // buttons are titles/labels and are not spoken.
                  Builder(
                    builder: (context) {
                      final submissionSpokenSig =
                          'submission|${l10n.currentLocale.languageCode}';
                      if (_lastSubmissionSpokenSig != submissionSpokenSig) {
                        _lastSubmissionSpokenSig = submissionSpokenSig;
                        _enqueueSpoken('submission', () async {
                          final l = ref.read(localizationProvider);
                          String? privacy;
                          try {
                            privacy = await _verificationService
                                .getPrivacyNotice(l.currentLocale.languageCode)
                                .timeout(const Duration(seconds: 6));
                          } catch (_) {
                            privacy = null;
                          }
                          if (privacy != null && privacy.trim().isNotEmpty) {
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
                                l10n.getString('verificationPrivacyNotice');
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4.0,
                                vertical: 8,
                              ),
                              child: Text(
                                text,
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.bodySmall
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

                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: _pickImage,
                                icon: const Icon(Icons.camera),
                                label: Text(
                                  _selectedImage == null
                                      ? l10n.getString('takePhoto')
                                      : l10n.getString('retakePhoto'),
                                ),
                              ),
                            ),
                            if (_selectedImage != null) ...[
                              const SizedBox(width: 16),
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: canSubmit
                                      ? _submitVerification
                                      : null,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.green,
                                    foregroundColor: Colors.white,
                                  ),
                                  child: _isSubmitting
                                      ? const SizedBox(
                                          height: 20,
                                          width: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            valueColor:
                                                AlwaysStoppedAnimation<Color>(
                                                  Colors.white,
                                                ),
                                          ),
                                        )
                                      : Text(l10n.getString('submitForReview')),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 32),
              ],
            ),
          );
        },
      ),
    );
  }
}
