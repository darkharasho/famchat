import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

Future<String> _tmp() async => (await getTemporaryDirectory()).path;

String _safe(String id) => id.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_');

/// Where the recorder writes the next clip.
Future<String> newRecordingPath() async => '${await _tmp()}/famchat_rec_${DateTime.now().microsecondsSinceEpoch}.m4a';

/// Reads a finished recording and deletes the file (the bytes live on encrypted from here).
Future<Uint8List> takeRecording(String path) async {
  final f = File(path);
  final bytes = await f.readAsBytes();
  try {
    await f.delete();
  } on FileSystemException {
    // the OS cleans the temp dir eventually
  }
  return bytes;
}

/// A file the player can open holding [bytes] (decrypted clip of message [id]).
Future<Uri> playableUri(String id, Uint8List bytes) async {
  final f = File('${await _tmp()}/famchat_play_${_safe(id)}.m4a');
  await f.writeAsBytes(bytes, flush: true);
  return Uri.file(f.path);
}

/// Deletes what [playableUri] wrote.
Future<void> releasePlayable(Uri uri) async {
  if (uri.scheme != 'file') return;
  try {
    await File.fromUri(uri).delete();
  } on FileSystemException {
    // already gone
  }
}
