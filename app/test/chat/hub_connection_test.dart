import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:famchat/api/models.dart';
import 'package:famchat/chat/hub_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class FakeSocket with StreamChannelMixin<dynamic> implements WebSocketChannel {
  FakeSocket(this.uri, {this.fail = false});
  final Uri uri;
  final bool fail;
  final incoming = StreamController<dynamic>();
  final sent = <Map<String, Object?>>[];
  bool closed = false;
  late final _FakeSink _sink = _FakeSink(this);

  void serverSend(Map<String, Object?> m) => incoming.add(jsonEncode(m));
  void serverClose() => incoming.close();

  @override
  Stream<dynamic> get stream => incoming.stream;
  @override
  WebSocketSink get sink => _sink;
  @override
  Future<void> get ready => fail ? Future.error(WebSocketChannelException('refused')) : Future.value();
  @override
  String? get protocol => null;
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this.s);
  final FakeSocket s;
  @override
  void add(dynamic data) => s.sent.add(jsonDecode(data as String) as Map<String, Object?>);
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<dynamic> stream) async {}
  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    s.closed = true;
    if (!s.incoming.isClosed) await s.incoming.close();
  }

  @override
  Future<void> get done => Future.value();
}

/// nextDouble() == 0.5 → no jitter.
class MidRandom implements Random {
  @override
  bool nextBool() => false;
  @override
  double nextDouble() => 0.5;
  @override
  int nextInt(int max) => 0;
}

class Harness {
  Harness({this.failFirst = 0});
  int failFirst;
  final sockets = <FakeSocket>[];
  int tickets = 0;
  Object? ticketError;
  late final HubConnection hub = HubConnection(
    ticket: () async {
      final e = ticketError;
      if (e != null) throw e;
      return 'T${++tickets}';
    },
    apiBase: Uri.parse('https://famchat.dev'),
    connect: (uri) {
      final s = FakeSocket(uri, fail: failFirst-- > 0);
      sockets.add(s);
      return s;
    },
    random: MidRandom(),
  );
  final states = <bool>[];
  final events = <Map<String, Object?>>[];
  void listen() {
    hub.connection.listen(states.add);
    hub.events.listen(events.add);
  }
}

