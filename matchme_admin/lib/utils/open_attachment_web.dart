import 'dart:typed_data';

import 'package:url_launcher/url_launcher.dart';

Future<bool> openUrlExternalImpl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  return launchUrl(uri, mode: LaunchMode.platformDefault);
}

Future<bool> openBytesInDefaultAppImpl(
  Uint8List bytes, {
  required String suggestedFileName,
  String? contentType,
}) async {
  return false;
}
