import 'dart:async';
import 'package:material_ui/material_ui.dart' show Size, SizedBox;
import 'package:meta/meta.dart';

import 'package:famchat/chat/directory.dart';
import 'package:famchat/chat/hub_link.dart';
import 'package:famchat/chat/providers.dart';
import 'package:famchat/main.dart';
import 'package:famchat/session/secure_kv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';
import 'fake_chat_backend.dart';
import 'fake_server.dart';
import 'session_overrides.dart';

/// A hub that stays disconnected unless the test says otherwise; tests push events with [emit].
class ScriptedHubLink implements HubLink {
  final _events = StreamController<Map<String, Object?>>.broadcast();
  final _connection = StreamController<bool>.broadcast();
  final sent = <Map<String, Object?>>[];
  bool _connected = false;

  void emit(Map<String, Object?> e) => _events.add(e);

  void setConnected(bool up) {
    _connected = up;
    _connection.add(up);
  }

  @override
  Stream<Map<String, Object?>> get events => _events.stream;
  @override
  Stream<bool> get connection => _connection.stream;
  @override
  bool get connected => _connected;
  @override
  bool send(Map<String, Object?> msg) {
    if (!_connected) return false;
    sent.add(msg);
    return true;
  }

  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}

/// A widget test that unmounts the app at the end and lets drift's stream-closing timers run,
/// so the framework's pending-timer check passes.
@isTest
void chatTestWidgets(String description, Future<void> Function(WidgetTester tester) body) {
  testWidgets(description, (tester) async {
    await body(tester);
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  });
}

/// Sets the test window to [size] logical pixels.
void setWindow(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Pumps the signed-in app with [me]'s chat stack (database, fake API, scripted hub).
Future<ScriptedHubLink> pumpChatApp(WidgetTester tester, TestDevice me, {String name = 'Alice'}) async {
  final hub = ScriptedHubLink();
  await tester.runAsync(() => Directory(me.db, me.api, me.me).refresh());
  final server = FakeServer();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      ...sessionOverrides(server, MemorySecureKv()),
      chatDbProvider.overrideWithValue(me.db),
      chatApiProvider.overrideWithValue(me.api),
      hubLinkProvider.overrideWithValue(hub),
      localIdentityProvider.overrideWith((ref) async => me.me),
    ],
    child: const FamChatApp(),
  ));
  await tester.pumpAndSettle();
  await signInDirectly(tester, server, name: name);
  await settle(tester);
  return hub;
}

/// Lets real async work (database, crypto, fake network) finish, then settles the UI.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => pump(10));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}
