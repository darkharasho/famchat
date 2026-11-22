import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:famchat/transcripts/model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

final _bodies = {
  'base-encoder.int8.onnx': utf8.encode('encoder' * 100),
  'base-decoder.int8.onnx': utf8.encode('decoder' * 300),
  'base-tokens.txt': utf8.encode('tokens'),
};
final _files = [
  for (final e in _bodies.entries) ModelFile(e.key, e.value.length, sha256.convert(e.value).toString()),
];

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('model_test'));
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  ProviderContainer container(http.Client client) {
    final c = ProviderContainer(overrides: [
      modelFilesProvider.overrideWithValue(_files),
      modelBaseUrlProvider.overrideWithValue('https://example.test'),
      modelDirProvider.overrideWithValue(() async => dir),
      modelHttpClientProvider.overrideWithValue(client),
      vadBytesProvider.overrideWithValue(() async => [1, 2, 3]),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  http.Client serving(Map<String, List<int>> bodies) => MockClient.streaming((req, _) async {
        final b = bodies[p.basename(req.url.path)];
        if (b == null) return http.StreamedResponse(const Stream.empty(), 404);
        // Two chunks, so progress moves twice per file.
        final half = b.length ~/ 2;
        return http.StreamedResponse(Stream.fromIterable([b.sublist(0, half), b.sublist(half)]), 200);
      });

  Future<ModelState> settled(ProviderContainer c) async {
    c.read(transcriptModelProvider);
    await c.read(transcriptModelProvider.notifier).refresh();
    return c.read(transcriptModelProvider);
  }

  test('absent until every file is there with its size', () async {
    final c = container(serving(_bodies));
    expect(await settled(c), isA<ModelAbsent>());
    for (final f in _files) {
      await File(p.join(dir.path, '${f.name}.part')).writeAsBytes(_bodies[f.name]!);
    }
    expect(await settled(c), isA<ModelAbsent>());
  });

  test('download reports progress, verifies, and is ready', () async {
    final c = container(serving(_bodies));
    await settled(c);
    final seen = <ModelState>[];
    c.listen(transcriptModelProvider, (_, s) => seen.add(s));
    await c.read(transcriptModelProvider.notifier).download();
    final received = seen.whereType<ModelDownloading>().map((s) => s.received).toList();
    expect(received.length, greaterThan(3));
    expect(received, orderedEquals([...received]..sort()));
    final ready = c.read(transcriptModelProvider);
    expect(ready, isA<ModelReady>());
    expect(File((ready as ModelReady).paths.vad).readAsBytesSync(), [1, 2, 3]);
    expect(File(ready.paths.decoder).readAsBytesSync(), _bodies['base-decoder.int8.onnx']);
    // A new start finds it ready.
    expect(await settled(container(serving(const {}))), isA<ModelReady>());
  });

  test('a bad hash fails and leaves nothing', () async {
    final bad = {..._bodies, 'base-tokens.txt': utf8.encode('tokenX')};
    final c = container(serving(bad));
    await settled(c);
    await c.read(transcriptModelProvider.notifier).download();
    expect(c.read(transcriptModelProvider), isA<ModelFailed>());
    expect(dir.listSync().where((e) => e.path.endsWith('.part') || e.path.endsWith('tokens.txt')), isEmpty);
  });

  test('cancel stops and cleans up', () async {
    final hang = StreamController<List<int>>();
    final c = container(MockClient.streaming((req, _) async => http.StreamedResponse(hang.stream, 200)));
    await settled(c);
    final download = c.read(transcriptModelProvider.notifier).download();
    await pumpEventQueue();
    hang.add([1, 2, 3]);
    await pumpEventQueue();
    expect(c.read(transcriptModelProvider), isA<ModelDownloading>());
    c.read(transcriptModelProvider.notifier).cancel();
    await download.timeout(const Duration(seconds: 5));
    expect(c.read(transcriptModelProvider), isA<ModelAbsent>());
    expect(dir.listSync().where((e) => e.path.endsWith('.part')), isEmpty);
  });

  test('remove deletes the files and goes absent', () async {
    final c = container(serving(_bodies));
    await settled(c);
    await c.read(transcriptModelProvider.notifier).download();
    expect(c.read(transcriptModelProvider), isA<ModelReady>());
    await c.read(transcriptModelProvider.notifier).remove();
    expect(c.read(transcriptModelProvider), isA<ModelAbsent>());
    expect(await dir.exists(), isFalse);
  });

  test('a truncated VAD copy is written again, whole', () async {
    final c = container(serving(_bodies));
    await settled(c);
    await c.read(transcriptModelProvider.notifier).download();
    final vad = File(p.join(dir.path, 'silero_vad.onnx'));
    await vad.writeAsBytes([1]);
    expect(await settled(c), isA<ModelReady>());
    expect(await vad.readAsBytes(), [1, 2, 3]);
  });

  test("a killed run's partial file is cleared by the next download", () async {
    await File(p.join(dir.path, 'base-tokens.txt.7.part')).writeAsBytes([9, 9]);
    final c = container(serving(_bodies));
    await settled(c);
    await c.read(transcriptModelProvider.notifier).download();
    expect(c.read(transcriptModelProvider), isA<ModelReady>());
    expect(dir.listSync().where((e) => e.path.endsWith('.part')), isEmpty);
  });

  test('cancel, then download again at once, succeeds', () async {
    final hang = StreamController<List<int>>();
    var first = true;
    final ok = serving(_bodies);
    final c = container(MockClient.streaming((req, body) async {
      if (first) {
        first = false;
        return http.StreamedResponse(hang.stream, 200);
      }
      return ok.send(http.Request(req.method, req.url));
    }));
    await settled(c);
    final n = c.read(transcriptModelProvider.notifier);
    final one = n.download();
    await pumpEventQueue();
    hang.add([1, 2, 3]);
    await pumpEventQueue();
    n.cancel();
    final two = n.download();
    await Future.wait([one, two]).timeout(const Duration(seconds: 5));
    expect(c.read(transcriptModelProvider), isA<ModelReady>());
    expect(dir.listSync().where((e) => e.path.endsWith('.part')), isEmpty);
  });
}
