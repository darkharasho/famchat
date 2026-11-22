// Decoding with libmpv (through media_kit): its "pcm" audio output writes the clip, resampled to
// 16 kHz mono float, to a file as fast as it decodes ("untimed").
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

int _seq = 0;

/// [m4aPath]'s audio as 16 kHz mono float samples. Throws on a file libmpv can't play.
Future<Float32List> decodeWithMpv(String m4aPath, {Duration timeout = const Duration(seconds: 60)}) async {
  final out = File(p.join(Directory.systemTemp.path, 'famchat-pcm-$pid-${_seq++}.f32'));
  final player = Player();
  var disposed = false;
  try {
    final native = player.platform as NativePlayer;
    const props = {
      'ao': 'pcm',
      'ao-pcm-waveheader': 'no',
      'audio-samplerate': '16000',
      'audio-channels': 'mono',
      'audio-format': 'float',
      'untimed': 'yes',
      'keep-open': 'no',
      'vid': 'no',
    };
    await native.setProperty('ao-pcm-file', out.path);
    for (final e in props.entries) {
      await native.setProperty(e.key, e.value);
    }
    final failed = Completer<Never>();
    final errors = player.stream.error.listen((e) {
      if (!failed.isCompleted) failed.completeError(Exception(e));
    });
    final done = player.stream.completed.firstWhere((c) => c);
    try {
      await player.open(Media(m4aPath));
      await Future.any([done, failed.future]).timeout(timeout);
    } finally {
      await errors.cancel();
    }
    // Disposing closes the output file, so it's complete to read.
    disposed = true;
    await player.dispose();
    final bytes = await out.readAsBytes();
    return Float32List.view(Uint8List.fromList(bytes).buffer, 0, bytes.length ~/ 4);
  } finally {
    if (!disposed) await player.dispose();
    if (await out.exists()) await out.delete();
  }
}
