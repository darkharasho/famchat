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

  /// Playback failures after a successful load (decoder errors, a lost output device).
  Stream<Object> get errors;

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
    _source = null;
    try {
      final uri = await playableUri(id, bytes);
      _source = uri;
      return await _player.setAudioSource(AudioSource.uri(uri)).timeout(loadTimeout);
    } finally {
      // The previous clip's file goes whether or not this one loaded.
      if (old != null && old != _source) unawaited(releasePlayable(old));
    }
  }

  final _errors = StreamController<Object>.broadcast();

  @override
  Future<void> play() async {
    // play()'s future ends when playback does; its errors arrive later.
    unawaited(_player.play().catchError((Object e) => _errors.add(e)));
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Stream<Duration> get position => _player.positionStream;

  @override
  Stream<bool> get playing =>
      _player.playerStateStream
          .map((s) =>
              s.playing && s.processingState != ProcessingState.completed && s.processingState != ProcessingState.idle)
          .distinct();

  @override
  Stream<void> get completed =>
      _player.processingStateStream.where((s) => s == ProcessingState.completed).map((_) {});

  @override
  Stream<Object> get errors {
    // Errors reported on the event stream (decoder failures mid-clip) join those from play().
    _eventErrors ??= _player.playbackEventStream.listen((_) {}, onError: (Object e) => _errors.add(e));
    return _errors.stream;
  }

  StreamSubscription<PlaybackEvent>? _eventErrors;

  @override
  Future<void> dispose() async {
    await _eventErrors?.cancel();
    _eventErrors = null;
    final p = _p, src = _source;
    _p = null;
    _source = null;
    if (p != null) await disposeWithin(p.dispose);
    if (src != null) await releasePlayable(src);
  }
}
