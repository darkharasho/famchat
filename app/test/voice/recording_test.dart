import 'package:famchat/voice/recording.dart';
import 'package:famchat/voice/waveform.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_voice.dart';

void main() {
  late FakeRecorders recorders;
  setUp(() => recorders = FakeRecorders());

  test('records and finishes with a 64-bucket waveform and the elapsed duration', () {
    fakeAsync((async) {
      final r = VoiceRecording(recorders.call);
      r.start();
      async.flushMicrotasks();
      expect(r.status, RecordingStatus.recording);
      for (var i = 0; i < 30; i++) {
        recorders.last.level(i.isEven ? 0.2 : 0.8);
        async.elapse(levelInterval);
      }
      expect(r.elapsed, const Duration(seconds: 3));
      expect(r.levels, hasLength(30));
      RecordedVoice? out;
      r.finish().then((v) => out = v);
      async.flushMicrotasks();
      expect(out, isNotNull);
      expect(out!.duration, const Duration(seconds: 3));
      expect(out!.waveform, hasLength(waveformBuckets));
      expect(out!.waveform.reduce((a, b) => a > b ? a : b), 204);
      expect(out!.bytes, recorders.last.output);
      expect(recorders.last.calls, ['permission', 'start', 'stop', 'dispose']);
      expect(r.status, RecordingStatus.idle);
      expect(r.elapsed, Duration.zero);
      r.dispose();
    });
  });

  test('notifies listeners while recording so the timer moves', () {
    fakeAsync((async) {
      final r = VoiceRecording(recorders.call);
      var n = 0;
      r.addListener(() => n++);
      r.start();
      async.flushMicrotasks();
      final before = n;
      async.elapse(const Duration(seconds: 1));
      expect(n - before, greaterThanOrEqualTo(5));
      r.dispose();
    });
  });

  test('cancel discards the recording', () {
    fakeAsync((async) {
      final r = VoiceRecording(recorders.call);
      r.start();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 2));
      r.cancel();
      async.flushMicrotasks();
      expect(recorders.last.calls, ['permission', 'start', 'cancel', 'dispose']);
      expect(r.status, RecordingStatus.idle);
      RecordedVoice? out;
      r.finish().then((v) => out = v);
      async.flushMicrotasks();
      expect(out, isNull);
      r.dispose();
    });
  });

  test('denied permission shows the hint and stays idle', () {
    fakeAsync((async) {
      recorders.granted = false;
      final r = VoiceRecording(recorders.call);
      r.start();
      async.flushMicrotasks();
      expect(r.status, RecordingStatus.denied);
      expect(recorders.last.calls, ['permission', 'dispose']);
      async.elapse(const Duration(seconds: 5));
      expect(r.elapsed, Duration.zero);
      // Trying again asks again.
      recorders.granted = true;
      r.start();
      async.flushMicrotasks();
      expect(r.status, RecordingStatus.recording);
      r.dispose();
    });
  });

  test('a recorder that fails to start reports failed', () {
    fakeAsync((async) {
      final r = VoiceRecording(() => FakeVoiceRecorder(failStart: true));
      r.start();
      async.flushMicrotasks();
      expect(r.status, RecordingStatus.failed);
      r.dispose();
    });
  });

  test('auto-stops at ten minutes', () {
    fakeAsync((async) {
      RecordedVoice? auto;
      final r = VoiceRecording(recorders.call, onAutoStop: (v) => auto = v);
      r.start();
      async.flushMicrotasks();
      async.elapse(maxVoiceDuration - const Duration(milliseconds: 100));
      expect(auto, isNull);
      expect(r.status, RecordingStatus.recording);
      async.elapse(const Duration(milliseconds: 250));
      expect(auto, isNotNull);
      expect(auto!.duration, maxVoiceDuration);
      expect(r.status, RecordingStatus.idle);
      expect(recorders.last.calls, contains('stop'));
      r.dispose();
    });
  });

  test('an empty recording finishes as failed, not as a clip', () {
    fakeAsync((async) {
      final rec = FakeVoiceRecorder()..output = null;
      final r = VoiceRecording(() => rec);
      r.start();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      RecordedVoice? out;
      var done = false;
      r.finish().then((v) {
        out = v;
        done = true;
      });
      async.flushMicrotasks();
      expect(done, isTrue);
      expect(out, isNull);
      expect(r.status, RecordingStatus.failed);
      r.dispose();
    });
  });

  test('cancel while starting stops the recorder once it starts', () {
    fakeAsync((async) {
      final r = VoiceRecording(recorders.call);
      r.start();
      r.cancel();
      async.flushMicrotasks();
      expect(r.status, RecordingStatus.idle);
      expect(recorders.last.calls.last, 'dispose');
      expect(recorders.last.calls, isNot(contains('stop')));
      r.dispose();
    });
  });

  test('dispose while recording cancels the recorder', () {
    fakeAsync((async) {
      final r = VoiceRecording(recorders.call);
      r.start();
      async.flushMicrotasks();
      r.dispose();
      async.flushMicrotasks();
      expect(recorders.last.calls, containsAllInOrder(['cancel', 'dispose']));
    });
  });
}
