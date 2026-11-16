import 'dart:async';

import 'package:famchat/api/api_client.dart';
import 'package:famchat/api/models.dart';
import 'package:famchat/api/token_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// A server that never answers; records requests and whether they were aborted.
class HangingClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  int aborted = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    final c = Completer<http.StreamedResponse>();
    if (request is http.Abortable && request.abortTrigger != null) {
      request.abortTrigger!.then((_) {
        aborted++;
        if (!c.isCompleted) c.completeError(http.RequestAbortedException(request.url));
      });
    }
    return c.future;
  }
}

void main() {
  testWidgets('refresh retries finish inside the 60 s grace window and abort timed-out requests', (tester) async {
    final client = HangingClient();
    final api = ApiClient(client: client, base: Uri.parse('https://famchat.dev'));
    final tm = TokenManager(
      refreshCall: api.refresh,
      readRefreshToken: () async => 'r',
      saveRefreshToken: (_) async {},
      onRevoked: () async {},
    ); // default retry delays, as in the app
    Object? error;
    unawaited(tm.accessToken().then((_) {}, onError: (Object e) => error = e));
    for (var s = 0; s < 59; s++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(client.requests, hasLength(4), reason: 'every attempt must start inside the grace window');
    expect(error, isA<NetworkException>(), reason: 'and the last one must have given up by 59 s');
    expect(client.aborted, 4);
  });
}
