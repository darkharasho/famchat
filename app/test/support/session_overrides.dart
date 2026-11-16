import 'package:famchat/session/secure_kv.dart';
import 'package:famchat/session/session_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import 'fake_server.dart';

/// Overrides that point the app at [server] and [kv] with no retry delays.
List<Override> sessionOverrides(FakeServer server, SecureKv kv) => [
      secureKvProvider.overrideWithValue(kv),
      httpClientProvider.overrideWithValue(server.client),
      clockProvider.overrideWithValue(() => server.now()),
      refreshRetryDelaysProvider.overrideWithValue(const [Duration.zero]),
    ];

/// Waits until the session has left [SessionLoading].
Future<SessionState> settledSession(ProviderContainer c) async {
  for (var i = 0; i < 200; i++) {
    final s = c.read(sessionProvider);
    if (s is! SessionLoading) return s;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  throw StateError('session still loading');
}
