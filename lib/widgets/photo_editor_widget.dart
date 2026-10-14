import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:extended_image/extended_image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/photo_moderation_rejection.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/photo_prescreen_service.dart';
import 'package:matchme/services/voice_guidance_service.dart';
import 'package:matchme/web_imports.dart' as web;
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;
import 'package:matchme/widgets/custom_camera_widget.dart';
import 'package:matchme/widgets/photo_rejection_dialog.dart';
import 'package:matchme/widgets/please_wait_dialog.dart';
import 'package:matchme/services/primary_selfie_capture.dart';

class PhotoEditor {
  /// Show image editor dialog and return edited bytes
  static Future<Uint8List?> _showImageEditor(
    BuildContext context,
    Uint8List bytes,
  ) async {
    final result = await showDialog<Uint8List>(
      context: context,
      builder: (context) => ImageEditorDialog(bytes: bytes),
    );
    return result;
  }

  /// Pick an image, let the user crop/adjust it, run the prescreen on the
  /// final result and return bytes ready for upload — or null if the user
  /// cancelled / could not produce a compliant photo. [ref] is required:
  /// every caller must run the prescreen — there is deliberately no
  /// prescreen-less variant.
  ///
  /// [onChooseAnother] is invoked when the prescreen dialog's "Choose
  /// another photo" action is tapped: it should re-pick a candidate and
  /// return it (or null when the user backs out). Without it, that action
  /// aborts the whole flow and returns null.
  static Future<Uint8List?> pickAndEdit({
    required BuildContext context,
    ImageSource source = ImageSource.gallery,
    String? preparingMessage,
    bool isPrimaryPhoto = false,
    required WidgetRef ref,
    Set<String>? existingHashes,
    Set<String>? existingPerceptualHashes,
    Future<Uint8List?> Function()? onChooseAnother,
  }) async {
    final bytes = await pickCandidateBytes(
      context: context,
      source: source,
      preparingMessage: preparingMessage,
      isPrimaryPhoto: isPrimaryPhoto,
      ref: ref,
    );
    if (bytes == null || !context.mounted) {
      return null;
    }

    final finalBytes = await editWithPrescreen(
      context: context,
      bytes: bytes,
      isPrimaryPhoto: isPrimaryPhoto,
      ref: ref,
      existingHashes: existingHashes,
      existingPerceptualHashes: existingPerceptualHashes,
      onChooseAnother: onChooseAnother,
    );
    return finalBytes;
  }

  /// Pick stage only — the camera/gallery branch of [pickCandidateBytes]
  /// without the editor or prescreen. Primary-photo camera picks use the
  /// live-gated selfie capture; everything else is prepared (compressed)
  /// and returned. Null when the user cancels or picking fails.
  static Future<Uint8List?> pickCandidateBytes({
    required BuildContext context,
    ImageSource source = ImageSource.gallery,
    String? preparingMessage,
    bool isPrimaryPhoto = false,
    required WidgetRef ref,
  }) async {
    Uint8List? bytes;
    try {
      if (source == ImageSource.camera && isPrimaryPhoto) {
        // Primary selfie on any platform: live-gated capture reusing the
        // verification selfie UX in face-only mode. The oval turns green
        // only while a single clear face is inside it, the face must hold
        // steady inside the oval (~2s + 1s best-frame selection), and
        // auto-capture waits for the spoken instructions to finish — a
        // body-only shot can never satisfy the gate.
        if (!context.mounted) return null;
        bytes = await openPrimarySelfieCapture(context: context, ref: ref);
        if (bytes == null || !context.mounted) return null;
        bytes = await _prepareBytes(context, bytes, preparingMessage);
      } else if (kIsWeb && source == ImageSource.camera) {
        bytes = await web.pickImageBytesFromCamera(capture: 'user');
        if (bytes == null || !context.mounted) return null;
        bytes = await _prepareBytes(context, bytes, preparingMessage);
      } else if (source == ImageSource.camera) {
        bytes = await showCustomCamera(context: context, useFrontCamera: true);
        if (bytes == null || !context.mounted) return null;
        bytes = await _prepareBytes(context, bytes, preparingMessage);
      } else {
        final picker = ImagePicker();
        final XFile? file = await picker.pickImage(
          source: source,
          imageQuality: await (() async {
            try {
              return await AppConfigService().getInt(
                'profile.image_quality_percent',
                defaultValue: 90,
              );
            } catch (e) {
              return 90;
            }
          })(),
        );
        if (file == null || !context.mounted) {
          return null;
        }
        bytes = await _prepareBytesFromFile(context, file, preparingMessage);
      }
    } catch (e) {
      return null;
    }
    if (bytes == null || !context.mounted) {
      return null;
    }
    return bytes;
  }

