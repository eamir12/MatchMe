import 'dart:async';
import 'dart:typed_data';
import 'dart:math';
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

  VerificationGesture? _currentGesture;

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
    // opens so the user knows exactly what to do.
    unawaited(
      VoiceGuidanceService.instance.speakKey(
        'voiceGuidanceVerificationGesture',
        params: {'gesture': gestureLabel, 'description': gestureDescription},
        fallbackText: '$gestureLabel. $gestureDescription',
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
      VoiceGuidanceService.instance.speakKey(
        'voiceGuidanceVerificationSubmitting',
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

        unawaited(VoiceGuidanceService.instance.speakText(message));

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
        unawaited(
          VoiceGuidanceService.instance.speakKey('failedToSubmitVerification'),
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${l10n.getString('failedToSubmitVerification')}: $e',
            ),
          ),
        );
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
        unawaited(
          VoiceGuidanceService.instance.speakText(
            l10n.getString('manualReviewRequestedSuccess'),
          ),
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.getString('manualReviewRequestedSuccess')),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        unawaited(
          VoiceGuidanceService.instance.speakKey('failedToSubmitVerification'),
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${l10n.getString('failedToSubmitVerification')}: $e',
            ),
            backgroundColor: Colors.red,
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
  }) {
    final l10n = ref.watch(localizationProvider);
    final translationService = ref.watch(translationServiceProvider);

    Color statusColor;
    IconData statusIcon;
    String statusText;
    String statusDescription;
    Widget? geminiReasoning;

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

        break;
      default:
        statusColor = Colors.grey;
        statusIcon = Icons.verified_user;
        statusText = l10n.getString('notVerified');
        statusDescription = l10n.getString('notVerifiedDescription');
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

  Widget _buildVerificationInstructions(LocalizationState l10n) {
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
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(child: Text(emoji, style: const TextStyle(fontSize: 58))),
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
          // first time the instructions are shown.
          // NOTE: scheduled as a microtask, NOT addPostFrameCallback:
          // post-frame callbacks only run after the next scheduled frame and
          // an idle engine can delay them for seconds, starting the
          // announcement after the user already left (it then keeps playing
          // on the next screen). The isCurrent check covers an already-gone
          // route; the service generation guard covers the rest.
          if (shouldShowVerificationInstructions && !_didSpeakIntro) {
            _didSpeakIntro = true;
            Future.microtask(() {
              if (!mounted) return;
              if (ModalRoute.of(context)?.isCurrent != true) return;
              unawaited(
                VoiceGuidanceService.instance.speakKey(
                  'voiceGuidanceVerificationIntro',
                ),
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
