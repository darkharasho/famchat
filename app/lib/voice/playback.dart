// App-wide voice playback: one player, one clip at a time. Bubbles watch [PlaybackState] for their
// message id and call toggle/seek with a loader for their decrypted bytes.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio_init.dart';
import 'providers.dart';
import 'voice_player.dart';

class PlaybackState {
  const PlaybackState({
    this.messageId,
    this.loading = false,
    this.playing = false,
    this.position = Duration.zero,
    this.duration,
    this.error,
  });

  /// The clip loaded (or loading); null when nothing is.
  final String? messageId;
  final bool loading, playing;
  final Duration position;
  final Duration? duration;

  /// Why the clip couldn't load (tap retries).
  final Object? error;

  /// 0..1 through the clip.
  double get progress {
    final d = duration;
    if (d == null || d <= Duration.zero) return 0;
    return (position.inMicroseconds / d.inMicroseconds).clamp(0.0, 1.0);
  }

  PlaybackState copyWith({bool? playing, Duration? position}) => PlaybackState(
        messageId: messageId,
        loading: loading,
        playing: playing ?? this.playing,
        position: position ?? this.position,
        duration: duration,
        error: error,
      );
}

typedef VoiceBytes = Future<Uint8List?> Function();

class VoicePlayback extends Notifier<PlaybackState> {
  VoicePlayer? _player;
  final _subs = <StreamSubscription<Object?>>[];
  int _gen = 0;

  @override
  PlaybackState build() {
    ref.onDispose(() {
      _gen++;
      for (final s in _subs) {
        unawaited(s.cancel());
      }
      _subs.clear();
      final p = _player;
      _player = null;
      if (p != null) unawaited(disposeWithin(p.dispose));
    });
    return const PlaybackState();
  }

  VoicePlayer get _p {
    final existing = _player;
    if (existing != null) return existing;
    final p = _player = ref.read(voicePlayerFactoryProvider)();
    _subs
      ..add(p.position.listen((d) {
        if (state.messageId != null && !state.loading) state = state.copyWith(position: d);
      }))
      ..add(p.playing.listen((v) {
        if (state.messageId != null && !state.loading && state.playing != v) state = state.copyWith(playing: v);
      }))
      ..add(p.completed.listen((_) => unawaited(_rewind())));
    return p;
  }

  Future<void> _rewind() async {
    final gen = _gen;
    state = state.copyWith(playing: false, position: Duration.zero);
    try {
      await _p.pause();
      if (gen == _gen) await _p.seek(Duration.zero);
    } catch (_) {}
    if (gen == _gen && ref.mounted) state = state.copyWith(playing: false, position: Duration.zero);
  }

  bool _ready(String messageId) =>
      state.messageId == messageId && !state.loading && state.error == null && state.duration != null;

  /// Plays or pauses message [messageId]'s clip, loading it first (stopping any other clip).
  /// [duration] is the message's length, used when the decoder doesn't report one.
  Future<void> toggle(String messageId, VoiceBytes bytes, {Duration? duration}) async {
    if (_ready(messageId)) {
      try {
        if (state.playing) {
          state = state.copyWith(playing: false);
          await _p.pause();
        } else {
          state = state.copyWith(playing: true);
          await _p.play();
        }
      } catch (e) {
        _fail(messageId, e);
      }
      return;
    }
    if (await _open(messageId, bytes, duration)) {
      try {
        state = state.copyWith(playing: true);
        await _p.play();
      } catch (e) {
        _fail(messageId, e);
      }
    }
  }

  /// Moves message [messageId]'s clip to [fraction] (0..1); another clip is loaded paused first.
  Future<void> seek(String messageId, double fraction, VoiceBytes bytes, {Duration? duration}) async {
    if (!_ready(messageId) && !await _open(messageId, bytes, duration)) return;
    final to = state.duration! * fraction.clamp(0.0, 1.0);
    state = state.copyWith(position: to);
    try {
      await _p.seek(to);
    } catch (_) {
      // the position stream corrects the bar
    }
  }

  /// Pauses whatever plays.
  Future<void> stop() async {
    _gen++;
    if (state.playing) {
      try {
        await _player?.pause();
      } catch (_) {}
    }
    state = const PlaybackState();
  }

  void _fail(String messageId, Object e) {
    if (ref.mounted) state = PlaybackState(messageId: messageId, error: e);
  }

  Future<bool> _open(String messageId, VoiceBytes bytes, Duration? fallback) async {
    final gen = ++_gen;
    if (state.playing) {
      try {
        await _player?.pause();
      } catch (_) {}
    }
    state = PlaybackState(messageId: messageId, loading: true);
    try {
      final b = await bytes();
      if (gen != _gen || !ref.mounted) return false;
      if (b == null) {
        state = const PlaybackState(); // expired: the bubble shows that itself
        return false;
      }
      final d = await _p.load(messageId, b);
      if (gen != _gen || !ref.mounted) return false;
      final duration = d != null && d > Duration.zero ? d : fallback;
      state = PlaybackState(messageId: messageId, duration: duration ?? Duration.zero);
      return true;
    } catch (e) {
      if (gen == _gen) _fail(messageId, e);
      return false;
    }
  }
}
