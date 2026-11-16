// One composer's recording session: permission, elapsed time, live levels, the 10-minute cap.
import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../audio_init.dart';
import 'voice_recorder.dart';
import 'waveform.dart';

enum RecordingStatus {
  idle,
  starting,
  recording,

  /// The last start was refused the microphone.
  denied,

  /// The last start or stop failed (no input device, empty output).
  failed,
}

class VoiceRecording extends ChangeNotifier {
  VoiceRecording(this._make, {this.onAutoStop, this.cap = maxVoiceDuration});

  final VoiceRecorder Function() _make;

  /// Gets the clip when the recording reaches [cap] and stops itself.
  void Function(RecordedVoice clip)? onAutoStop;
  final Duration cap;

  RecordingStatus _status = RecordingStatus.idle;
  RecordingStatus get status => _status;

  VoiceRecorder? _rec;
  Stopwatch? _sw;
  Timer? _ticker;
  StreamSubscription<double>? _levelSub;
  final _levels = <double>[];
  int _session = 0;
  bool _disposed = false;

  /// How long the current recording has run (zero when not recording), at most [cap].
  Duration get elapsed {
    final sw = _sw;
    if (sw == null) return Duration.zero;
    return sw.elapsed > cap ? cap : sw.elapsed;
  }

  /// Every level (0..1) of the current recording, oldest first.
  List<double> get levels => List.unmodifiable(_levels);

  bool get active => _status == RecordingStatus.starting || _status == RecordingStatus.recording;

  void _set(RecordingStatus s) {
    _status = s;
    if (!_disposed) notifyListeners();
  }

  Future<void> start() async {
    if (active || _disposed) return;
    final session = ++_session;
    _set(RecordingStatus.starting);
    final rec = _make();
    _rec = rec;
    try {
      if (!await rec.permission()) {
        if (session == _session) {
          _rec = null;
          _set(RecordingStatus.denied);
        }
        await disposeWithin(rec.dispose);
        return;
      }
      if (session != _session) {
        await disposeWithin(rec.dispose);
        return;
      }
      await rec.start();
    } catch (_) {
      if (session == _session) {
        _rec = null;
        _set(RecordingStatus.failed);
      }
      await disposeWithin(rec.dispose);
      return;
    }
    if (session != _session) {
      // Cancelled while the recorder was starting.
      try {
        await rec.cancel();
      } catch (_) {}
      await disposeWithin(rec.dispose);
      return;
    }
    _levels.clear();
    _sw = clock.stopwatch()..start();
    _levelSub = rec.levels().listen(_levels.add, onError: (_) {});
    _ticker = Timer.periodic(levelInterval, (_) {
      if (_sw != null && _sw!.elapsed >= cap) {
        unawaited(_autoStop());
      } else {
        notifyListeners();
      }
    });
    _set(RecordingStatus.recording);
  }

  Future<void> _autoStop() async {
    final clip = await finish();
    if (clip != null) onAutoStop?.call(clip);
  }

  void _stopClock() {
    _ticker?.cancel();
    _ticker = null;
    unawaited(_levelSub?.cancel());
    _levelSub = null;
  }

  /// Stops and returns the clip; null when nothing was recording or the recorder produced nothing.
  Future<RecordedVoice?> finish() async {
    final rec = _rec;
    if (_status != RecordingStatus.recording || rec == null) return null;
    _session++;
    final duration = elapsed;
    final waveform = downsampleWaveform(_levels);
    _stopClock();
    _sw = null;
    _rec = null;
    _set(RecordingStatus.idle);
    try {
      final bytes = await rec.stop();
      if (bytes == null || bytes.isEmpty || duration <= Duration.zero) {
        _set(RecordingStatus.failed);
        return null;
      }
      return RecordedVoice(bytes: bytes, duration: duration, waveform: waveform);
    } catch (_) {
      _set(RecordingStatus.failed);
      return null;
    } finally {
      await disposeWithin(rec.dispose);
    }
  }

  /// Stops and discards (also while starting).
  Future<void> cancel() async {
    final rec = _rec;
    final wasRecording = _status == RecordingStatus.recording;
    _session++;
    _stopClock();
    _sw = null;
    _rec = null;
    if (_status != RecordingStatus.idle) _set(RecordingStatus.idle);
    if (rec == null || !wasRecording) return; // a start in flight cleans up after itself
    try {
      await rec.cancel();
    } catch (_) {
      // nothing to keep anyway
    }
    await disposeWithin(rec.dispose);
  }

  @override
  void dispose() {
    unawaited(cancel());
    _disposed = true;
    super.dispose();
  }
}
