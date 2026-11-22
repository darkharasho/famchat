import 'dart:io';

import 'package:famchat/transcripts/pcm.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('voice_pcm');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('decodeToPcm uses the voice_pcm channel off the desktop', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    String? path;
    messenger.setMockMethodCallHandler(channel, (call) async {
      path = (call.arguments as Map)['path'] as String;
      return {'samples': Float32List.fromList([0.1, -0.2, 0.3]), 'sampleRate': 44100};
    });
    final pcm = await decodeToPcm('/tmp/clip.m4a');
    expect(path, '/tmp/clip.m4a');
    expect(pcm.samples.length, 3);
    expect(pcm.sampleRate, 44100);
  });

  test('a channel error is a PcmException', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    messenger.setMockMethodCallHandler(channel, (call) async => throw PlatformException(code: 'decode_failed', message: 'bad'));
    await expectLater(decodeToPcm('/tmp/clip.m4a'), throwsA(isA<PcmException>()));
  });

  final libmpv = Platform.environment['FAMCHAT_LIBMPV'];
  test('desktop decode via libmpv', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    MediaKit.ensureInitialized(libmpv: libmpv);
    final pcm = await decodeToPcm(File('test/fixtures/tone.m4a').absolute.path);
    expect(pcm.sampleRate, 16000);
    expect(pcm.samples.length, inInclusiveRange(15500, 16600));
    expect(pcm.samples.reduce((a, x) => x.abs() > a ? x.abs() : a), greaterThan(0.05));
  }, skip: libmpv == null ? 'set FAMCHAT_LIBMPV to a libmpv to run' : false);
}
