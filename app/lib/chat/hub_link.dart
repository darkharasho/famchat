// The device's one WebSocket to FamilyHub (docs/protocol.md "WebSocket").
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../api/models.dart';

/// What the sync engine needs from the hub connection; [HubConnection] is the real one.
abstract interface class HubLink {
  /// Hub → client frames, decoded.
  Stream<Map<String, Object?>> get events;

  /// true when a connection opens, false when it closes.
  Stream<bool> get connection;

  bool get connected;

  /// Sends a frame; false when not connected (the caller keeps it for later).
  bool send(Map<String, Object?> msg);

  /// Starts connecting and keeps reconnecting until [stop].
  Future<void> start();

  Future<void> stop();
}

/// The real [HubLink]: a WebSocket authenticated with a one-time ticket, reconnecting with
/// jittered exponential backoff, kept alive with pings.
class HubConnection implements HubLink {
  HubConnection({
    required this.ticket,
    required this.apiBase,
    WebSocketChannel Function(Uri uri)? connect,
    this.backoff = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
      Duration(seconds: 30),
    ],
    this.pingEvery = const Duration(seconds: 25),
    this.pongTimeout = const Duration(seconds: 10),
    this.connectTimeout = const Duration(seconds: 15),
    Random? random,
  })  : _connect = connect ?? WebSocketChannel.connect,
        _random = random ?? Random();

  /// `POST /api/ws/ticket`. A [SignedOutException] stops reconnecting.
  final Future<String> Function() ticket;
  final Uri apiBase;
  final List<Duration> backoff;
  final Duration pingEvery, pongTimeout, connectTimeout;
  final WebSocketChannel Function(Uri uri) _connect;
  final Random _random;

  /// A connection that stays up this long resets the backoff.
  static const stableAfter = Duration(seconds: 10);

  static Uri wsUri(Uri apiBase, String ticket) => apiBase.replace(
        scheme: apiBase.scheme == 'https' ? 'wss' : 'ws',
        path: '/api/ws',
        queryParameters: {'ticket': ticket},
      );

  final _events = StreamController<Map<String, Object?>>.broadcast();
  final _connection = StreamController<bool>.broadcast();

  bool _running = false;

  /// Bumped by [stop]: an [_open] that started before a stop (and a start) gives up after its
  /// awaits instead of opening a second socket.
  int _generation = 0;
  int _attempt = 0;
  WebSocketChannel? _ch;
  StreamSubscription<dynamic>? _sub;
  Timer? _retry, _ping, _pong, _stable;
  bool _connected = false;
  bool _gotFrame = false;

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Stream<bool> get connection => _connection.stream;

  @override
  bool get connected => _connected;

  @override
  bool send(Map<String, Object?> msg) {
    final ch = _ch;
    if (!_connected || ch == null) return false;
    try {
      ch.sink.add(jsonEncode(msg));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    unawaited(_open());
  }

  @override
  Future<void> stop() async {
    _running = false;
    _generation++;
    _retry?.cancel();
    final ch = _ch;
    _teardown();
    if (ch != null) unawaited(ch.sink.close(1000).catchError((_) {}));
  }

  Future<void> _open() async {
    if (!_running || _ch != null) return;
    final gen = _generation;
    bool stale() => !_running || gen != _generation || _ch != null;
    final String t;
    try {
      t = await ticket();
    } on SignedOutException {
      if (gen == _generation) _running = false;
      return;
    } catch (_) {
      if (stale()) return;
      return _scheduleRetry();
    }
    if (stale()) return;
    final WebSocketChannel ch;
    try {
      ch = _connect(wsUri(apiBase, t));
      await ch.ready.timeout(connectTimeout);
    } catch (_) {
      if (stale()) return;
      return _scheduleRetry();
    }
    if (stale()) {
      unawaited(ch.sink.close(1000).catchError((_) {}));
      return;
    }
    _ch = ch;
    _connected = true;
    _connection.add(true);
    _stable = Timer(stableAfter, () => _attempt = 0);
    _ping = Timer.periodic(pingEvery, (_) => _sendPing());
    _sub = ch.stream.listen(_onFrame, onDone: _onClosed, onError: (_) => _onClosed(), cancelOnError: true);
  }

  void _onFrame(dynamic data) {
    _gotFrame = true;
    if (data is! String) return;
    try {
      final m = jsonDecode(data);
      if (m is Map<String, Object?> && m['type'] != 'pong') _events.add(m);
    } on FormatException {
      // Not ours; ignore.
    }
  }

  void _sendPing() {
    _gotFrame = false;
    if (!send({'type': 'ping'})) return;
    _pong?.cancel();
    _pong = Timer(pongTimeout, () {
      if (_gotFrame) return;
      // The connection is dead without telling us: drop it and reconnect.
      final ch = _ch;
      _onClosed();
      if (ch != null) unawaited(ch.sink.close(4000).catchError((_) {}));
    });
  }

  void _onClosed() {
    if (_ch == null) return;
    _teardown();
    _scheduleRetry();
  }

  void _teardown() {
    _ping?.cancel();
    _pong?.cancel();
    _stable?.cancel();
    unawaited(_sub?.cancel());
    _sub = null;
    _ch = null;
    if (_connected) {
      _connected = false;
      _connection.add(false);
    }
  }

  void _scheduleRetry() {
    if (!_running) return;
    final base = backoff[_attempt < backoff.length ? _attempt : backoff.length - 1];
    _attempt++;
    final jitter = 0.8 + 0.4 * _random.nextDouble(); // ±20 %
    _retry?.cancel();
    _retry = Timer(base * jitter, () => unawaited(_open()));
  }
}
