// lib/utils/scroll_anchor.dart
import 'package:flutter/widgets.dart';

/// Keeps a scrollable list anchored to the content the user is looking at.
///
/// Adding or removing a block of content above the viewport moves every row
/// below it, even though the scroll offset itself does not change — the list
/// appears to jump away from whatever the user was reading.
///
/// This helper remembers the height of that block and moves the scroll offset
/// by the same amount. The movement and the offset change cancel each other
/// out, so the visible rows stay exactly where the user left them.
///
/// The block **must** be laid out unconditionally, e.g. as a sliver ahead of
/// the lazy list (a `SliverToBoxAdapter`). A child *inside* a lazy list keeps
/// the offset it was last laid out at; when it is toggled while it is outside
/// the materialised range, the list shifts the content below it by the change
/// in child count times the average child extent, not by the height of what
/// actually changed. No scroll-offset correction can cancel that error.
class ScrollAnchor {
  /// Height of the block that appears and disappears above the viewport.
  ///
  /// `null` until the block has been laid out at least once. The height is
  /// remembered rather than measured on demand because the block is usually
  /// off screen by the time it is toggled.
  double? _blockHeight;

  /// Records the height of the block that toggles above the viewport.
  ///
  /// Zero heights are ignored: they mean the block is not on screen (or not
  /// rendered at all) and would wipe out the remembered height.
  void setBlockHeight(double height) {
    if (height > 0) _blockHeight = height;
  }

  /// Moves [controller] so the list keeps showing the same content when the
  /// block above the viewport changes from [wasPresent] to [willBePresent].
  ///
  /// The offset is moved straight away, so this has to be called before the
  /// list is rebuilt: the rows the user is looking at then never move at all.
  void anchor({
    required ScrollController? controller,
    required bool wasPresent,
    required bool willBePresent,
  }) {
    if (wasPresent == willBePresent) return;
    final height = _blockHeight;
    if (height == null || height <= 0) return;
    if (controller == null || !controller.hasClients) return;
    final position = controller.position;
    final delta = (willBePresent ? height : 0.0) - (wasPresent ? height : 0.0);
    final target = position.pixels + delta;
    if (target >= position.minScrollExtent &&
        target <= position.maxScrollExtent) {
      if ((target - position.pixels).abs() < 0.5) return;
      controller.jumpTo(target);
      return;
    }
    // The list is at its very end, so the bounds after the change are not
    // known yet. Apply the move once the next layout has been done.
    _shiftAfterLayout(controller, delta);
  }

  /// Same as [anchor], but the move is applied after the next layout.
  ///
  /// Used to undo a shift whose prediction did not hold, which can only be
  /// spotted once the list has been rebuilt. Safe to call while the list is
  /// being built.
  void reconcile({
    required ScrollController? controller,
    required bool wasPresent,
    required bool willBePresent,
  }) {
    if (wasPresent == willBePresent) return;
    final height = _blockHeight;
    if (height == null || height <= 0) return;
    if (controller == null || !controller.hasClients) return;
    _shiftAfterLayout(
      controller,
      (willBePresent ? height : 0.0) - (wasPresent ? height : 0.0),
    );
  }

  void _shiftAfterLayout(ScrollController controller, double delta) {
    if (delta == 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!controller.hasClients) return;
      final position = controller.position;
      final target = (position.pixels + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((target - position.pixels).abs() < 0.5) return;
      controller.jumpTo(target);
    });
  }
}
