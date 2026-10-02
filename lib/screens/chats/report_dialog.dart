// lib/screens/chats/report_dialog.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'; // Import
import 'package:matchme/providers/locale_provider.dart'; // Import

// Change to ConsumerStatefulWidget
class ReportDialogContent extends ConsumerStatefulWidget {
  final String otherUserName;
  const ReportDialogContent({super.key, required this.otherUserName});

  @override
  ConsumerState<ReportDialogContent> createState() =>
      _ReportDialogContentState();
}

class _ReportDialogContentState extends ConsumerState<ReportDialogContent> {
  final TextEditingController _reportReasonController = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _reportReasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider); // Get l10n

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      scrollable: true,
      actionsAlignment: MainAxisAlignment.end,
      actionsOverflowAlignment: OverflowBarAlignment.end,
      actionsOverflowButtonSpacing: 8,
      actionsOverflowDirection: VerticalDirection.down,
      title: Text(
        l10n.getString(
          'reportTitleWithName',
          params: {'name': widget.otherUserName},
        ),
      ),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.getString('reportReason')), // Use l10n
            const SizedBox(height: 16),
            TextFormField(
              controller: _reportReasonController,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontFeatures: const []),
              decoration: InputDecoration(
                labelText: l10n.getString('reportReasonRequired'), // Use l10n
                border: const OutlineInputBorder(),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return l10n.getString('reportReasonRequired'); // Use l10n
                }
                return null;
              },
              maxLines: 3,
              autofocus: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.getString('generalCancel')), // Use l10n
        ),
        TextButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              Navigator.pop(context, _reportReasonController.text.trim());
            }
          },
          style: TextButton.styleFrom(foregroundColor: Colors.red),
          child: Text(l10n.getString('reportSubmit')), // Use l10n
        ),
      ],
    );
  }
}

// Update the helper function to use the new widget
Future<String?> showReportDialog(
  BuildContext context,
  String otherUserName,
) async {
  return await showDialog<String>(
    context: context,
    builder: (context) {
      // Return the ConsumerStatefulWidget
      return ReportDialogContent(otherUserName: otherUserName);
    },
  );
}
