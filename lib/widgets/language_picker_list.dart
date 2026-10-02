import 'package:flutter/material.dart';

class LanguagePickerEntry {
  const LanguagePickerEntry({
    required this.code,
    required this.displayName,
    this.canUseNow = true,
  });

  final String code;
  final String displayName;

  /// False when the language's translations aren't available offline.
  final bool canUseNow;
}

/// The list body of the "select language" dialog.
///
/// Deliberately a [Column] of tiles and never a scrollable: the dialog that
/// hosts this is an `AlertDialog(scrollable: true)`, which measures its content
/// intrinsically. A nested viewport cannot return intrinsic dimensions, so a
/// `ListView` here made the dialog throw during layout and the language list
/// never rendered — the dialog supplies the scrolling instead.
class LanguagePickerList extends StatelessWidget {
  const LanguagePickerList({
    super.key,
    required this.entries,
    required this.onSelected,
    this.onUnavailable,
  });

  final List<LanguagePickerEntry> entries;
  final ValueChanged<LanguagePickerEntry> onSelected;
  final ValueChanged<LanguagePickerEntry>? onUnavailable;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final entry in entries)
          ListTile(
            leading: Icon(
              entry.canUseNow ? Icons.language : Icons.lock_outline,
              color: entry.canUseNow ? null : Colors.grey.shade400,
            ),
            title: Text(
              entry.displayName,
              style: TextStyle(
                color: entry.canUseNow ? null : Colors.grey.shade400,
              ),
            ),
            onTap: () => entry.canUseNow
                ? onSelected(entry)
                : onUnavailable?.call(entry),
          ),
      ],
    );
  }
}
