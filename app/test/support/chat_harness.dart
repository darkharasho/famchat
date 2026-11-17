import 'package:famchat/gifs/klipy.dart';
import 'package:famchat/gifs/providers.dart';
import 'dart:async';
import 'package:material_ui/material_ui.dart' show Size, SizedBox;
import 'package:meta/meta.dart';

import 'package:famchat/chat/directory.dart';
import 'package:famchat/chat/hub_link.dart';
import 'package:famchat/chat/providers.dart';
import 'package:famchat/main.dart';
import 'package:famchat/media/media_db.dart';
import 'package:famchat/media/photo_picker.dart';
import 'package:famchat/media/providers.dart';
import 'package:famchat/session/secure_kv.dart';
import 'package:famchat/voice/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';
import 'fake_chat_backend.dart';
import 'fake_media.dart';
import 'fake_server.dart';
import 'fake_voice.dart';
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
Future<ScriptedHubLink> pumpChatApp(
  WidgetTester tester,
  TestDevice me, {
  String name = 'Alice',
  bool admin = false,
  MediaDb? mediaDb,
  PhotoPicker? picker,
  FakeRecorders? recorders,
  FakeVoicePlayer? player,
  KlipyClient? gifs,
}) async {
  final hub = ScriptedHubLink();
  await tester.runAsync(() async {
    await me.db.bindDevice(me.deviceId); // as ChatSync.start does; binding later would wipe the directory
    await Directory(me.db, me.api, me.me).refresh();
  });
  final server = FakeServer();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      ...sessionOverrides(server, MemorySecureKv()),
      chatDbProvider.overrideWithValue(me.db),
      chatApiProvider.overrideWithValue(me.api),
      hubLinkProvider.overrideWithValue(hub),
      localIdentityProvider.overrideWith((ref) async => me.me),
      mediaDbProvider.overrideWithValue(mediaDb ?? memoryMediaDb()),
      mediaApiProvider.overrideWithValue(me.media),
      photoProcessorProvider.overrideWithValue(FakeProcessor()),
      mediaOffloadProvider.overrideWithValue(null), // isolates never answer under fake time
      if (picker != null) photoPickerProvider.overrideWithValue(picker),
      // No microphone or speaker in tests: fakes, unless a test brings its own.
      voiceRecorderFactoryProvider.overrideWithValue((recorders ?? FakeRecorders()).call),
      voicePlayerFactoryProvider.overrideWithValue(() => player ?? FakeVoicePlayer()),
      // No GIF search unless a test brings a client (the real one needs the server's key).
      gifClientProvider.overrideWith((ref) async => gifs),
    ],
    child: const FamChatApp(),
  ));
  await tester.pumpAndSettle();
  await signInDirectly(tester, server, name: name, admin: admin);
  await settle(tester);
  return hub;
}

/// Lets queued work (database, crypto, fake network) finish under fake time, then settles the UI.
/// Everything touching the app's database stays in the test's fake zone: a query from
/// `runAsync` would wait forever on a lock held by a query parked in the fake zone.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
  await tester.pumpAndSettle();
}

/// Runs [f] (which may use the app's database) in the fake zone, pumping until it completes.
Future<T> inApp<T>(WidgetTester tester, Future<T> Function() f) async {
  var done = false;
  late T value;
  Object? error;
  f().then((v) {
    value = v;
    done = true;
  }, onError: (Object e) {
    error = e;
    done = true;
  });
  for (var i = 0; i < 500 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
  if (error != null) throw error!;
  if (!done) throw StateError('operation did not finish');
  return value;
}
