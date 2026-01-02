import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:extended_image/extended_image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;

class PhotoEditor {
  /// Show image editor dialog and return edited bytes
  static Future<Uint8List?> _showImageEditor(BuildContext context, Uint8List bytes) async {
    final result = await showDialog<Uint8List>(
      context: context,
      builder: (context) => ImageEditorDialog(bytes: bytes),
    );
    return result;
  }

  /// Pick an image and return its edited bytes.
  static Future<Uint8List?> pickAndEdit({
    required BuildContext context,
    ImageSource source = ImageSource.gallery,
  }) async {
    try {
      final picker = ImagePicker();
      final XFile? file = await picker.pickImage(source: source, imageQuality: 90);
      if (file == null) return null;

      // Read bytes (works on mobile and web)
      final bytes = await file.readAsBytes();

      // Show editor dialog
      return await _showImageEditor(context, bytes); // ignore: use_build_context_synchronously
    } catch (e) {
      // Return null on error to indicate failure
      return null;
    }
  }

  /// Edit existing bytes
  static Future<Uint8List?> editBytes(BuildContext context, Uint8List bytes) async {
    try {
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

      return await _showImageEditor(context, bytes); // ignore: use_build_context_synchronously
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
}

class ImageEditorDialog extends ConsumerStatefulWidget {
  final Uint8List bytes;

  const ImageEditorDialog({super.key, required this.bytes});

  @override
  ConsumerState<ImageEditorDialog> createState() => _ImageEditorDialogState();
}

class _ImageEditorDialogState extends ConsumerState<ImageEditorDialog> {
  final GlobalKey<ExtendedImageEditorState> editorKey = GlobalKey<ExtendedImageEditorState>();

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

    final List<int> out = kIsWeb ? _encodeJpg(decoded) : await compute(_encodeJpg, decoded);
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
                  onPressed: () async {
                    final state = editorKey.currentState;
                    if (state == null) return;

                    try {
                      final bytes = await _exportEditedBytes(state);
                      if (!context.mounted) return;
                      Navigator.of(context).pop(bytes);
                    } catch (_) {
                      if (!context.mounted) return;
                      Navigator.of(context).pop(state.rawImageData);
                    }
                  },
                  child: Text(l10n.getString('done')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}