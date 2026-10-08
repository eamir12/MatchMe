/// A single highlighted region on a rejected profile photo, in image-normalized
/// coordinates (0..1, x/y = top-left corner) so it can be drawn over any
/// rendered size of the image.
class PhotoIssueBox {
  final double x;
  final double y;
  final double w;
  final double h;

  /// Stable identifier for the issue kind ('text', 'watermark', 'screenshot',
  /// 'meme', 'face'). Rendered through translation keys `photoIssue<Label>`.
  final String label;

  const PhotoIssueBox({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.label,
  });

  static double _clamp01(Object? v) {
    final n = v is num
        ? v.toDouble()
        : double.tryParse('$v') ?? 0;
    return n.isFinite ? n.clamp(0.0, 1.0).toDouble() : 0.0;
  }

  /// Parses one box from a moderation response entry ({x,y,w,h[,label]}).
  /// Returns null when the entry has no usable extent.
  static PhotoIssueBox? fromJson(Object? value, {String fallbackLabel = 'text'}) {
    if (value is! Map) return null;
    final w = _clamp01(value['w']);
    final h = _clamp01(value['h']);
    if (w <= 0 || h <= 0) return null;
    final label = value['label'] is String
        ? (value['label'] as String).trim().toLowerCase()
        : fallbackLabel;
    return PhotoIssueBox(
      x: _clamp01(value['x']),
      y: _clamp01(value['y']),
      w: w,
      h: h,
      label: label.isEmpty ? fallbackLabel : label,
    );
  }
}

/// Structured result of a rejected profile-photo moderation, thrown by the
/// profile provider so the wizard can show the user exactly what was wrong
/// with the photo: the AI's explanation plus highlighted regions.
///
/// [toString] keeps the legacy `Exception: GEMINI_MSG:` marker so existing
/// string-based error handling (snackbars, `_photoUploadFailureMessage`,
/// error-page routing) continues to work unchanged at call sites that do not
/// need the visual overlay.
class PhotoModerationRejection implements Exception {
  /// Gemini's short, human-friendly explanation, already translated into the
  /// UI language when possible.
  final String displayMessage;

  /// Fixed, moderated wording for the rejection, resolved through this key.
  /// Null when the server did not provide one.
  final String? translationKey;

  /// Machine-readable cause, e.g. BAD_CONTENT, TEXT_SCREENSHOT_OR_WATERMARK.
  final String? reasonCode;

  /// Regions of the photo related to the rejection. Empty when the problem
  /// cannot be localized to a region.
  final List<PhotoIssueBox> issueBoxes;

  /// Storage path of the photo this rejection refers to. Differs from the
  /// path the caller uploaded when the auto-sanitize pipeline replaced the
  /// original with a cleaned copy — callers must render THESE bytes, as the
  /// original may already be deleted. Null when unknown.
  final String? photoPath;

  /// True for photo-wide problems (restricted/suggestive content) where no
  /// single region is at fault; the dialog tints the whole image instead of
  /// drawing boxes.
  final bool fullImageIssue;

  const PhotoModerationRejection({
    required this.displayMessage,
    this.translationKey,
    this.reasonCode,
    this.issueBoxes = const [],
    this.photoPath,
    this.fullImageIssue = false,
  });

  @override
  String toString() => 'Exception: GEMINI_MSG:$displayMessage';
}