  /// Open the editor on [bytes], run the prescreen on the edited result and
  /// loop until the photo passes, the user fixes it, or gives up.
  ///
  /// Prescreen runs AFTER the editor so the user can fix issues (crop away
  /// extra people, zoom in on a small face) before being judged. If the
  /// prescreen fails, the dialog offers "Adjust photo" to re-open the editor
  /// with the same image, or "Choose another photo" to pick a different
  /// candidate via [onChooseAnother] (or abort when it is null).
  static Future<Uint8List?> editWithPrescreen({
    required BuildContext context,
    required Uint8List bytes,
    bool isPrimaryPhoto = false,
    required WidgetRef ref,
    Set<String>? existingHashes,
    Set<String>? existingPerceptualHashes,
    Future<Uint8List?> Function()? onChooseAnother,
  }) async {
    Uint8List candidate = bytes;
    while (true) {
      final editorContext = context;
      if (!editorContext.mounted) return null;
      // ignore: use_build_context_synchronously
      final edited = await _showImageEditor(editorContext, candidate);
      if (edited == null) return null; // user cancelled
      candidate = edited;

      final prescreenService = ref.read(photoPrescreenServiceProvider);
      final prescreenResult = await prescreenService.prescreenPhoto(
        candidate,
        isPrimary: isPrimaryPhoto,
        existingHashes: existingHashes,
        existingPerceptualHashes: existingPerceptualHashes,
      );
      if (prescreenResult.passed) {
        return await compressImage(candidate);
      }

      if (!context.mounted) return null;
      final action = await showPrescreenFailureDialog(
        context,
        prescreenResult,
        ref,
        photoBytes: candidate,
      );
      if (action == PrescreenFailureAction.adjust) {
        continue; // re-open the editor on the same image
      }
      // "Choose another photo" (or dismissed): re-pick when the caller
      // supports it, otherwise abort. The caller's old photo — e.g. the
      // current primary when replacing — is kept either way.
      if (onChooseAnother == null) return null;
      final next = await onChooseAnother();
      if (next == null || next.isEmpty) return null;
      candidate = next;
    }
  }

  static Future<Uint8List?> _prepareBytesFromFile(
    BuildContext context,
    XFile file,
    String? preparingMessage,
  ) async {
    _showPreparingDialog(context, preparingMessage);
    try {
      final raw = await file.readAsBytes();
      return await compressImage(raw);
    } finally {
      _hidePreparingDialog(context);
    }
  }

  static Future<Uint8List> _prepareBytes(
    BuildContext context,
    Uint8List raw,
    String? preparingMessage,
  ) async {
    _showPreparingDialog(context, preparingMessage);
    try {
      return await compressImage(raw);
    } finally {
      _hidePreparingDialog(context);
    }
  }

  static void _showPreparingDialog(BuildContext context, String? message) {
    if (!context.mounted) return;
    PleaseWaitDialog.show(context, message: message);
  }

  static void _hidePreparingDialog(BuildContext context) {
    if (!context.mounted) return;
    PleaseWaitDialog.hide(context);
  }

  /// Pick a camera image with front camera preference for verification
  static Future<Uint8List?> pickVerificationPhoto(BuildContext context) async {
    // This method is now handled by the verification screen directly
    // using the CameraPreviewWidget for live preview
    throw UnimplementedError(
      'Use CameraPreviewWidget directly from verification screen',
    );
  }

