import 'dart:typed_data';

import 'open_attachment_web.dart'
    if (dart.library.io) 'open_attachment_io.dart';

Future<bool> openUrlExternal(String url) => openUrlExternalImpl(url);

Future<bool> openBytesInDefaultApp(
  Uint8List bytes, {
  required String suggestedFileName,
  String? contentType,
}) => openBytesInDefaultAppImpl(
  bytes,
  suggestedFileName: suggestedFileName,
  contentType: contentType,
);

Future<bool> openPdfBytesInDefaultApp(
  Uint8List bytes, {
  required String suggestedFileName,
}) => openBytesInDefaultAppImpl(
  bytes,
  suggestedFileName: suggestedFileName,
  contentType: 'application/pdf',
);