void main() {
  test('wsUri maps schemes', () {
    expect(HubConnection.wsUri(Uri.parse('https://famchat.dev'), 'a+b').toString(), 'wss://famchat.dev/api/ws?ticket=a%2Bb');
    expect(HubConnection.wsUri(Uri.parse('http://localhost:8787'), 'T').toString(), 'ws://localhost:8787/api/ws?ticket=T');
  });

  test('connects, delivers events and sends frames', () {
    fakeAsync((async) {
      final h = Harness()..listen();
      h.hub.start();
      async.flushMicrotasks();
      expect(h.hub.connected, isTrue);
      expect(h.states, [true]);
      expect(h.sockets.single.uri.queryParameters['ticket'], 'T1');
      h.sockets.single.serverSend({'type': 'hello', 'online': []});
      async.flushMicrotasks();
      expect(h.events.single['type'], 'hello');
      expect(h.hub.send({'type': 'typing', 'chatId': 'C'}), isTrue);
      expect(h.sockets.single.sent.single, {'type': 'typing', 'chatId': 'C'});
      h.hub.stop();
      async.flushMicrotasks();
    });
  });

  test('reconnects with backoff and a fresh ticket after a drop', () {
    fakeAsync((async) {
      final h = Harness()..listen();
      h.hub.start();
      async.flushMicrotasks();
      h.sockets.single.serverClose();
      async.flushMicrotasks();
      expect(h.hub.connected, isFalse);
      expect(h.hub.send({'type': 'ping'}), isFalse);
      async.elapse(const Duration(milliseconds: 900));
      expect(h.sockets, hasLength(1));
      async.elapse(const Duration(milliseconds: 200));
      expect(h.sockets, hasLength(2));
      expect(h.sockets.last.uri.queryParameters['ticket'], 'T2');
      expect(h.states, [true, false, true]);
      h.hub.stop();
      async.flushMicrotasks();
    });
  });

  test('backoff grows across failed attempts and resets after a stable connection', () {
    fakeAsync((async) {
      final h = Harness(failFirst: 3)..listen();
      h.hub.start();
      async.flushMicrotasks();
      expect(h.sockets, hasLength(1)); // failed
      async.elapse(const Duration(seconds: 1));
      expect(h.sockets, hasLength(2)); // failed, next in 2 s
      async.elapse(const Duration(milliseconds: 1900));
      expect(h.sockets, hasLength(2));
      async.elapse(const Duration(milliseconds: 100));
      expect(h.sockets, hasLength(3)); // failed, next in 4 s
      async.elapse(const Duration(seconds: 4));
      expect(h.sockets, hasLength(4));
      expect(h.hub.connected, isTrue);
      // Stays up long enough, answering pings: the next drop starts again at 1 s.
      for (var i = 0; i < 2; i++) {
        async.elapse(const Duration(seconds: 25));
        h.sockets.last.serverSend({'type': 'pong'});
        async.flushMicrotasks();
      }
      h.sockets.last.serverClose();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      expect(h.sockets, hasLength(5));
      h.hub.stop();
      async.flushMicrotasks();
    });
  });

  test('a missing pong forces a reconnect; pongs are not events', () {
    fakeAsync((async) {
      final h = Harness()..listen();
      h.hub.start();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 25));
      expect(h.sockets.single.sent.last, {'type': 'ping'});
      h.sockets.single.serverSend({'type': 'pong'});
      async.elapse(const Duration(seconds: 11));
      expect(h.hub.connected, isTrue);
      expect(h.events, isEmpty);
      async.elapse(const Duration(seconds: 14)); // next ping at 50 s, no answer
      async.elapse(const Duration(seconds: 10));
      expect(h.sockets.first.closed, isTrue);
      expect(h.hub.connected, isFalse);
      async.elapse(const Duration(seconds: 1));
      expect(h.sockets, hasLength(2));
      h.hub.stop();
      async.flushMicrotasks();
    });
  });

  test('stop prevents reconnect', () {
    fakeAsync((async) {
      final h = Harness()..listen();
      h.hub.start();
      async.flushMicrotasks();
      h.hub.stop();
      async.flushMicrotasks();
      expect(h.sockets.single.closed, isTrue);
      async.elapse(const Duration(minutes: 5));
      expect(h.sockets, hasLength(1));
      expect(h.states, [true, false]);
    });
  });

  test('signed out stops reconnecting; other ticket errors retry', () {
    fakeAsync((async) {
      final h = Harness()..listen();
      h.ticketError = const NetworkException('offline');
      h.hub.start();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      h.ticketError = const SignedOutException();
      async.elapse(const Duration(seconds: 2));
      h.ticketError = null;
      async.elapse(const Duration(minutes: 5));
      expect(h.sockets, isEmpty);
      expect(h.tickets, 0);
    });
  });

  test('stop then start during a pending connect leaves exactly one socket', () {
    fakeAsync((async) {
      final gates = <Completer<String>>[];
      final sockets = <FakeSocket>[];
      final hub = HubConnection(
        ticket: () {
          final c = Completer<String>();
          gates.add(c);
          return c.future;
        },
        apiBase: Uri.parse('https://famchat.dev'),
        connect: (uri) {
          final s = FakeSocket(uri);
          sockets.add(s);
          return s;
        },
        random: MidRandom(),
      );
      final states = <bool>[];
      hub.connection.listen(states.add);
      hub.start();
      async.flushMicrotasks();
      hub.stop(); // the app was paused while the ticket was on its way
      hub.start(); // and resumed
      async.flushMicrotasks();
      expect(gates, hasLength(2));
      gates[1].complete('T2');
      async.flushMicrotasks();
      gates[0].complete('T1'); // the first attempt finishes late
      async.flushMicrotasks();
      expect(sockets.where((s) => !s.closed).map((s) => s.uri.queryParameters['ticket']), ['T2']);
      expect(states, [true]);
      expect(hub.connected, isTrue);
      async.elapse(const Duration(seconds: 30));
      expect(sockets.where((s) => !s.closed), hasLength(1));
      hub.stop();
      async.flushMicrotasks();
    });
  });
}
