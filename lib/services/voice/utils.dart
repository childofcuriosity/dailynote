import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Copy file from assets to app support directory, return destination path
Future<String> copyAssetFile(String src, [String? dst]) async {
  final directory = await getApplicationSupportDirectory();
  final target = p.join(directory.path, dst ?? p.basename(src));

  final data = await rootBundle.load(src);
  final exists = await File(target).exists();

  if (!exists || File(target).lengthSync() != data.lengthInBytes) {
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    await File(target).writeAsBytes(bytes);
  }

  return target;
}

/// PCM 16-bit bytes → normalized Float32 array [-1.0, 1.0]
Float32List convertBytesToFloat32(Uint8List bytes, [Endian endian = Endian.little]) {
  final values = Float32List(bytes.length ~/ 2);
  final data = ByteData.view(bytes.buffer);

  for (var i = 0; i < bytes.length; i += 2) {
    final sample = data.getInt16(i, endian);
    values[i ~/ 2] = sample / 32768.0;
  }

  return values;
}
