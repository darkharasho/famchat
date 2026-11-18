import 'dart:async';

import 'package:famchat/chat/background_send.dart';
import 'package:famchat/chat/hub_link.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

class _Hub implements HubLink {
  var running = true;
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Stream<bool> get connection => const Stream.empty();
  @override
  bool get connected => running;
  @override
  bool send(Map<String, Object?> msg) => running;
  @override
  Future<void> start() async => running = true;
  @override
  Future<void> stop() async => running = false;
}

class _Task implements BackgroundTask {
  final log = <String>[];
  var next = 0;
  Future<void> Function()? expire;
  @override
  Future<Object?> begin({required Future<void> Function() onExpired}) async {
    expire = onExpired;
    log.add('begin ${++next}');
    return next;
  }

  @override
  Future<void> end(Object? id) async => log.add('end $id');
}

void main() {
  late _Hub hub;
  late _Task task;
  var unsent = false;
  BackgroundSend make() => BackgroundSend(
        hub: hub,
        unsent: () async => unsent,
        task: task,
        grace: const Duration(seconds: 25),
        poll: const Duration(milliseconds: 500),
      );

  setUp(() {
    hub = _Hub();
    task = _Task();
    unsent = false;
  });

  test('nothing unsent: the hub stops at once, with no background task', () {
    fakeAsync((t) {
      make().paused();
      t.flushMicrotasks();
      expect(hub.running, isFalse);
      expect(task.log, isEmpty);
    });
  });

  test('an unsent message keeps the hub up in a background task until it is sent', () {
    fakeAsync((t) {
      unsent = true;
      make().paused();
      t.elapse(const Duration(seconds: 3));
      expect(hub.running, isTrue);
      expect(task.log, ['begin 1']);
      unsent = false;
      t.elapse(const Duration(seconds: 1));
      expect(hub.running, isFalse);
      expect(task.log, ['begin 1', 'end 1']);
    });
  });

  test('a message still unsent after the grace period: the hub stops anyway', () {
    fakeAsync((t) {
      unsent = true;
      make().paused();
      t.elapse(const Duration(seconds: 24));
      expect(hub.running, isTrue);
      t.elapse(const Duration(seconds: 2));
      expect(hub.running, isFalse);
      expect(task.log, ['begin 1', 'end 1']);
    });
  });

  test('coming back during the grace period keeps the hub up and ends the task', () {
    fakeAsync((t) {
      unsent = true;
      final b = make();
      b.paused();
      t.elapse(const Duration(seconds: 2));
      b.resumed();
      t.elapse(const Duration(seconds: 1));
      unsent = false;
      t.elapse(const Duration(seconds: 30));
      expect(hub.running, isTrue);
      expect(task.log, ['begin 1', 'end 1']);
    });
  });

  test('the OS taking the background time back early stops the hub then', () {
    fakeAsync((t) {
      unsent = true;
      make().paused();
      t.elapse(const Duration(seconds: 5));
      expect(hub.running, isTrue);
      var answered = false;
      // The OS gets its answer (and suspends the app) only once the socket is closed: a suspended
      // app with its socket open would look online, and get no pushes.
      task.expire!().then((_) => answered = hub.running == false);
      t.flushMicrotasks();
      expect(answered, isTrue);
      expect(task.log, ['begin 1', 'end 1']);
    });
  });

  test('an expiry from an earlier pause does not stop the hub after coming back', () {
    fakeAsync((t) {
      unsent = true;
      final b = make();
      b.paused();
      t.elapse(const Duration(seconds: 2));
      b.resumed();
      t.flushMicrotasks();
      task.expire!();
      t.elapse(const Duration(seconds: 1));
      expect(hub.running, isTrue);
    });
  });

  test('a background task that fails to start still waits out the send', () {
    fakeAsync((t) {
      unsent = true;
      BackgroundSend(hub: hub, unsent: () async => unsent, task: const NoBackgroundTask()).paused();
      t.elapse(const Duration(seconds: 2));
      expect(hub.running, isTrue);
      unsent = false;
      t.elapse(const Duration(seconds: 1));
      expect(hub.running, isFalse);
    });
  });
}
