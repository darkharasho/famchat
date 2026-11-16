// Local WebSocket echo server for the WebSocket spike.
// Run from app/: dart run tool/echo_server.dart [port]   (default 8787)
import 'dart:io';

Future<HttpServer> serve(int port) async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  server.listen((req) async {
    if (req.uri.path == '/echo' && WebSocketTransformer.isUpgradeRequest(req)) {
      final ws = await WebSocketTransformer.upgrade(req);
      ws.listen(ws.add, onDone: ws.close);
    } else {
      req.response
        ..statusCode = HttpStatus.notFound
        ..close();
    }
  });
  return server;
}

Future<void> main(List<String> args) async {
  final server = await serve(args.isEmpty ? 8787 : int.parse(args.first));
  stdout.writeln('listening ${server.port}');
}
