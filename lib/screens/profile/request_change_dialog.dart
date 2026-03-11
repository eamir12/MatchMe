// lib/screens/profile/request_change_dialog.dart
// RTL fixes: ensure helper text + attach row are mirrored correctly in RTL locales.
// - Align helper text to right for RTL
// - Use Row(textDirection: ...) for the attach row so children order is flipped automatically

import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/services/profile_request_service.dart';

class RequestChangeDialog extends ConsumerStatefulWidget {
  final String userId;
  final String fieldKey; // 'name' | 'gender' | 'date_of_birth'
  final String fieldLabel;

  const RequestChangeDialog({
    super.key,
    required this.userId,
    required this.fieldKey,
    required this.fieldLabel,
  });

  @override
  ConsumerState<RequestChangeDialog> createState() => _RequestChangeDialogState();
}

class _RequestChangeDialogState extends ConsumerState<RequestChangeDialog> {
  String _reason = '';
  bool _submitting = false;
  final List<PlatformFile> _pickedFiles = [];

  // Submit is allowed as soon as the user enters any non-empty reason (attachments are optional)
  bool get _canSubmit => _reason.trim().isNotEmpty && !_submitting;

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const [
        'jpg',
        'jpeg',
        'png',
        'gif',
        'pdf',
        'doc',
        'docx',
        'xls',
        'xlsx',
        'ppt',
        'pptx',
      ],
      allowMultiple: true,
      withData: true,
    );
    if (result == null) return;
    final filesWithBytes = result.files.where((f) => f.bytes != null).toList();
    final filesWithoutBytes = result.files.where((f) => f.bytes == null).toList();

    if (filesWithoutBytes.isNotEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ref.read(localizationProvider).getString('profileEditFileBytesMissing'))));
      }
    }

    setState(() {
      _pickedFiles.clear();
      _pickedFiles.addAll(filesWithBytes);
    });
  }

  String _sanitizeFileName(String name) {
    var out = name.trim();
    out = out.replaceAll(RegExp(r'[\\/]+'), '_');
    out = out.replaceAll('..', '_');
    out = out.replaceAll(RegExp(r'[^a-zA-Z0-9._ -]'), '_');
    if (out.isEmpty) out = 'file';
    if (out.length > 120) out = out.substring(out.length - 120);
    return out;
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    final svc = ref.read(profileEditRequestServiceProvider);
    try {
      final List<Map<String, dynamic>> attachments = [];
      for (var f in _pickedFiles) {
        final bytes = f.bytes;
        if (bytes == null) continue;
        final safeName = _sanitizeFileName(f.name);
        final filename =
            '${widget.userId}/${DateTime.now().toUtc().millisecondsSinceEpoch}_$safeName';
        const bucket = 'profile-edit-attachments';
        final objectPath = await svc.uploadBytesToStorage(
          filename,
          bytes,
          public: false,
          bucket: bucket,
        );
        if (objectPath == null) {
          throw ProfileEditAttachmentException(
            'profileEditAttachmentUploadFailed',
            params: {'file': f.name},
          );
        }
        attachments.add({
          'name': f.name,
          'url': objectPath,
          'bucket': bucket,
          'size': f.size,
        });
      }

      final ok = await svc.submitRequestWithAttachments(widget.userId, [widget.fieldKey], _reason.trim(), attachments);
      if (ok) {
        if (mounted) Navigator.of(context).pop(true);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(ref.read(localizationProvider).getString('profileEditRequestAlreadyPendingBody'))),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        final l10n = ref.read(localizationProvider);
        if (e is ProfileEditAttachmentException) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.getString(e.key, params: e.params)),
            ),
          );
        } else {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(l10n.getString('generalError'))));
        }
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _extractLangCode(dynamic cur) {
    try {
      if (cur == null) return 'en';
      if (cur is Locale) return cur.languageCode;
      if (cur is String) return (cur.split(RegExp('[-_]')).first);
      return cur.toString().split(RegExp('[-_]')).first;
    } catch (_) {
      return 'en';
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final adminReviewsAsync = ref.watch(basicFieldAdminReviewsProvider(widget.userId));
    final cur = l10n.currentLocale;
    final langCode = _extractLangCode(cur);
    final isRtl = ['ar', 'he'].contains(langCode.toLowerCase());

    final title = l10n.getString('profileEditRequestUnlockTitle');
    final intro = l10n.getString('profileEditRequestUnlockDesc');
    // Use the correct translation key for the change label
    final changeLabel = l10n.getString('profileEditRequestChangingLabel');
    final helper = l10n.getString('profileEditRequestHelper');

    final review = adminReviewsAsync.value?[widget.fieldKey];
    final isPending = review?.status == 'pending';

    return Directionality(
      textDirection: isRtl ? ui.TextDirection.rtl : ui.TextDirection.ltr,
      child: AlertDialog(
        scrollable: true,
        title: Align(
          alignment: isRtl ? Alignment.centerRight : Alignment.centerLeft,
          child: Text(
            isPending ? l10n.getString('profileEditRequestAlreadyPendingTitle') : title,
            textAlign: isRtl ? TextAlign.right : TextAlign.left,
          ),
        ),
        content: Column(
          crossAxisAlignment: isRtl ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isPending ? l10n.getString('profileEditRequestAlreadyPendingBody') : intro,
              textAlign: isRtl ? TextAlign.right : TextAlign.left,
            ),
            const SizedBox(height: 12),

            if (!isPending) ...[
              Align(
                alignment: isRtl ? Alignment.centerRight : Alignment.centerLeft,
                child: Builder(builder: (ctx) {
                  final trimmed = changeLabel.trim();
                  final lastRune = trimmed.isNotEmpty ? trimmed.runes.last : 0;
                  final punctuationRunes = <int>{46, 58, 8230};
                  final endWithPunct = lastRune != 0 && punctuationRunes.contains(lastRune);

                  final displayLabel = endWithPunct
                      ? '$changeLabel ${widget.fieldLabel}'
                      : '$changeLabel: ${widget.fieldLabel}';

                  return Text(
                    displayLabel,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                    textAlign: isRtl ? TextAlign.right : TextAlign.left,
                  );
                }),
              ),
              const SizedBox(height: 8),

              TextField(
                textAlign: isRtl ? TextAlign.right : TextAlign.left,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontFeatures: const []),
                maxLines: 4,
                minLines: 2,
                onChanged: (v) => setState(() => _reason = v),
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: l10n.getString('profileEditRequestReasonHint'),
                  helperText: helper,
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 8),

              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _pickFiles,
                      icon: const Icon(Icons.attach_file),
                      label: Text(l10n.getString('profileEditAttachDocs')),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _pickedFiles.isEmpty
                        ? l10n.getString('profileEditNoFiles')
                        : '${_pickedFiles.length} ${l10n.getString('profileEditFilesSelected')}',
                    textAlign: isRtl ? TextAlign.right : TextAlign.left,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        actionsAlignment: isRtl ? MainAxisAlignment.start : MainAxisAlignment.end,
        actions: [
          TextButton(
            onPressed: _submitting ? null : () => Navigator.of(context).pop(false),
            child: Text(l10n.getString('generalCancel')),
          ),
          if (!isPending)
            ElevatedButton(
              onPressed: !_canSubmit ? null : _submit,
              child: _submitting
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).colorScheme.onPrimary,
                      ),
                    )
                  : Text(l10n.getString('profileEditRequestSubmit')),
            ),
        ],
      ),
    );
  }
}
