import 'dart:async';
import 'dart:typed_data';

import 'package:famchat/voice/playback.dart';
import 'package:famchat/voice/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_voice.dart';

Future<Uint8List?> Function() bytes(int n) => () async => Uint8List.fromList([n, n, n]);

void main() {
  late FakeVoicePlayer player;
  late ProviderContainer c;
  var made = 0;

  setUp(() {
    player = FakeVoicePlayer();
    made = 0;
    c = ProviderContainer(overrides: [
      voicePlayerFactoryProvider.overrideWithValue(() {
        made++;
        return player;
      }),
    ]);
  });
  tearDown(() => c.dispose());

  VoicePlayback pb() => c.read(voicePlaybackProvider.notifier);
  PlaybackState st() => c.read(voicePlaybackProvider);
  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test('nothing is created until something plays', () {
    expect(st().messageId, isNull);
    expect(made, 0);
  });

  test('toggle loads, plays, then pauses', () async {
    await pb().toggle('A', bytes(1));
    await flush();
    expect(player.log, ['load A', 'play A']);
    expect(st().messageId, 'A');
    expect(st().playing, isTrue);
    expect(st().duration, const Duration(seconds: 4));
    await pb().toggle('A', bytes(1));
    await flush();
    expect(player.log.last, 'pause A');
    expect(st().playing, isFalse);
    await pb().toggle('A', bytes(1));
    await flush();
    expect(player.log.last, 'play A');
    expect(player.log.where((l) => l.startsWith('load')), hasLength(1));
    expect(made, 1);
  });

  test('playing another clip stops the first', () async {
    await pb().toggle('A', bytes(1));
    await flush();
    await pb().toggle('B', bytes(2));
    await flush();
    expect(player.log, ['load A', 'play A', 'pause A', 'load B', 'play B']);
    expect(st().messageId, 'B');
    expect(st().playing, isTrue);
    expect(made, 1);
  });

  test('position updates the current clip', () async {
    await pb().toggle('A', bytes(1));
    player.moveTo(const Duration(milliseconds: 1500));
    await flush();
    expect(st().position, const Duration(milliseconds: 1500));
    expect(st().progress, closeTo(0.375, 1e-9));
  });

  test('completion resets to the start', () async {
    await pb().toggle('A', bytes(1));
    player.moveTo(const Duration(seconds: 4));
    player.complete();
    await flush();
    await flush();
    expect(st().playing, isFalse);
    expect(st().position, Duration.zero);
    expect(player.log, containsAllInOrder(['pause A', 'seek 0']));
  });

  test('null bytes (expired) leaves it stopped', () async {
    await pb().toggle('A', () async => null);
    await flush();
    expect(st().messageId, isNull);
    expect(st().playing, isFalse);
    expect(player.log, isEmpty);
  });

  test('a failed load shows an error on that clip', () async {
    await pb().toggle('A', () async => throw StateError('network'));
    await flush();
    expect(st().messageId, 'A');
    expect(st().error, isNotNull);
    expect(st().loading, isFalse);
    // Tapping again retries.
    await pb().toggle('A', bytes(1));
    await flush();
    expect(st().error, isNull);
    expect(st().playing, isTrue);
  });

  test('the decoder not knowing the duration falls back to the message', () async {
    player.duration = null;
    await pb().toggle('A', bytes(1), duration: const Duration(seconds: 9));
    expect(st().duration, const Duration(seconds: 9));
  });

  test('seek on the current clip seeks to the fraction', () async {
    await pb().toggle('A', bytes(1));
    await pb().seek('A', 0.5, bytes(1));
    expect(player.log.last, 'seek 2000');
    expect(st().position, const Duration(seconds: 2));
  });

  test('seek on another clip loads it paused at the fraction', () async {
    await pb().toggle('A', bytes(1));
    await pb().seek('B', 0.25, bytes(2));
    await flush();
    expect(player.log, ['load A', 'play A', 'pause A', 'load B', 'seek 1000']);
    expect(st().messageId, 'B');
    expect(st().playing, isFalse);
  });

  test('a slower earlier load does not win over a later tap', () async {
    final slow = Completer<Uint8List?>();
    final first = pb().toggle('A', () => slow.future);
    await pb().toggle('B', bytes(2));
    slow.complete(Uint8List(3));
    await first;
    await flush();
    expect(st().messageId, 'B');
    expect(player.log.where((l) => l.startsWith('load')), ['load B']);
  });

  test('dispose is time-boxed', () async {
    player.hangDispose = true;
    await pb().toggle('A', bytes(1));
    final sw = Stopwatch()..start();
    c.dispose();
    c = ProviderContainer(); // for tearDown
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(player.disposed, isTrue);
    expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
  });
}
