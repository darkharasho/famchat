import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// A video_player backend for tests: every video is 1280×720 and 12 s, and plays instantly.
class FakeVideoPlatform extends VideoPlayerPlatform {
  final created = <String?>[];
  final played = <int>[];
  final disposed = <int>[];
  final _events = <int, StreamController<VideoEvent>>{};
  var _next = 0;

  @override
  Future<void> init() async {}

  @override
  Future<int?> create(DataSource dataSource) async => _create(dataSource.uri);

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async => _create(options.dataSource.uri);

  int _create(String? uri) {
    created.add(uri);
    final id = _next++;
    final c = _events[id] = StreamController<VideoEvent>();
    c.add(VideoEvent(
      eventType: VideoEventType.initialized,
      size: const Size(1280, 720),
      duration: const Duration(seconds: 12),
    ));
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> dispose(int playerId) async {
    disposed.add(playerId);
    // Not awaited: close() waits for a listener, and the controller already cancelled its own.
    unawaited(_events.remove(playerId)?.close());
  }

  @override
  Future<void> play(int playerId) async => played.add(playerId);

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Widget buildView(int playerId) => SizedBox(key: Key('fake-video-$playerId'));

  @override
  Widget buildViewWithOptions(VideoViewOptions options) => buildView(options.playerId);

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
}
