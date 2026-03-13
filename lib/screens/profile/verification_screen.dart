import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/verification_service.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/translation_service.dart';
import 'package:matchme/widgets/please_wait_dialog.dart';
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
    code: 'PEACE_SIGN_RIGHT_HAND',
    titleKey: 'verificationGesturePeaceSignTitle',
    descriptionKey: 'verificationGesturePeaceSignDescription',
    aiPromptText:
        'The person must clearly show a V-shaped peace sign with their right hand next to their face, with the fingers clearly visible.',
  ),
  VerificationGesture(
    code: 'THUMBS_UP_RIGHT_HAND',
    titleKey: 'verificationGestureThumbsUpTitle',
    descriptionKey: 'verificationGestureThumbsUpDescription',
    aiPromptText:
        'The person must clearly show a thumbs-up with their right hand next to their face, with the thumb clearly visible.',
  ),
];

VerificationGesture? _cachedVerificationGesture;
final Random _gestureRandom = Random();

VerificationGesture _getSessionVerificationGesture() {
  if (_cachedVerificationGesture != null) {
    return _cachedVerificationGesture!;
  }
  if (_availableVerificationGestures.isEmpty) {
    throw StateError('No verification gestures configured');
  }
  _cachedVerificationGesture =
      _availableVerificationGestures[_gestureRandom.nextInt(_availableVerificationGestures.length)];
  return _cachedVerificationGesture!;
}

class VerificationScreen extends ConsumerStatefulWidget {
  const VerificationScreen({super.key});

  @override
  ConsumerState<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends ConsumerState<VerificationScreen> {
  final VerificationService _verificationService = VerificationService();

  Uint8List? _selectedImage;
  bool _isSubmitting = false;
  String _verificationStatus = 'unverified';

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
    _loadVerificationStatus();
    _selectRandomGestureIfNeeded();
  }

  void _selectRandomGestureIfNeeded() {
    if (_currentGesture != null) {
      return;
    }
    setState(() {
      _currentGesture = _getSessionVerificationGesture();
    });
  }

  Future<void> _loadVerificationStatus() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user != null) {
      final status = await _verificationService.getVerificationStatus(user.id);
      if (status != null && mounted) {
        setState(() {
          _verificationStatus = status['verification_status'] ?? 'unverified';
        });
      }
    }
  }

  Future<void> _pickImage() async {
    _selectRandomGestureIfNeeded();
    if (_currentGesture == null) return;
    final l10n = ref.read(localizationProvider);
    final gestureLabel = l10n.getString(_currentGesture!.titleKey);

    openMediaPipeVerificationCapture(
      gestureCode: _currentGesture!.code,
      gestureLabel: gestureLabel,
      captureStrings: <String, String>{
        'verificationCaptureLoading': l10n.getString('verificationCaptureLoading'),
        'verificationCaptureInstruction': l10n.getString('verificationCaptureInstruction'),
        'verificationCaptureStatusShowGesture': l10n.getString('verificationCaptureStatusShowGesture'),
        'verificationCaptureStatusShowFace': l10n.getString('verificationCaptureStatusShowFace'),
        'verificationCaptureStatusGestureDetected': l10n.getString('verificationCaptureStatusGestureDetected'),
        'verificationCaptureStatusUseCorrectHand': l10n.getString('verificationCaptureStatusUseCorrectHand'),
        'verificationCaptureHandLeft': l10n.getString('verificationCaptureHandLeft'),
        'verificationCaptureHandRight': l10n.getString('verificationCaptureHandRight'),
        'verificationCaptureCameraOrModelError': l10n.getString('verificationCaptureCameraOrModelError'),
        'verificationCaptureFailedToLoad': l10n.getString('verificationCaptureFailedToLoad'),
      },
      context: context,
      onPhoto: (Uint8List? bytes) {
        if (bytes != null && mounted) {
          setState(() {
            _selectedImage = bytes;
          });
        }
      },
    );
  }

  Future<void> _submitVerification() async {
    if (_selectedImage == null) return;

    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    final l10n = ref.watch(localizationProvider);

    setState(() {
      _isSubmitting = true;
      _verificationStatus = 'analyzing';
    });

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

      if (mounted) {
        setState(() {
          _verificationStatus = status ?? _verificationStatus;
          _selectedImage = null;
        });

        final message =
            (status == 'rejected')
                ? l10n.getString('verificationNotApproved')
                : l10n.getString('verificationSubmittedSuccess');
        final bg =
            (status == 'rejected')
                ? Colors.red
                : Colors.green;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: bg,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
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


  Widget _buildStatusCard() {
    final l10n = ref.watch(localizationProvider);
    final translationService = ref.watch(translationServiceProvider);

    return FutureBuilder<Map<String, dynamic>?>(
      future: _verificationService.getVerificationStatus(
        Supabase.instance.client.auth.currentUser?.id ?? '',
      ),
      builder: (context, snapshot) {
        final statusData = snapshot.data;

        Color statusColor;
        IconData statusIcon;
        String statusText;
        String statusDescription;
        Widget? geminiReasoning;

        final status =
            statusData?['verification_status'] ?? _verificationStatus;
        final similarityScore = statusData?['verification_similarity_score'];
        final autoRejected = statusData?['verification_auto_rejected'] == true;
        final aiAnalysis = statusData?['verification_ai_analysis'];
        final rejectionReason = aiAnalysis?['reasoning'] as String?;

        // Debug logging for rejection data
        if (status == 'rejected') {
          debugPrint('🔍 VERIFICATION STATUS DEBUG:');
          debugPrint('  - autoRejected: $autoRejected');
          debugPrint('  - rejectionReason: $rejectionReason');
          debugPrint('  - aiAnalysis: $aiAnalysis');
          debugPrint('  - similarityScore: $similarityScore');
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
            statusDescription =
                autoRejected
                    ? l10n.getString('aiDetectedMismatch')
                    : l10n.getString('verificationNotApproved');

            // Handle Gemini reasoning separately - show it if available, regardless of autoRejected flag
            if (rejectionReason != null && rejectionReason.isNotEmpty) {
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
                if (geminiReasoning != null) ...[
                  const SizedBox(height: 12),
                  geminiReasoning,
                ],
                if (status == 'analyzing') ...[
                  const SizedBox(height: 16),
                  const CircularProgressIndicator(),
                ],
              ],
            ),
          ),
        );
      },
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
        debugPrint('Using cached Gemini reasoning translation');
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
      debugPrint('Cached new Gemini reasoning translation');

      return translated;
    } catch (e) {
      debugPrint('Failed to translate Gemini reasoning: $e');
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
          ],
        ),
      ),
    );
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
    final canSubmit =
        _selectedImage != null &&
        !_isSubmitting &&
        _verificationStatus != 'pending';

    return Scaffold(
      appBar: AppBar(title: Text(l10n.getString('verification'))),
      body: SingleChildScrollView(
        child: Column(
          children: [
            _buildStatusCard(),
            _buildVerificationInstructions(l10n),

            if (_verificationStatus == 'unverified' ||
                _verificationStatus == 'rejected') ...[
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    Text(
                      l10n.getString('submitVerificationPhoto'),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
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
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(
                              color: Theme.of(
                                context,
                              ).textTheme.bodySmall?.color?.withValues(alpha: 0.8),
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
                              onPressed: canSubmit ? _submitVerification : null,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
                                foregroundColor: Colors.white,
                              ),
                              child:
                                  _isSubmitting
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
      ),
    );
  }
}
