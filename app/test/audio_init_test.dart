import 'package:famchat/audio_init.dart';
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
}