  /// Edit existing bytes
  static Future<Uint8List?> editBytes(
    BuildContext context,
    Uint8List bytes,
  ) async {
    try {
      if (!context.mounted) return bytes;
      return await _showImageEditor(context, bytes);
    } catch (e) {
      return bytes; // Return original on error
    }
  }

  /// Edit an image from a file path or URL
  static Future<Uint8List?> editImage({
    required BuildContext context,
    required String imagePath,
  }) async {
    try {
      // Download the image bytes directly from the URL
      final bytes = await _downloadImageBytes(imagePath);
      if (bytes == null) return null;

      final editorContext = context;
      if (!editorContext.mounted) return null;
      // ignore: use_build_context_synchronously
      return await _showImageEditor(editorContext, bytes);
    } catch (e) {
      return null;
    }
  }

  static Future<Uint8List?> _downloadImageBytes(String imageUrl) async {
    try {
      final response = await http.get(Uri.parse(imageUrl));
      if (response.statusCode == 200) {
        return response.bodyBytes;
      } else {
        return null;
      }
    } catch (e) {
      return null;
    }
  }

  static Future<Uint8List> compressImage(Uint8List bytes) async {
    if (kIsWeb) {
      return _compressImageSync(bytes);
    }
    return await compute(_compressImageSync, bytes);
  }
}

Uint8List _compressImageSync(Uint8List original) {
  try {
    final image = img.decodeImage(original);
    if (image == null) return original;

    img.Image target = image;
    if (target.width > 1200 || target.height > 1200) {
      if (target.width >= target.height) {
        target = img.copyResize(target, width: 1200);
      } else {
        target = img.copyResize(target, height: 1200);
      }
    }

    return Uint8List.fromList(img.encodeJpg(target, quality: 85));
  } catch (e) {
    debugPrint('Image compression failed: $e');
    return original;
  }
}

class ImageEditorDialog extends ConsumerStatefulWidget {
  final Uint8List bytes;

  const ImageEditorDialog({super.key, required this.bytes});

  @override
  ConsumerState<ImageEditorDialog> createState() => _ImageEditorDialogState();
}

class _ImageEditorDialogState extends ConsumerState<ImageEditorDialog> {
  final GlobalKey<ExtendedImageEditorState> editorKey =
      GlobalKey<ExtendedImageEditorState>();
  bool _isProcessing = false;

  static img.Image? _decodeImageBytes(Uint8List data) => img.decodeImage(data);
  static List<int> _encodeJpg(img.Image image) => img.encodeJpg(image);

