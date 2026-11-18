// Phones close the hub socket in the background (so the server pushes right away); this lets a
// message that is still sending finish first.
import 'dart:async';

import 'package:flutter/services.dart';

import 'hub_link.dart';

/// Extra running time the OS grants an app that just went to the background (iOS:
/// `beginBackgroundTask`). [begin] returns a handle for [end], or null if none was granted;
/// `onExpired` is called if the OS takes the time back before [end]; the OS waits (briefly) for
/// its future before suspending the app.
abstract interface class BackgroundTask {
  Future<Object?> begin({required Future<void> Function() onExpired});
  Future<void> end(Object? id);
}

/// Platforms that keep a backgrounded app running for a while anyway (Android).
class NoBackgroundTask implements BackgroundTask {
  const NoBackgroundTask();
  @override
  Future<Object?> begin({required Future<void> Function() onExpired}) async => null;
  @override
  Future<void> end(Object? id) async {}
}

/// iOS: the `famchat/background_task` channel in AppDelegate.swift, which calls `expired` back
/// with the task's id when iOS ends it early.
class IosBackgroundTask implements BackgroundTask {
  IosBackgroundTask() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'expired') await _expired.remove(call.arguments)?.call();
    });
  }
  static const _channel = MethodChannel('famchat/background_task');
  final _expired = <Object?, Future<void> Function()>{};

  @override
  Future<Object?> begin({required Future<void> Function() onExpired}) async {
    try {
      final id = await _channel.invokeMethod<int>('begin');
      if (id != null) _expired[id] = onExpired;
      return id;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> end(Object? id) async {
    if (id == null) return;
    _expired.remove(id);
    try {
      await _channel.invokeMethod<void>('end', id);
    } catch (_) {
      // Already ended by the OS.
    }
  }
}

/// Stops [hub] when the app is paused, but while [unsent] says a message is still on its way,
/// keeps it up (for at most [grace], inside a [BackgroundTask]) so the message can go out.
class BackgroundSend {
  BackgroundSend({
    required this.hub,
    required this.unsent,
    required this.task,
    this.grace = const Duration(seconds: 25),
    this.poll = const Duration(milliseconds: 500),
  });

  final HubLink hub;
  final Future<bool> Function() unsent;
  final BackgroundTask task;

  /// iOS gives about 30 s; stop a little before.
  final Duration grace, poll;

  /// Bumped by every pause and resume: a wait from an older pause gives up.
  int _generation = 0;

  Future<void> paused() async {
    final gen = ++_generation;
    if (!await _unsent()) {
      if (gen == _generation) await hub.stop();
      return;
    }
    final expired = Completer<void>(), done = Completer<void>();
    final id = await task.begin(onExpired: () {
      if (!expired.isCompleted) expired.complete();
      return done.future;
    });
    try {
      for (var waited = Duration.zero; waited < grace; waited += poll) {
        await Future.any([Future<void>.delayed(poll), expired.future]);
        // Out of time: a suspended app with its socket open would look online (no pushes).
        if (expired.isCompleted || gen != _generation || !await _unsent()) break;
      }
      if (gen == _generation) await hub.stop();
    } finally {
      done.complete();
      await task.end(id);
    }
  }

  Future<void> resumed() async {
    _generation++;
    await hub.start();
  }

  Future<bool> _unsent() async {
    try {
      return await unsent();
    } catch (_) {
      return false;
    }
  }
}
