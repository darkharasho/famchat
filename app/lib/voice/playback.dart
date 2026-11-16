// App-wide voice playback: one player, one clip at a time. Bubbles watch [PlaybackState] for their
// message id and call toggle/seek with a loader for their decrypted bytes. Signing out (a new
// [voiceScopeProvider] value) disposes the player and its decrypted temp file.
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

  /// Why the clip couldn't load or play (tap retries).
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

  /// What to do once the clip that's loading is ready (taps and drags while it loads).
  bool _wantPlay = false;
  double? _wantSeek;

  @override
  PlaybackState build() {
    ref.watch(voiceScopeProvider);
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

  void _set(PlaybackState s) {
    if (ref.mounted) state = s;
  }

  VoicePlayer get _p {
    final existing = _player;
    if (existing != null) return existing;
    final p = _player = ref.read(voicePlayerFactoryProvider)();
    _subs
      ..add(p.position.listen((d) {
        if (state.messageId != null && !state.loading) _set(state.copyWith(position: d));
      }))
      ..add(p.playing.listen((v) {
        if (state.messageId != null && !state.loading && state.playing != v) _set(state.copyWith(playing: v));
      }))
      ..add(p.completed.listen((_) => unawaited(_rewind())))
      ..add(p.errors.listen((e) {
        final id = state.messageId;
        if (id != null && !state.loading) _fail(id, e);
      }));
    return p;
  }

  Future<void> _rewind() async {
    final gen = _gen;
    _set(state.copyWith(playing: false, position: Duration.zero));
    try {
      await _p.pause();
      if (gen == _gen) await _p.seek(Duration.zero);
    } catch (_) {}
    if (gen == _gen) _set(state.copyWith(playing: false, position: Duration.zero));
  }

  bool _ready(String messageId) =>
      state.messageId == messageId && !state.loading && state.error == null && state.duration != null;

  bool _loading(String messageId) => state.messageId == messageId && state.loading;

  /// Plays or pauses message [messageId]'s clip, loading it first (stopping any other clip).
  /// [duration] is the message's length, used when the decoder doesn't report one.
  Future<void> toggle(String messageId, VoiceBytes bytes, {Duration? duration}) async {
    if (_loading(messageId)) {
      _wantPlay = !_wantPlay;
      return;
    }
    if (_ready(messageId)) {
      if (state.playing) {
        _set(state.copyWith(playing: false));
        try {
          await _p.pause();
        } catch (e) {
          _fail(messageId, e);
        }
      } else {
        await _play(messageId);
      }
      return;
    }
    await _open(messageId, bytes, duration, play: true);
  }

  /// Moves message [messageId]'s clip to [fraction] (0..1); another clip is loaded paused first.
  Future<void> seek(String messageId, double fraction, VoiceBytes bytes, {Duration? duration}) async {
    if (_loading(messageId)) {
      _wantSeek = fraction;
      return;
    }
    if (_ready(messageId)) return _seekTo(fraction);
    await _open(messageId, bytes, duration, play: false, seek: fraction);
  }

  /// Pauses whatever plays and forgets it.
  Future<void> stop() async {
    if (!ref.mounted) return;
    _gen++;
    final wasPlaying = state.playing;
    _set(const PlaybackState());
    if (wasPlaying) {
      try {
        await _player?.pause();
      } catch (_) {}
    }
  }

  Future<void> _seekTo(double fraction) async {
    final to = state.duration! * fraction.clamp(0.0, 1.0);
    _set(state.copyWith(position: to));
    try {
      await _p.seek(to);
    } catch (_) {
      // the position stream corrects the bar
    }
  }

  Future<void> _play(String messageId) async {
    _set(state.copyWith(playing: true));
    try {
      await _p.play();
    } catch (e) {
      _fail(messageId, e);
    }
  }

  void _fail(String messageId, Object e) => _set(PlaybackState(messageId: messageId, error: e));

  Future<void> _open(String messageId, VoiceBytes bytes, Duration? fallback, {required bool play, double? seek}) async {
    final gen = ++_gen;
    _wantPlay = play;
    _wantSeek = seek;
    if (state.playing) {
      try {
        await _player?.pause();
      } catch (_) {}
    }
    _set(PlaybackState(messageId: messageId, loading: true));
    try {
      final b = await bytes();
      if (gen != _gen || !ref.mounted) return;
      if (b == null) {
        _set(const PlaybackState()); // expired: the bubble shows that itself
        return;
      }
      final d = await _p.load(messageId, b);
      if (gen != _gen || !ref.mounted) return;
      final duration = d != null && d > Duration.zero ? d : fallback;
      _set(PlaybackState(messageId: messageId, duration: duration ?? Duration.zero));
    } catch (e) {
      if (gen == _gen) _fail(messageId, e);
      return;
    }
    final at = _wantSeek;
    if (at != null) await _seekTo(at);
    if (_wantPlay && gen == _gen) await _play(messageId);
  }
}
