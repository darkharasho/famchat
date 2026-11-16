import 'dart:io';

import 'package:famchat/spikes/ws_spike.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/echo_server.dart' as echo;

void main() {
  late HttpServer server;
  setUpAll(() async => server = await echo.serve(0));
  tearDownAll(() => server.close(force: true));

  test('echo round-trip', () async {
    final r = await wsEchoRoundTrip(Uri.parse('ws://localhost:${server.port}/echo'));
    expect(r.textOk, isTrue);
    expect(r.bigTextOk, isTrue);
    expect(r.binaryOk, isTrue);
    expect(r.rtt, greaterThan(Duration.zero));
  });

  test('echoUrl default', () {
    expect(echoUrl(), Uri.parse('ws://localhost:8787/echo'));
  });
}
