// Which build this is, for the version line in settings. Release builds get these from
// --dart-define (release.yml for the apps, scripts/deploy.sh for the web app).
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'update_controller.dart' show appReleaseVersion;

class BuildInfo {
  const BuildInfo({this.version = '', this.build = '', this.commit = '', this.built = '', this.web = kIsWeb});

  /// The release version (1.2.3); empty on the web and in local builds.
  final String version;

  /// The store build number; empty where there is none.
  final String build;

  /// The short commit the web app was deployed from.
  final String commit;

  /// The web app's deploy date, as yyyy-mm-dd.
  final String built;

  final bool web;
}

final buildInfoProvider = Provider<BuildInfo>((ref) => const BuildInfo(
      version: appReleaseVersion,
      build: String.fromEnvironment('FAMCHAT_BUILD'),
      commit: String.fromEnvironment('FAMCHAT_COMMIT'),
      built: String.fromEnvironment('FAMCHAT_BUILT'),
    ));

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "FamChat 1.2.3 (build 42)" for the apps; "FamChat web · deployed Nov 17, 2026 · dcff4ff" for
/// the web app, which redeploys with every change rather than with releases.
String versionLine(BuildInfo info) {
  if (info.web) {
    final date = DateTime.tryParse(info.built);
    final parts = [
      if (date != null) 'deployed ${_months[date.month - 1]} ${date.day}, ${date.year}',
      if (info.commit.isNotEmpty) info.commit,
    ];
    return parts.isEmpty ? 'FamChat web (local build)' : 'FamChat web · ${parts.join(' · ')}';
  }
  if (info.version.isEmpty) return 'FamChat (local build)';
  return info.build.isEmpty ? 'FamChat ${info.version}' : 'FamChat ${info.version} (build ${info.build})';
}
