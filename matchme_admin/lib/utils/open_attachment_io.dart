import 'dart:io';
import 'dart:typed_data';

import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

Future<bool> openUrlExternalImpl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

Future<bool> openBytesInDefaultAppImpl(
  Uint8List bytes, {
  required String suggestedFileName,
  String? contentType,
}) async {
  final dir = await getTemporaryDirectory();
  final fileName = _sanitizeFileName(
    suggestedFileName,
    defaultName: _defaultFileName(contentType),
    contentType: contentType,
  );
  final path = '${dir.path}${Platform.pathSeparator}$fileName';
  final file = File(path);
  await file.writeAsBytes(bytes, flush: true);
  final result = await OpenFilex.open(path, type: contentType);
  return result.type == ResultType.done;
}

String _defaultFileName(String? contentType) {
  return switch (contentType) {
    'application/pdf' => 'attachment.pdf',
    'image/jpeg' => 'attachment.jpg',
    'image/png' => 'attachment.png',
    'image/webp' => 'attachment.webp',
    _ => 'attachment',
  };
}

String _sanitizeFileName(
  String input, {
  required String defaultName,
  String? contentType,
}) {
  final trimmed = input.trim();
  var name = trimmed.isEmpty ? defaultName : trimmed;
  name = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  if (!_hasFileExtension(name)) {
    final ext = _extensionForContentType(contentType);
    if (ext != null) {
      name = '$name.$ext';
    }
  }
  return name;
}

bool _hasFileExtension(String name) {
  final i = name.lastIndexOf('.');
  return i > 0 && i < name.length - 1;
}

String? _extensionForContentType(String? contentType) {
  return switch (contentType) {
    'application/pdf' => 'pdf',
    'image/jpeg' => 'jpg',
    'image/png' => 'png',
    'image/webp' => 'webp',
    'image/gif' => 'gif',
    _ => null,
  };
}
