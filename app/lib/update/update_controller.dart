// Desktop self-update: checks GitHub for a newer published release, downloads it in the
// background where the app can install it, and offers "Restart to update".
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'release_feed.dart';
import 'update_platform.dart';

/// The version release.yml builds into desktop apps (--dart-define=FAMCHAT_VERSION=1.2.3).
/// Empty in local and test builds, which never update themselves.
const appReleaseVersion = String.fromEnvironment('FAMCHAT_VERSION');

class UpdateConfig {
  const UpdateConfig({
    required this.currentVersion,
    required this.platform,
    required this.newClient,
    required this.openUrl,
    this.firstCheckDelay = const Duration(seconds: 10),
    this.checkEvery = const Duration(hours: 6),
  });

  final String currentVersion;
  final UpdatePlatform platform;
  final http.Client Function() newClient;
  final Future<bool> Function(Uri) openUrl;
  final Duration firstCheckDelay;
  final Duration checkEvery;
}

/// Null where updates don't apply: the web, phones (the stores update those), and builds without a
/// release version.
final updateConfigProvider = Provider<UpdateConfig?>((ref) {
  if (kIsWeb || appReleaseVersion.isEmpty) return null;
  final platform = createUpdatePlatform();
  if (platform == null) return null;
  return UpdateConfig(
    currentVersion: appReleaseVersion,
    platform: platform,
    newClient: http.Client.new,
    openUrl: (u) => launchUrl(u, mode: LaunchMode.externalApplication),
  );
});

sealed class UpdateState {
  const UpdateState();
}

/// Nothing to offer. [checked]: a check finished and this is the newest version.
class UpdateIdle extends UpdateState {
  const UpdateIdle({this.checked = false, this.error});
  final bool checked;

  /// Why the last check failed, if it did.
  final String? error;
}

/// A newer version this install can't apply itself: offer its download.
class UpdateAvailable extends UpdateState {
  const UpdateAvailable(this.release, {this.error});
  final Release release;

  /// Set when a background download failed, so this is the fallback.
  final String? error;
}

class UpdateDownloading extends UpdateState {
  const UpdateDownloading(this.release, this.progress);
  final Release release;
  final double progress;
}

/// Downloaded and checked; applied on restart.
class UpdateReady extends UpdateState {
  const UpdateReady(this.release, this.file);
  final Release release;
  final String file;
}

class UpdateController extends Notifier<UpdateState> {
  Timer? _timer;
  bool _checking = false;

  /// The version whose banner was dismissed; a later one shows again.
  String? _dismissed;

  @override
  UpdateState build() {
    final config = ref.watch(updateConfigProvider);
    if (config != null) {
      _timer = Timer(config.firstCheckDelay, () {
        unawaited(check());
        _timer = Timer.periodic(config.checkEvery, (_) => unawaited(check()));
      });
      ref.onDispose(() => _timer?.cancel());
    }
    return const UpdateIdle();
  }

  bool get enabled => ref.read(updateConfigProvider) != null;

  /// Whether the home screen should show the update banner.
  bool get showBanner => switch (state) {
        UpdateReady(:final release) || UpdateAvailable(:final release) => release.version != _dismissed,
        _ => false,
      };

  Future<void> check() async {
    final config = ref.read(updateConfigProvider);
    if (config == null || _checking) return;
    // A download in flight or waiting for a restart is already the newest we know of.
    if (state is UpdateDownloading || state is UpdateReady) return;
    _checking = true;
    final client = config.newClient();
    try {
      final res = await client.get(latestReleaseUrl, headers: {'Accept': 'application/vnd.github+json'});
      if (res.statusCode != 200) {
        state = UpdateIdle(error: "Couldn't check for updates (HTTP ${res.statusCode}).");
        return;
      }
      final release = parseRelease(res.body, platform: config.platform.platform);
      if (release == null || !isNewerVersion(release.version, config.currentVersion)) {
        state = const UpdateIdle(checked: true);
        return;
      }
      final asset = release.asset;
      if (!config.platform.canSelfInstall || asset == null || asset.sha256 == null) {
        state = UpdateAvailable(release);
        return;
      }
      state = UpdateDownloading(release, 0);
      try {
        final file = await config.platform.download(asset, client, (p) {
          if (state is UpdateDownloading) state = UpdateDownloading(release, p);
        });
        state = UpdateReady(release, file);
      } catch (e) {
        state = UpdateAvailable(release, error: '$e');
      }
    } catch (e) {
      state = const UpdateIdle(error: "Couldn't check for updates. Check your connection.");
    } finally {
      client.close();
      _checking = false;
    }
  }

  Future<void> restart() async {
    final s = state;
    final config = ref.read(updateConfigProvider);
    if (s is! UpdateReady || config == null) return;
    try {
      await config.platform.installAndRestart(s.file);
    } catch (e) {
      state = UpdateAvailable(s.release, error: "Couldn't install the update: $e");
    }
  }

  /// Opens the release's download (or its page) in the browser.
  Future<void> openDownload() async {
    final config = ref.read(updateConfigProvider);
    final s = state;
    if (config == null || s is! UpdateAvailable) return;
    await config.openUrl(s.release.asset?.url ?? s.release.pageUrl);
  }

  void dismiss() {
    final s = state;
    if (s is UpdateReady) _dismissed = s.release.version;
    if (s is UpdateAvailable) _dismissed = s.release.version;
    ref.notifyListeners();
  }
}

final updateProvider = NotifierProvider<UpdateController, UpdateState>(UpdateController.new);
