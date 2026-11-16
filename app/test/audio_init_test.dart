import 'dart:async';

import 'package:famchat/audio_init.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a failing audio backend init is caught and returned', () {
    final err = initAudioBackend(init: () => throw StateError('libmpv missing'));
    expect(err, isA<StateError>());
  });

  test('a working audio backend init returns null', () {
    var called = false;
    expect(initAudioBackend(init: () => called = true), isNull);
    expect(called, isTrue);
  });

  test('disposeWithin gives up after the timeout', () {
    fakeAsync((async) {
      var done = false;
      disposeWithin(() => Completer<void>().future).then((_) => done = true);
      async.elapse(const Duration(milliseconds: 2900));
      expect(done, isFalse);
      async.elapse(const Duration(milliseconds: 200));
      expect(done, isTrue);
    });
  });

  test('disposeWithin swallows errors', () async {
    await disposeWithin(() async => throw StateError('boom'));
    await disposeWithin(() => throw StateError('sync boom'));
  });

  test('disposeWithin returns as soon as dispose does', () async {
    var called = false;
    await disposeWithin(() async => called = true);
    expect(called, isTrue);
  });
}
