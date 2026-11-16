import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../audio_init.dart';

const kFixtureAsset = 'assets/spike/sample.m4a';
const _timeout = Duration(seconds: 10);

/// Upper bound for a whole play (load, playback, dispose): a spike may fail, it must never hang.
const playBudget = Duration(seconds: 30);

class PlayResult {
  const PlayResult({required this.duration, required this.reachedEnd});
  final Duration? duration;
  final bool reachedEnd;

  @override
  String toString() => 'duration=${duration?.inMilliseconds}ms reachedEnd=$reachedEnd';
}

class RecordProbe {
  const RecordProbe({required this.aacLc, required this.opus, required this.hasPermission});
  final bool aacLc;
  final bool opus;
  final bool hasPermission;

  @override
  String toString() => 'aacLc=$aacLc opus=$opus permission=$hasPermission';
}

Future<PlayResult> _play(Future<Duration?> Function(AudioPlayer) load, {double volume = 0}) =>
    _playOnce(load, volume: volume).timeout(playBudget);

Future<PlayResult> _playOnce(Future<Duration?> Function(AudioPlayer) load, {double volume = 0}) async {
  final player = AudioPlayer();
  try {
    final duration = await load(player).timeout(_timeout);
    await player.setVolume(volume);
    final done = player.processingStateStream.firstWhere((s) => s == ProcessingState.completed);
    unawaited(player.play());
    var reachedEnd = true;
    await done.timeout(_timeout, onTimeout: () {
      reachedEnd = false;
      return ProcessingState.idle;
    });
    return PlayResult(duration: duration, reachedEnd: reachedEnd);
  } finally {
    await disposeWithin(player.dispose);
  }
}

/// Loads the bundled AAC-LC fixture and plays it to the end at volume 0.
Future<PlayResult> playFixture() => _play((p) => p.setAsset(kFixtureAsset));

/// Which voice encoders this platform's recorder supports. Never prompts for permission.
Future<RecordProbe> probeRecorder() async {
  final rec = AudioRecorder();
  try {
    return RecordProbe(
      aacLc: await rec.isEncoderSupported(AudioEncoder.aacLc).timeout(_timeout),
      opus: await rec.isEncoderSupported(AudioEncoder.opus).timeout(_timeout),
      hasPermission: await rec.hasPermission(request: false).timeout(_timeout),
    );
  } finally {
    await disposeWithin(rec.dispose);
  }
}

/// Records [length] of AAC-LC (48 kbps mono 44.1 kHz) and plays it back; returns the decoded duration.
/// Needs a microphone; used from the spikes screen only.
Future<Duration?> recordAndPlay(Duration length) async {
  final rec = AudioRecorder();
  try {
    if (!await rec.hasPermission()) throw StateError('microphone permission denied');
    final path = kIsWeb
        ? ''
        : '${(await getTemporaryDirectory()).path}/famchat_spike_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await rec.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 48000, numChannels: 1, sampleRate: 44100),
      path: path,
    );
    await Future<void>.delayed(length);
    final out = await rec.stop();
    if (out == null) throw StateError('recorder returned no output');
    final result = await _play((p) => kIsWeb ? p.setUrl(out) : p.setFilePath(out), volume: 1);
    return result.duration;
  } finally {
    await disposeWithin(rec.dispose);
  }
}
