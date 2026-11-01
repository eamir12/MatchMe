// TEMP-FORENSICS: walks the raw hive box file with hive's own reader and
// returns compact one-line summaries of the frames behind an "unknown
// typeId" open failure. Removal planned after root cause is identified.
// Note: returns strings instead of printing — standalone probe prints kept
// vanishing before reaching logcat; the caller embeds this into the
// '[HiveCrypto] Encrypted open failed' line, which has survived every run.
// ignore_for_file: implementation_imports

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hive/hive.dart';
import 'package:hive/src/binary/binary_reader_impl.dart';
import 'package:hive/src/registry/type_registry_impl.dart';

String _hex(Uint8List bytes, int offset, int length) {
  final end = math.min(bytes.length, offset + length);
  final sb = StringBuffer();
  for (var i = offset; i < end; i++) {
    sb.write(bytes[i].toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Future<List<String>> hiveForensicDump(
  String boxName,
  String filePath,
  HiveCipher cipher,
  void Function(String line) _, // ignored: kept for the shared signature
) async {
  final out = <String>[];
  try {
    final file = File(filePath);
    if (!await file.exists()) {
      return ['missing:$filePath'];
    }
    final bytes = await file.readAsBytes();
    out.add('size=${bytes.length}');
    out.add('head=${_hex(bytes, 0, 64)}');
    if (bytes.length > 64) {
      out.add('tail=${_hex(bytes, math.max(0, bytes.length - 32), 32)}');
    }

    final reader = BinaryReaderImpl(bytes, TypeRegistryImpl());
    var frames = 0;
    final offsets = <String>[];
    while (reader.availableBytes != 0) {
      final offset = reader.usedBytes;
      if (reader.availableBytes < 4) {
        out.add('stray=${reader.availableBytes}@$offset');
        break;
      }
      try {
        final frame = reader.readFrame(
          cipher: cipher,
          lazy: false,
          frameOffset: offset,
        );
        if (frame == null) {
          out.add('crcfail@$offset remain=${reader.availableBytes} '
              'b=${_hex(bytes, offset, math.min(24, bytes.length - offset))}');
          return out;
        }
        frames++;
        if (offsets.length < 8) {
          offsets.add('@$offset:${frame.length}');
        }
      } catch (e) {
        final code = e.toString();
        out.add('throw@$offset before=$frames '
            'code=${code.substring(0, math.min(70, code.length))}');
        out.add('region=${_hex(bytes, offset, math.min(64, bytes.length - offset))}');
        return out;
      }
    }
    out.add('ok frames=$frames off=${offsets.join(',')}');
  } catch (e) {
    out.add('probeerr=$e');
  }
  return out;
}
