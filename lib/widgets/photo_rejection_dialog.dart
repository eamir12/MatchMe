// lib/widgets/photo_rejection_dialog.dart
// Rich rejection dialog for profile-photo moderation: shows the photo the user
// tried to add with the problem regions highlighted, the fixed translated
// explanation, and the AI's own short message.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:matchme/models/photo_moderation_rejection.dart';
import 'package:matchme/providers/locale_provider.dart';

const Set<String> _knownIssueLabels = {
  'text',
  'watermark',
  'screenshot',
  'meme',
  'face',
  'document',
};

Color _issueColor(String label) =>
    label == 'face' || label == 'document' ? Colors.orange : Colors.red;

/// Decodes the photo dimensions, then shows the rejection dialog. Falls back
/// to a plain message dialog when the image cannot be decoded.
///
/// Returns true when the user chose "Try again" (only offered when
/// [offerRetry] is true — used when a previous photo is still in place, e.g.
/// replacing the primary, so the caller can restart the pick flow); false
/// when the user dismissed with OK (the previous photo is kept).
/// [keepNotice], when provided, is shown as a reassurance line (e.g. "Your
/// current primary photo was kept.").
Future<bool> showPhotoRejectionDialog({
  required BuildContext context,
  required PhotoModerationRejection rejection,
  required LocalizationState l10n,
  Uint8List? photoBytes,
  bool offerRetry = false,
  String? keepNotice,
}) async {
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
      imageHeight = null;
    }
  }

  if (!context.mounted) return false;

  final fixedMessage = rejection.translationKey == null
      ? null
      : l10n.getString(rejection.translationKey!);
  final aiMessage = rejection.displayMessage;
  final showAiMessage =
      aiMessage.isNotEmpty &&
      (fixedMessage == null || fixedMessage != aiMessage);

  final chips = rejection.issueBoxes
      .map((b) => b.label)
      .where(_knownIssueLabels.contains)
      .toSet()
      .toList();

  var retryChosen = false;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.getString('photoRejectedTitle')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (imageWidth != null && imageHeight != null)
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: double.infinity,
                    height: 360,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.memory(photoBytes!, fit: BoxFit.contain),
                        Positioned.fill(
                          child: CustomPaint(
                            painter: IssueBoxesPainter(
                              boxes: rejection.issueBoxes,
                              imageWidth: imageWidth,
                              imageHeight: imageHeight,
                            ),
                          ),
                        ),
                        if (rejection.fullImageIssue)
                          Container(color: Colors.red.withValues(alpha: 0.25)),
                      ],
                    ),
                  ),
                ),
              ),
            if (chips.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: chips
                    .map(
                      (label) => Chip(
                        avatar: Icon(
                          Icons.flag_outlined,
                          size: 16,
                          color: _issueColor(label),
                        ),
                        label: Text(
                          l10n.getString(
                            'photoIssue${label[0].toUpperCase()}${label.substring(1)}',
                          ),
                          style: Theme.of(ctx).textTheme.bodySmall,
                        ),
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                      ),
                    )
                    .toList(),
              ),
            ],
            const SizedBox(height: 12),
            if (fixedMessage != null)
              Text(
                fixedMessage,
                style: Theme.of(
                  ctx,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            if (showAiMessage) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: Theme.of(ctx).colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      aiMessage,
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
            if (keepNotice != null) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.history,
                    size: 16,
                    color: Theme.of(ctx).colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      keepNotice,
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (offerRetry)
          TextButton(
            onPressed: () {
              retryChosen = true;
              Navigator.of(ctx).pop();
            },
            child: Text(l10n.getString('photoRejectedTryAgain')),
          ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(l10n.getString('generalOk')),
        ),
      ],
    ),
  );
  return retryChosen;
}

/// Draws the rejection boxes over the photo, mapping normalized 0..1
/// coordinates onto the BoxFit.contain rect of the rendered image. Shared by
/// the AI-moderation rejection dialog and the prescreen failure dialog.
class IssueBoxesPainter extends CustomPainter {
  final List<PhotoIssueBox> boxes;
  final int imageWidth;
  final int imageHeight;

  IssueBoxesPainter({
    required this.boxes,
    required this.imageWidth,
    required this.imageHeight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (imageWidth <= 0 || imageHeight <= 0) return;
    final scale = math.min(size.width / imageWidth, size.height / imageHeight);
    final displayedWidth = imageWidth * scale;
    final displayedHeight = imageHeight * scale;
    final offsetX = (size.width - displayedWidth) / 2;
    final offsetY = (size.height - displayedHeight) / 2;

    for (final box in boxes) {
      final rect = Rect.fromLTWH(
        offsetX + box.x * displayedWidth,
        offsetY + box.y * displayedHeight,
        box.w * displayedWidth,
        box.h * displayedHeight,
      );
      final color = _issueColor(box.label);
      final fill = Paint()..color = color.withValues(alpha: 0.18);
      final stroke = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeJoin = StrokeJoin.round;
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect.inflate(2), const Radius.circular(6)),
        fill,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect.inflate(2), const Radius.circular(6)),
        stroke,
      );
    }
  }

  @override
  bool shouldRepaint(covariant IssueBoxesPainter oldDelegate) =>
      oldDelegate.boxes != boxes ||
      oldDelegate.imageWidth != imageWidth ||
      oldDelegate.imageHeight != imageHeight;
}
