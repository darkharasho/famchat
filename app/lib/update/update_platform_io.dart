import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import 'release_feed.dart';
import 'update_platform_base.dart';

UpdatePlatform? createUpdatePlatform() {
  if (Platform.isLinux) return LinuxAppImageUpdate(Platform.environment['APPIMAGE']);
  if (Platform.isWindows) return WindowsInstallerUpdate();
  if (Platform.isMacOS) return MacUpdate();
  return null;
}

/// Streams [asset] into [target] and checks its SHA-256. Deletes [target] on any failure.
Future<void> downloadVerified(
  ReleaseAsset asset,
  http.Client client,
  File target,
  void Function(double) onProgress,
) async {
  final expected = asset.sha256;
  if (expected == null) throw const UpdateException('The release has no checksum for this download.');
  final sink = target.openWrite();
  final hash = Sha256().newHashSink();
  try {
    final res = await client.send(http.Request('GET', asset.url));
    if (res.statusCode != 200) throw UpdateException('Download failed (HTTP ${res.statusCode}).');
    final total = res.contentLength ?? asset.size;
    var received = 0;
    await for (final chunk in res.stream) {
      sink.add(chunk);
      hash.add(chunk);
      received += chunk.length;
      if (total > 0) onProgress((received / total).clamp(0, 1).toDouble());
    }
    await sink.flush();
    await sink.close();
    hash.close();
    final got = (await hash.hash()).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    if (got != expected) throw const UpdateException("The download didn't match its checksum.");
  } catch (_) {
    await sink.close().catchError((_) {});
    if (await target.exists()) await target.delete();
    rethrow;
  }
}

/// [downloadVerified] in a background isolate: streaming and hashing a 90 MB file on the UI isolate
/// competes with every frame. Reports progress in whole percents.
Future<void> downloadInBackground(ReleaseAsset asset, File target, void Function(double) onProgress) async {
  final port = ReceivePort();
  final done = Completer<void>();
  port.listen((m) {
    switch (m) {
      case double p:
        onProgress(p);
      case null:
        done.complete();
      case (String error, bool expected):
        done.completeError(expected ? UpdateException(error) : Exception(error));
    }
  });
  try {
    await Isolate.spawn(_downloadIsolate, (asset, target.path, port.sendPort));
    await done.future;
  } finally {
    port.close();
  }
}

Future<void> _downloadIsolate((ReleaseAsset, String, SendPort) args) async {
  final (asset, path, send) = args;
  final client = http.Client();
  var shown = -1;
  try {
    await downloadVerified(asset, client, File(path), (p) {
      final percent = (p * 100).floor();
      if (percent == shown) return;
      shown = percent;
      send.send(percent / 100);
    });
    send.send(null);
  } on UpdateException catch (e) {
    send.send((e.message, true));
  } catch (e) {
    send.send(('$e', false));
  } finally {
    client.close();
  }
}

/// The AppImage replaces its own file (it runs from a mount, so the old file can be swapped).
class LinuxAppImageUpdate implements UpdatePlatform {
  LinuxAppImageUpdate(this.appImagePath);

  /// $APPIMAGE: the AppImage file this app runs from. Null outside an AppImage.
  final String? appImagePath;

  @override
  String get platform => 'linux';

  @override
  bool get canSelfInstall => appImagePath != null;

  // Next to the AppImage, so the final rename stays on one file system.
  String get _staged => '$appImagePath.update';

  @override
  Future<String> download(ReleaseAsset asset, http.Client client, void Function(double) onProgress) async {
    final target = File(_staged);
    await downloadInBackground(asset, target, onProgress);
    final chmod = await Process.run('chmod', ['755', target.path]);
    if (chmod.exitCode != 0) throw const UpdateException("Couldn't make the update runnable.");
    return target.path;
  }

  @override
  Future<void> installAndRestart(String downloaded) async {
    final app = appImagePath!;
    await File(downloaded).rename(app);
    await Process.start(app, const [], mode: ProcessStartMode.detached);
    exit(0);
  }
}

/// Runs the signed Inno Setup installer silently (it upgrades the existing install in place), then
/// starts the app again.
class WindowsInstallerUpdate implements UpdatePlatform {
  @override
  String get platform => 'windows';

  @override
  bool get canSelfInstall => true;

  Directory get _dir => Directory('${Directory.systemTemp.path}\\FamChatUpdate');

  @override
  Future<String> download(ReleaseAsset asset, http.Client client, void Function(double) onProgress) async {
    await _dir.create(recursive: true);
    final target = File('${_dir.path}\\FamChat-setup.exe');
    await downloadInBackground(asset, target, onProgress);
    return target.path;
  }

  @override
  Future<void> installAndRestart(String downloaded) async {
    final exe = Platform.resolvedExecutable;
    final script = File('${_dir.path}\\update.cmd');
    // ping, not timeout: timeout needs a console, and this runs detached without one.
    await script.writeAsString([
      '@echo off',
      'ping -n 3 127.0.0.1 >nul',
      '"$downloaded" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS',
      'start "" "$exe"',
      '',
    ].join('\r\n'));
    await Process.start('cmd.exe', ['/c', script.path], mode: ProcessStartMode.detached);
    exit(0);
  }
}

/// The sandboxed Mac app can't replace itself: it links to the new DMG instead.
class MacUpdate implements UpdatePlatform {
  @override
  String get platform => 'macos';

  @override
  bool get canSelfInstall => false;

  @override
  Future<String> download(ReleaseAsset asset, http.Client client, void Function(double) onProgress) =>
      throw UnsupportedError('download the DMG instead');

  @override
  Future<void> installAndRestart(String downloaded) => throw UnsupportedError('download the DMG instead');
}
