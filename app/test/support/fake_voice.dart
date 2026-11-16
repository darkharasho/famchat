import 'dart:async';
import 'dart:typed_data';

import 'package:famchat/voice/voice_player.dart';
import 'package:famchat/voice/voice_recorder.dart';

/// A recorder without a microphone: levels are pushed by the test, [stop] returns [output].
class FakeVoiceRecorder implements VoiceRecorder {
  FakeVoiceRecorder({this.isSupported = true, this.granted = true, Uint8List? output, this.failStart = false})
      : output = output ?? Uint8List.fromList(List.generate(1200, (i) => i & 0xff));

  bool isSupported, granted, failStart;
  Uint8List? output;

  /// When set, start/stop wait for it (a slow native recorder).
  Completer<void>? startGate, stopGate;
  final _levels = StreamController<double>.broadcast();
  final calls = <String>[];
  bool get recording => calls.isNotEmpty && calls.last == 'start';

  void level(double v) => _levels.add(v);

  @override
  Future<bool> supported() async => isSupported;
  @override
  Future<bool> permission() async {
    calls.add('permission');
    return granted;
  }

  @override
  Future<void> start() async {
    if (failStart) throw StateError('no input device');
    calls.add('start');
    if (startGate != null) await startGate!.future;
  }

  @override
  Stream<double> levels() => _levels.stream;
  @override
  Future<Uint8List?> stop() async {
    calls.add('stop');
    if (stopGate != null) await stopGate!.future;
    return output;
  }

  @override
  Future<void> cancel() async => calls.add('cancel');
  @override
  Future<void> dispose() async => calls.add('dispose');
}

/// Hands out [FakeVoiceRecorder]s; [last] is the most recent one.
class FakeRecorders {
  FakeRecorders({this.supported = true, this.granted = true});
  bool supported, granted;
  Completer<void>? stopGate;
  final made = <FakeVoiceRecorder>[];
  FakeVoiceRecorder get last => made.last;

  VoiceRecorder call() {
    final r = FakeVoiceRecorder(isSupported: supported, granted: granted)..stopGate = stopGate;
    made.add(r);
    return r;
  }
}

/// A player that plays nothing: the test drives position and completion.
class FakeVoicePlayer implements VoicePlayer {
  FakeVoicePlayer({this.duration = const Duration(seconds: 4), this.hangDispose = false});
  Duration? duration;
  bool hangDispose;
  bool failPlay = false;
  final log = <String>[];
  final loaded = <String, Uint8List>{};
  String? current;
  bool isPlaying = false;
  bool disposed = false;
  final _position = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final _errors = StreamController<Object>.broadcast();

  void fail(Object e) {
    isPlaying = false;
    _errors.add(e);
  }

  void moveTo(Duration d) => _position.add(d);
  void complete() {
    isPlaying = false;
    _playing.add(false);
    _completed.add(null);
  }

  @override
  Future<Duration?> load(String id, Uint8List bytes) async {
    log.add('load $id');
    loaded[id] = bytes;
    current = id;
    return duration;
  }

  @override
  Future<void> play() async {
    if (failPlay) throw StateError('no output device');
    log.add('play $current');
    isPlaying = true;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    log.add('pause $current');
    isPlaying = false;
    _playing.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    log.add('seek ${position.inMilliseconds}');
    _position.add(position);
  }

  @override
  Stream<Duration> get position => _position.stream;
  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<void> get completed => _completed.stream;
  @override
  Stream<Object> get errors => _errors.stream;

  @override
  Future<void> dispose() {
    log.add('dispose');
    disposed = true;
    if (hangDispose) return Completer<void>().future;
    return Future.value();
  }
}
