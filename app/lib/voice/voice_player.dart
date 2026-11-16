// Playing a voice clip: an interface the playback notifier uses, and its `just_audio` implementation
// (libmpv via just_audio_media_kit on Linux and Windows).
import 'dart:async';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

import '../audio_init.dart';
import 'voice_io.dart';

/// One audio output, reused for every clip.
abstract interface class VoicePlayer {
  /// Loads the decrypted clip of message [id]; returns its duration if the decoder knows it.
  Future<Duration?> load(String id, Uint8List bytes);

  /// Starts or resumes; returns once playback has started.
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);

  Stream<Duration> get position;
  Stream<bool> get playing;

  /// Fires when a clip plays to its end.
  Stream<void> get completed;

  /// Releases the player; time-boxed, never hangs.
  Future<void> dispose();
}

class JustVoicePlayer implements VoicePlayer {
  /// A load that takes longer fails (a broken decoder must not leave the bubble spinning).
  static const loadTimeout = Duration(seconds: 15);

  AudioPlayer? _p;
  Uri? _source;

  AudioPlayer get _player => _p ??= AudioPlayer();

  @override
  Future<Duration?> load(String id, Uint8List bytes) async {
    final old = _source;
    final uri = await playableUri(id, bytes);
    _source = uri;
    final d = await _player.setAudioSource(AudioSource.uri(uri)).timeout(loadTimeout);
    if (old != null && old != uri) unawaited(releasePlayable(old));
    return d;
  }

  @override
  Future<void> play() async => unawaited(_player.play()); // play()'s future ends when playback does

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Stream<Duration> get position => _player.positionStream;

  @override
  Stream<bool> get playing =>
      _player.playerStateStream.map((s) => s.playing && s.processingState != ProcessingState.completed).distinct();

  @override
  Stream<void> get completed =>
      _player.processingStateStream.where((s) => s == ProcessingState.completed).map((_) {});

  @override
  Future<void> dispose() async {
    final p = _p, src = _source;
    _p = null;
    _source = null;
    if (p != null) await disposeWithin(p.dispose);
    if (src != null) await releasePlayable(src);
  }
}
