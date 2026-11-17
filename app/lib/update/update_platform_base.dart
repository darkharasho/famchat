import 'package:http/http.dart' as http;

import 'release_feed.dart';

/// How this install downloads and applies an update.
abstract class UpdatePlatform {
  /// The [assetSuffixes] key: linux or windows.
  String get platform;

  /// False where the app can't replace itself (Linux outside an AppImage):
  /// those get a download link instead.
  bool get canSelfInstall;

  /// Downloads [asset], checks it against its SHA-256 and returns the downloaded file's path.
  /// [onProgress] gets 0..1.
  Future<String> download(ReleaseAsset asset, http.Client client, void Function(double) onProgress);

  /// Puts the downloaded update in place, starts the new version and quits this one.
  Future<void> installAndRestart(String downloaded);
}

class UpdateException implements Exception {
  const UpdateException(this.message);
  final String message;

  @override
  String toString() => message;
}
