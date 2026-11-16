import 'dart:async';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class WsResult {
  const WsResult({required this.textOk, required this.bigTextOk, required this.binaryOk, required this.rtt});
  final bool textOk;
  final bool bigTextOk;
  final bool binaryOk;
  final Duration rtt;

  bool get allOk => textOk && bigTextOk && binaryOk;

  @override
  String toString() => 'text=$textOk big=$bigTextOk binary=$binaryOk rtt=${rtt.inMilliseconds}ms';
}

/// Echo server URL; override with --dart-define=ECHO_URL=... (Android emulator: ws://10.0.2.2:8787/echo).
Uri echoUrl() => Uri.parse(const String.fromEnvironment('ECHO_URL', defaultValue: 'ws://localhost:8787/echo'));

/// Sends "ping", a 65 536-char text frame and bytes 0..255; each must come back unchanged.
/// No custom headers: browsers can't set them.
Future<WsResult> wsEchoRoundTrip(Uri url) async {
  final channel = WebSocketChannel.connect(url);
  final timeout = const Duration(seconds: 10);
  try {
    await channel.ready.timeout(timeout);
    final incoming = StreamIterator(channel.stream);
    Future<Object?> next() async => await incoming.moveNext().timeout(timeout) ? incoming.current : null;

    final sw = Stopwatch()..start();
    channel.sink.add('ping');
    final textOk = await next() == 'ping';
    final rtt = sw.elapsed;

    final big = List.generate(65536, (i) => String.fromCharCode(97 + i % 26)).join();
    channel.sink.add(big);
    final bigTextOk = await next() == big;

    final bytes = Uint8List.fromList(List.generate(256, (i) => i));
    channel.sink.add(bytes);
    final got = await next();
    final binaryOk = got is List<int> && const ListEquality<int>().equals(got, bytes);

    return WsResult(textOk: textOk, bigTextOk: bigTextOk, binaryOk: binaryOk, rtt: rtt);
  } finally {
    await channel.sink.close();
  }
}
