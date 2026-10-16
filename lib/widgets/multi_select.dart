// lib/widgets/multi_select.dart
//
// Shared multi-select machinery for list screens (notification inbox, chats,
// and future lists). Screens own a [SelectionController], feed it item ids via
// long-press/tap, and render the shared bars:
//   - [SelectionHeaderBar]: close button + "N selected" + select-all toggle,
//     placed wherever the screen's normal top chrome sits.
//   - [SelectionBottomBar]: the contextual bulk actions (archive, mark read,
//     delete, ...), thumb-reachable at the bottom of the screen.
//   - [SelectionCheckCircle]: the animated leading check for selected rows.
//
// Selection mode is active while the controller holds at least one id; the
// conventional entry point is a long-press on a row, and clearing the
// selection exits the mode.

import 'package:flutter/material.dart';
import 'package:matchme/widgets/safe_text.dart';

/// Holds the set of selected ids for one screen.
///
/// Plain [ChangeNotifier] rather than a Riverpod provider on purpose: the
/// selection is ephemeral, screen-local UI state that dies with the screen.
/// Screens rebuild on it via `controller.addListener(() => setState(() {}))`.
class SelectionController extends ChangeNotifier {
  final Set<String> _ids = <String>{};

  /// The currently selected ids. Treat as read-only.
  Set<String> get selected => Set.unmodifiable(_ids);

  int get count => _ids.length;

  /// True while the screen is in selection mode (at least one row selected).
  bool get isActive => _ids.isNotEmpty;

  bool isSelected(String id) => _ids.contains(id);

  /// Selects [id] if unselected, deselects it if selected. Entering selection
  /// mode from a long-press is just a toggle on an empty set.
  void toggle(String id) {
    if (!_ids.remove(id)) {
      _ids.add(id);
    }
    notifyListeners();
  }

  void selectAll(Iterable<String> ids) {
    _ids.addAll(ids);
    notifyListeners();
  }

  void clear() {
    if (_ids.isEmpty) return;
    _ids.clear();
    notifyListeners();
  }
}

/// Top bar shown while a screen is in selection mode: a close button, the
/// "N selected" counter and a select-all/deselect-all toggle. Drop it in
/// wherever the screen's normal top chrome sits (AppBar replacement, top of
/// the content column, ...).
class SelectionHeaderBar extends StatelessWidget {
  final SelectionController controller;

  /// All selectable ids currently visible, used by the select-all toggle.
  final List<String> allIds;

  /// Localized "N selected" text.
  final String selectedLabel;

  final String closeTooltip;
  final String selectAllTooltip;
  final String deselectAllTooltip;

  const SelectionHeaderBar({
    super.key,
    required this.controller,
    required this.allIds,
    required this.selectedLabel,
    required this.closeTooltip,
    required this.selectAllTooltip,
    required this.deselectAllTooltip,
  });

  @override
  Widget build(BuildContext context) {
    final allSelected =
        allIds.isNotEmpty && controller.selected.length >= allIds.length;

    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.close),
          tooltip: closeTooltip,
          onPressed: controller.clear,
        ),
        Expanded(
          child: Text(
            selectedLabel,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        IconButton(
          icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
          tooltip: allSelected ? deselectAllTooltip : selectAllTooltip,
          onPressed: allIds.isEmpty
              ? null
              : () {
                  if (allSelected) {
                    controller.clear();
                  } else {
                    controller.selectAll(allIds);
                  }
                },
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}

/// One entry in a [SelectionBottomBar].
class SelectionAction {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  /// Destructive actions render in the error color and (per app convention)
  /// should be confirmed by the screen before [onPressed] runs.
  final bool destructive;

  const SelectionAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.destructive = false,
  });
}

/// Bottom-anchored action bar for selection mode. Thumb-reachable and safe for
/// long lists; screens show it in place of whatever normally occupies the
/// bottom (e.g. the inline ad slot).
class SelectionBottomBar extends StatelessWidget {
  final List<SelectionAction> actions;

  const SelectionBottomBar({super.key, required this.actions});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(
          top: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          child: Row(
            children: [
              for (final action in actions)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: action.destructive
                            ? colors.error
                            : colors.primary,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      onPressed: action.onPressed,
                      icon: Icon(action.icon, size: 20),
                      label: ShrinkText(
                        action.label,
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
}

/// Animated leading check for a selectable row: an outlined circle when
/// unselected, a filled primary circle with a check mark when selected.
/// Swap a row's avatar for this while selection mode is active.
class SelectionCheckCircle extends StatelessWidget {
  final bool selected;
  final double size;

  const SelectionCheckCircle({super.key, required this.selected, this.size = 24});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? colors.primary : Colors.transparent,
          border: Border.all(
            color: selected ? colors.primary : colors.onSurfaceVariant,
            width: 2,
          ),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          child: selected
              ? Icon(
                  Icons.check,
                  key: const ValueKey('checked'),
                  size: size * 0.7,
                  color: colors.onPrimary,
                )
              : const SizedBox.shrink(key: ValueKey('unchecked')),
        ),
      ),
    );
  }
}
