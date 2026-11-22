import 'dart:async';
import 'dart:typed_data';

import 'package:famchat/transcripts/model.dart';
import 'package:famchat/transcripts/sherpa_transcriber.dart';
import 'package:famchat/transcripts/transcriber.dart';
import 'package:flutter_test/flutter_test.dart';

const _paths = ModelPaths(encoder: 'e', decoder: 'd', tokens: 't', vad: 'v');

class _Fake implements Transcriber {
  int inFlight = 0, maxInFlight = 0;
  final jobs = <String, Completer<TranscriptResult>>{};
  @override
  Future<TranscriptResult> transcribe(String m4aPath, ModelPaths paths) async {
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      return await (jobs[m4aPath] = Completer<TranscriptResult>()).future;
    } finally {
      inFlight--;
    }
  }
}

void main() {
  test('runs one job at a time, in order', () async {
    final fake = _Fake();
    final t = SerialTranscriber(fake);
    final results = <String>[];
    final all = [for (final p in ['a', 'b', 'c']) t.transcribe(p, _paths).then((r) => results.add(r.text))];
    for (final p in ['a', 'b', 'c']) {
      await pumpEventQueue();
      expect(fake.jobs.keys.last, p);
      fake.jobs[p]!.complete(TranscriptResult('text $p', null));
    }
    await Future.wait(all);
    expect(fake.maxInFlight, 1);
    expect(results, ['text a', 'text b', 'text c']);
  });

  test("a failing job doesn't block the next", () async {
    final fake = _Fake();
    final t = SerialTranscriber(fake);
    final first = t.transcribe('a', _paths);
    final second = t.transcribe('b', _paths);
    await pumpEventQueue();
    fake.jobs['a']!.completeError(StateError('boom'));
    await expectLater(first, throwsStateError);
    await pumpEventQueue();
    fake.jobs['b']!.complete(const TranscriptResult('ok', 'en'));
    expect((await second).text, 'ok');
  });

  test('resampleLinear keeps duration and shape', () {
    final input = Float32List.fromList(List.generate(44100, (i) => i.isEven ? 0.5 : 0.5));
    final out = resampleLinear(input, 44100, 16000);
    expect(out.length, 16000);
    expect(out.every((x) => (x - 0.5).abs() < 1e-6), isTrue);
  });
}
