// Runs every platform spike on a real target. Each test prints `SPIKE <name> <platform> <result>`
// for the spike report. Needs `dart run tool/echo_server.dart` running (see echoUrl()).
import 'dart:convert';

import 'package:famchat/audio_init.dart';
import 'package:famchat/crypto/device_cert.dart';
import 'package:famchat/crypto/envelope.dart';
import 'package:famchat/crypto/keys.dart';
import 'package:famchat/crypto/sealed_box.dart';
import 'package:famchat/spikes/audio_spike.dart';
import 'package:famchat/spikes/db_spike.dart';
import 'package:famchat/spikes/ws_spike.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

final platform = kIsWeb ? 'web' : defaultTargetPlatform.name;

final _lines = <String>[];

void report(String name, Object result) {
  final line = 'SPIKE $name $platform $result';
  _lines.add(line);
  // ignore: avoid_print
  print(line);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // On the web, print() goes to the browser console; flutter drive's driver prints these instead.
  tearDownAll(() => binding.reportData = {'spike': _lines});
  // e.g. libmpv missing on Linux: report it, keep the other spikes running
  final audioInitError = initAudioBackend();

  testWidgets('crypto', (_) async {
    final identity = await newIdentityKey();
    final device = await DeviceKeys.generate();
    final cert = await signDeviceCert(identity: identity, device: device);
    expect(await verifyDeviceCert(cert), isTrue);

    final sealed = await sealBox(await device.encPub(), utf8.encode('chat key'));
    expect(utf8.decode(await openBox(device.enc, sealed)), 'chat key');

    final signPub = await device.signPub();
    final key = newChatKey();
    final body = List.filled(1024, 7);
    final sw = Stopwatch()..start();
    for (var i = 0; i < 100; i++) {
      final env = await encryptEnvelope(chatKey: key, epoch: 1, chatId: 'C', messageId: 'M$i',
          senderDeviceId: 'D', signKey: device.sign, plaintext: body);
      final pt = await decryptEnvelope(envelope: env, chatKey: key, chatId: 'C', messageId: 'M$i',
          senderDeviceId: 'D', senderSignPub: signPub);
      expect(pt.length, 1024);
    }
    sw.stop();
    report('crypto', '${sw.elapsedMilliseconds}ms/100');
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
  });

  testWidgets('database persists across reopen', (_) async {
    final body = await dbRoundTrip('spike_$platform');
    report('db', 'ok');
    expect(body, startsWith('hello '));
  });

  testWidgets('websocket echo', (_) async {
    final r = await wsEchoRoundTrip(echoUrl());
    report('ws', r);
    expect(r.allOk, isTrue);
  });

  testWidgets('audio fixture plays', (_) async {
    if (audioInitError != null) {
      report('audio', 'init failed: $audioInitError');
      fail('audio backend init failed: $audioInitError');
    }
    final r = await playFixture();
    report('audio', r);
    expect(r.duration, isNotNull);
    expect(r.duration!.inMilliseconds, inInclusiveRange(1800, 2200));
    expect(r.reachedEnd, isTrue);
  });

  testWidgets('recorder probe', (_) async {
    try {
      report('recorder', await probeRecorder());
    } catch (e) {
      report('recorder', 'error: $e');
    }
  });
}
