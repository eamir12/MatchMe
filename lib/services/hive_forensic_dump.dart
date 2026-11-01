// TEMP-FORENSICS: web/no-op stub for the hive file frame-walk probe.
import 'package:hive/hive.dart';

Future<List<String>> hiveForensicDump(
  String boxName,
  String filePath,
  HiveCipher cipher,
  void Function(String line) _,
) async => const [];
