// Phones close the hub socket in the background (so the server pushes right away); this lets a
// message that is still sending finish first.
import 'dart:async';

import 'package:flutter/services.dart';

import 'hub_link.dart';

/// Extra running time the OS grants an app that just went to the background (iOS:
/// `beginBackgroundTask`). [begin] returns a handle for [end], or null if none was granted.
abstract interface class BackgroundTask {
  Future<Object?> begin();
  Future<void> end(Object? id);
}

/// Platforms that keep a backgrounded app running for a while anyway (Android).
class NoBackgroundTask implements BackgroundTask {
  const NoBackgroundTask();
  @override
  Future<Object?> begin() async => null;
  @override
  Future<void> end(Object? id) async {}
}

/// iOS: the `famchat/background_task` channel in AppDelegate.swift.
class IosBackgroundTask implements BackgroundTask {
  const IosBackgroundTask();
  static const _channel = MethodChannel('famchat/background_task');

  @override
  Future<Object?> begin() async {
    try {
      return await _channel.invokeMethod<int>('begin');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> end(Object? id) async {
    if (id == null) return;
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
    final id = await task.begin();
    try {
      for (var waited = Duration.zero; waited < grace; waited += poll) {
        await Future<void>.delayed(poll);
        if (gen != _generation || !await _unsent()) break;
      }
      if (gen == _generation) await hub.stop();
    } finally {
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
