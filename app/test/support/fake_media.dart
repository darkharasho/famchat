import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:famchat/media/media_db.dart';
import 'package:famchat/media/photo.dart';

/// "Processes" a photo without decoding: the full image is the input, the thumbnail its first
/// 16 bytes, 4×3 pixels. Bytes starting with 0xFF 0x00 are "undecodable".
class FakeProcessor implements PhotoProcessor {
  int calls = 0;

  @override
  Future<ProcessedPhoto> process(Uint8List original) async {
    calls++;
    if (original.length >= 2 && original[0] == 0xff && original[1] == 0x00) throw const UnsupportedImageException();
    return ProcessedPhoto(
      full: original,
      thumb: Uint8List.fromList(original.take(16).toList()),
      width: 4,
      height: 3,
    );
  }
}

MediaDb memoryMediaDb() => MediaDb(NativeDatabase.memory());

Uint8List photoBytes(int n, [int seed = 7]) => Uint8List.fromList([for (var i = 0; i < n; i++) (i * 13 + seed) & 0xff]);
