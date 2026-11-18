import 'dart:async';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:famchat/media/media_db.dart';
import 'package:cross_file/cross_file.dart';
import 'package:famchat/media/photo.dart';
import 'package:famchat/media/video.dart';

/// "Processes" a photo without decoding: the full image is the input, the thumbnail its first
/// 16 bytes, 4×3 pixels. Bytes starting with 0xFF 0x00 are "undecodable".
class FakeProcessor implements PhotoProcessor {
  int calls = 0;

  /// While set, processing waits for it (after counting the call).
  Completer<void>? hold;

  @override
  Future<ProcessedPhoto> process(Uint8List original) async {
    calls++;
    await hold?.future;
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

/// "Processes" a video without decoding: its bytes as they are, a 16-byte poster, 1280×720, 12 s.
/// Files named `*.bad` are unreadable and `*.huge` too large.
class FakeVideoProcessor implements VideoProcessor {
  final processed = <String>[];

  @override
  Future<ProcessedVideo> process(XFile file) async {
    final name = file.name.isNotEmpty ? file.name : file.path;
    processed.add(name);
    if (name.endsWith('.bad')) throw const UnsupportedVideoException();
    if (name.endsWith('.huge')) throw VideoTooLargeException(maxVideoBytes + 1);
    final bytes = await file.readAsBytes();
    return ProcessedVideo(
      bytes: bytes,
      thumb: Uint8List.fromList(bytes.take(16).toList()),
      width: 1280,
      height: 720,
      duration: const Duration(seconds: 12),
    );
  }
}
