import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Recordings and decrypted clips live in the app's own cache directory (per user, sandboxed on
/// mobile and macOS), never in a shared /tmp.
Future<Directory> _dir() async {
  final d = Directory('${(await getApplicationCacheDirectory()).path}/voice');
  await d.create(recursive: true);
  return d;
}

String _safe(String id) => id.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_');

/// Where the recorder writes the next clip.
Future<String> newRecordingPath() async => '${(await _dir()).path}/rec_${DateTime.now().microsecondsSinceEpoch}.m4a';

/// Reads a finished recording and deletes the file (the bytes live on encrypted from here).
Future<Uint8List> takeRecording(String path) async {
  final f = File(path);
  final bytes = await f.readAsBytes();
  try {
    await f.delete();
  } on FileSystemException {
    // swept at the next start
  }
  return bytes;
}

/// A file the player can open holding [bytes] (decrypted clip of message [id]).
Future<Uri> playableUri(String id, Uint8List bytes) async {
  final f = File('${(await _dir()).path}/play_${_safe(id)}.m4a');
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

/// Deletes every recording and decrypted clip left behind (a crash, a kill, sign-out).
Future<void> sweepVoiceFiles() async {
  try {
    final d = Directory('${(await getApplicationCacheDirectory()).path}/voice');
    if (await d.exists()) await d.delete(recursive: true);
  } catch (_) {
    // best effort
  }
}

/// Deletes the decrypted clip of message [id] (a disappearing message that went), if one is left.
Future<void> dropVoiceFiles(String id) async {
  try {
    final f = File('${(await getApplicationCacheDirectory()).path}/voice/play_${_safe(id)}.m4a');
    if (await f.exists()) await f.delete();
  } catch (_) {
    // best effort; swept at the next start
  }
}
