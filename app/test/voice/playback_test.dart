import 'dart:async';
import 'dart:typed_data';

import 'package:famchat/voice/playback.dart';
import 'package:famchat/voice/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_voice.dart';

/// Stands in for the signed-in session: bumping it is a sign-out/in.
final _session = NotifierProvider<_Session, int>(_Session.new);

class _Session extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

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
      voiceScopeProvider.overrideWith((ref) => ref.watch(_session)),
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

  test('disposing the container disposes the player without waiting on a hung dispose', () async {
    player.hangDispose = true;
    await pb().toggle('A', bytes(1));
    final sw = Stopwatch()..start();
    c.dispose();
    c = ProviderContainer(); // for tearDown
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(player.disposed, isTrue);
    expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('seeking while the clip loads does not load it again', () async {
    final gate = Completer<Uint8List?>();
    var loads = 0;
    Future<Uint8List?> slow() {
      loads++;
      return gate.future;
    }

    final first = pb().seek('A', 0.1, slow);
    await flush();
    for (final f in [0.2, 0.3, 0.5]) {
      unawaited(pb().seek('A', f, slow));
    }
    await flush();
    gate.complete(Uint8List(3));
    await first;
    await flush();
    expect(loads, 1);
    expect(player.log, ['load A', 'seek 2000']);
    expect(st().position, const Duration(seconds: 2));
    expect(st().playing, isFalse);
  });

  test('play then seek while loading plays from the seek point', () async {
    final gate = Completer<Uint8List?>();
    final first = pb().toggle('A', () => gate.future);
    await flush();
    unawaited(pb().seek('A', 0.5, bytes(1)));
    await flush();
    gate.complete(Uint8List(3));
    await first;
    await flush();
    expect(player.log, ['load A', 'seek 2000', 'play A']);
    expect(st().playing, isTrue);
  });

  test('tapping play again while loading cancels the play', () async {
    final gate = Completer<Uint8List?>();
    final first = pb().toggle('A', () => gate.future);
    await flush();
    unawaited(pb().toggle('A', bytes(1)));
    await flush();
    gate.complete(Uint8List(3));
    await first;
    await flush();
    expect(player.log, ['load A']);
    expect(st().playing, isFalse);
    expect(st().messageId, 'A');
  });

  test('a playback error shows on the clip and stops it', () async {
    await pb().toggle('A', bytes(1));
    await flush();
    player.fail(StateError('decoder'));
    await flush();
    expect(st().error, isNotNull);
    expect(st().playing, isFalse);
  });

  test('a play that throws shows the error', () async {
    player.failPlay = true;
    await pb().toggle('A', bytes(1));
    await flush();
    expect(st().error, isNotNull);
    expect(st().playing, isFalse);
  });

  test('signing out disposes the player and forgets the clip', () async {
    await pb().toggle('A', bytes(1));
    await flush();
    c.read(_session.notifier).bump();
    await flush();
    expect(st().messageId, isNull);
    expect(player.disposed, isTrue);
  });

  test('stop after the notifier is gone does not throw', () async {
    await pb().toggle('A', bytes(1));
    final old = pb();
    c.read(_session.notifier).bump();
    c.read(voicePlaybackProvider); // rebuilt
    await old.stop();
  });
}
