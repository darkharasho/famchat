import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';

/// The web recorder makes a blob URL itself; no path.
Future<String> newRecordingPath() async => '';

/// Fetches the recorder's blob URL.
Future<Uint8List> takeRecording(String url) => XFile(url).readAsBytes();

/// A data: URL the audio element can play.
Future<Uri> playableUri(String id, Uint8List bytes) async => Uri.dataFromBytes(bytes, mimeType: 'audio/mp4');

Future<void> releasePlayable(Uri uri) async {}

/// Nothing is written to disk on the web.
Future<void> sweepVoiceFiles() async {}

/// Nothing is written to disk on the web.
Future<void> dropVoiceFiles(String id) async {}