  Future<Uint8List> _exportEditedBytes(ExtendedImageEditorState state) async {
    final Rect? cropRect = state.getCropRect();
    final EditActionDetails? action = state.editAction;

    // If nothing to apply, return original
    final bool needsCrop = cropRect != null && (action?.needCrop ?? false);
    final bool needsRotate = action?.hasRotateDegrees ?? false;
    final bool needsFlip = action?.flipY ?? false;
    if (!needsCrop && !needsRotate && !needsFlip) {
      return state.rawImageData;
    }

    img.Image? decoded;
    if (kIsWeb) {
      decoded = _decodeImageBytes(state.rawImageData);
    } else {
      decoded = await compute(_decodeImageBytes, state.rawImageData);
    }
    if (decoded == null) return state.rawImageData;

    // Normalize EXIF orientation first.
    decoded = img.bakeOrientation(decoded);

    if (needsRotate) {
      decoded = img.copyRotate(decoded, angle: action!.rotateDegrees);
    }
    if (needsFlip) {
      decoded = img.flip(decoded, direction: img.FlipDirection.horizontal);
    }
    if (needsCrop) {
      final crop = cropRect;
      decoded = img.copyCrop(
        decoded,
        x: crop.left.toInt(),
        y: crop.top.toInt(),
        width: crop.width.toInt(),
        height: crop.height.toInt(),
      );
    }

    final List<int> out = kIsWeb
        ? _encodeJpg(decoded)
        : await compute(_encodeJpg, decoded);
    return Uint8List.fromList(out);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    return Dialog(
      child: SizedBox(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(
          children: [
            AppBar(
              title: Text(l10n.getString('editPhoto')),
              actions: [
                IconButton(
                  icon: const Icon(Icons.rotate_right),
                  onPressed: () {
                    editorKey.currentState?.rotate(degree: 90);
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.flip),
                  onPressed: () {
                    editorKey.currentState?.flip();
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.restore),
                  onPressed: () {
                    editorKey.currentState?.reset();
                  },
                ),
              ],
            ),
            Expanded(
              child: ExtendedImage.memory(
                widget.bytes,
                fit: BoxFit.contain,
                mode: ExtendedImageMode.editor,
                extendedImageEditorKey: editorKey,
                initEditorConfigHandler: (state) {
                  return EditorConfig(
                    maxScale: 8.0,
                    cropRectPadding: const EdgeInsets.all(20.0),
                    hitTestSize: 20.0,
                    cropAspectRatio: null, // allow freeform cropping
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.getString('cancel')),
                ),
                ElevatedButton(
                  onPressed: _isProcessing
                      ? null
                      : () async {
                          final state = editorKey.currentState;
                          if (state == null) return;

                          setState(() => _isProcessing = true);
                          try {
                            final bytes = await _exportEditedBytes(state);
                            if (!context.mounted) return;
                            Navigator.of(context).pop(bytes);
                          } catch (_) {
                            if (!context.mounted) return;
                            Navigator.of(context).pop(state.rawImageData);
                          }
                        },
                  child: _isProcessing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.getString('done')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

enum PrescreenFailureAction { adjust, chooseAnother }

/// Visual failure dialog: shows the rejected photo large, with the problem
/// regions (face + offending text/object boxes) highlighted when the native
/// analyzer reported coordinates, one row per failed rule (all issues at
/// once, so a single retake can fix everything), and actions to fix the
/// current photo or pick a different one. Returns what the user chose (null
/// when dismissed).
Future<PrescreenFailureAction?> showPrescreenFailureDialog(
  BuildContext context,
  PhotoPrescreenResult result,
  WidgetRef ref, {
  Uint8List? photoBytes,
}) async {
  final l10n = ref.read(localizationProvider);

  final reasons = result.failureReasons.isNotEmpty
      ? result.failureReasons
      : <PrescreenFailureReason?>[result.failureReason];
  final messages = reasons
      .map(
        (reason) => reason == null
            ? (result.errorMessage ?? l10n.getString('photoErrorGeneral'))
            : l10n.getString(prescreenFailureL10nKey(reason)),
      )
      .toList();

  // Decode the photo dimensions so the overlay boxes can be mapped onto the
  // BoxFit.contain rect (same approach as the AI-moderation rejection
  // dialog). Prescreen issue boxes are normalized 0..1, so only the aspect
  // ratio matters.
  int? imageWidth;
  int? imageHeight;
  if (photoBytes != null && photoBytes.isNotEmpty) {
    try {
      final codec = await ui.instantiateImageCodec(
        photoBytes,
        targetWidth: 720,
      );
      final frame = await codec.getNextFrame();
      imageWidth = frame.image.width;
      imageHeight = frame.image.height;
      frame.image.dispose();
      codec.dispose();
    } catch (_) {
      imageWidth = null;
    }
  }

  final issueBoxes = <PhotoIssueBox>[];
  // The face box is only drawn when the face itself is what the rejection is
  // about — being covered by text/an object, or failing a face rule. A pure
  // document rejection (card elsewhere in frame) highlights only the card:
  // boxing a perfectly fine face would suggest it is the problem.
  final faceIsTheSubject = reasons.any(
    (reason) =>
        reason == PrescreenFailureReason.textOverFace ||
        reason == PrescreenFailureReason.objectOverFace ||
        reason == PrescreenFailureReason.multipleFaces ||
        reason == PrescreenFailureReason.noFaceOrBody ||
        reason == PrescreenFailureReason.noFaceDetected ||
        reason == PrescreenFailureReason.faceNotVisible ||
        reason == PrescreenFailureReason.faceTooSmall ||
        reason == PrescreenFailureReason.eyesClosed,
  );
  if (faceIsTheSubject && result.faceBox != null) {
    issueBoxes.add(
      PhotoIssueBox(
        x: result.faceBox!['x'] ?? 0,
        y: result.faceBox!['y'] ?? 0,
        w: result.faceBox!['w'] ?? 0,
        h: result.faceBox!['h'] ?? 0,
        label: 'face',
      ),
    );
  }
  // The offending regions (text blocks / held objects over the face).
  for (final box in result.issueBoxes) {
    final parsed = PhotoIssueBox.fromJson(box, fallbackLabel: 'text');
    if (parsed != null) issueBoxes.add(parsed);
  }
  // Generic text rejection (card/sign away from the face): the native
  // analyzer knows where the text blocks are — mark them, so the highlight
  // sits on the actual issue instead of showing an unexplained rejection.
  if (reasons.contains(PrescreenFailureReason.textDetected) &&
      !issueBoxes.any((box) => box.label == 'text') &&
      result.textAnalysis != null) {
    for (final block in result.textAnalysis!.blocks) {
      final w = block['w'] ?? 0;
      final h = block['h'] ?? 0;
      if (w <= 0 || h <= 0) continue;
      issueBoxes.add(
        PhotoIssueBox(
          x: block['x'] ?? 0,
          y: block['y'] ?? 0,
          w: w,
          h: h,
          label: 'text',
        ),
      );
    }
  }

  final (IconData icon, Color iconColor) = switch (reasons.first) {
    PrescreenFailureReason.multipleFaces ||
    PrescreenFailureReason.noFaceOrBody ||
    PrescreenFailureReason.noFaceDetected ||
    PrescreenFailureReason.bodyShotNotAllowed ||
    PrescreenFailureReason.faceTooSmall ||
    PrescreenFailureReason.faceNotVisible ||
    PrescreenFailureReason.eyesClosed ||
    PrescreenFailureReason.textOverFace ||
    PrescreenFailureReason.objectOverFace ||
    PrescreenFailureReason.documentDetected => (
      Icons.face_retouching_off,
      Colors.orange.shade700,
    ),
    PrescreenFailureReason.imageTooBlurry ||
    PrescreenFailureReason.imageTooDark ||
    PrescreenFailureReason.imageTooBright => (
      Icons.auto_awesome_motion_outlined,
      Colors.orange.shade700,
    ),
    PrescreenFailureReason.duplicatePhoto => (
      Icons.photo_library_outlined,
      Colors.orange.shade700,
    ),
    _ => (Icons.image_not_supported_outlined, Colors.red.shade400),
  };

  if (!context.mounted) return null;
  return showDialog<PrescreenFailureAction>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      // Voice guidance repeats the first reason so the user hears what to fix
      // (same localized string shown first in the dialog).
      unawaited(VoiceGuidanceService.instance.speakText(messages.first));
      return AlertDialog(
        title: Row(
          children: [
            Icon(icon, color: iconColor),
            const SizedBox(width: 12),
            Expanded(child: Text(l10n.getString('photoPrescreenFailedTitle'))),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (photoBytes != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: double.infinity,
                    height: 360,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.memory(photoBytes, fit: BoxFit.contain),
                        if (imageWidth != null &&
                            imageHeight != null &&
                            issueBoxes.isNotEmpty)
                          Positioned.fill(
                            child: CustomPaint(
                              painter: IssueBoxesPainter(
                                boxes: issueBoxes,
                                imageWidth: imageWidth,
                                imageHeight: imageHeight,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              // Every failed rule, each with its own bullet — not just the
              // first — so one retake can address them all.
              for (final message in messages)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Icon(Icons.circle, size: 6),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(message)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop(PrescreenFailureAction.chooseAnother),
            child: Text(l10n.getString('photoPrescreenChooseAnother')),
          ),
          ElevatedButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(PrescreenFailureAction.adjust),
            child: Text(l10n.getString('photoPrescreenAdjustPhoto')),
          ),
        ],
      );
    },
  );
}
