// Reads the newest FamChat release from GitHub and picks this platform's download.
import 'dart:convert';

/// Published (not draft, not prerelease) releases only: what desktop installs update to.
final latestReleaseUrl = Uri.parse('https://api.github.com/repos/darkharasho/famchat/releases/latest');

/// Where people can download FamChat by hand.
final releasesPageUrl = Uri.parse('https://github.com/darkharasho/famchat/releases/latest');

/// A release's download for one platform.
class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.url, required this.sha256, required this.size});

  final String name;
  final Uri url;

  /// Lowercase hex, or null when GitHub didn't publish a digest.
  final String? sha256;
  final int size;
}

class Release {
  const Release({required this.version, required this.pageUrl, this.asset});

  /// "1.2.3", from the tag "v1.2.3".
  final String version;
  final Uri pageUrl;

  /// This platform's file, or null if the release has none.
  final ReleaseAsset? asset;
}

/// The file name suffix of each desktop platform's download (see release.yml).
const assetSuffixes = {
  'linux': '-linux-x86_64.AppImage',
  'windows': '-windows-x64-setup.exe',
  'macos': '-macos.dmg',
};

/// Parses the GitHub "latest release" JSON. Returns null for anything that isn't a usable release.
Release? parseRelease(String body, {required String platform}) {
  final Object? json;
  try {
    json = jsonDecode(body);
  } on FormatException {
    return null;
  }
  if (json is! Map<String, dynamic>) return null;
  if (json['draft'] == true || json['prerelease'] == true) return null;
  final tag = json['tag_name'];
  if (tag is! String) return null;
  final version = tag.startsWith('v') ? tag.substring(1) : tag;
  if (parseVersion(version) == null) return null;
  final page = Uri.tryParse(json['html_url'] as String? ?? '') ?? releasesPageUrl;
  final suffix = assetSuffixes[platform];
  ReleaseAsset? asset;
  if (suffix != null) {
    for (final a in (json['assets'] as List? ?? const [])) {
      if (a is! Map<String, dynamic>) continue;
      final name = a['name'];
      final url = Uri.tryParse(a['browser_download_url'] as String? ?? '');
      if (name is! String || !name.endsWith(suffix) || url == null || url.scheme != 'https') continue;
      final digest = a['digest'];
      asset = ReleaseAsset(
        name: name,
        url: url,
        sha256: digest is String && digest.startsWith('sha256:') ? digest.substring(7).toLowerCase() : null,
        size: a['size'] is int ? a['size'] as int : 0,
      );
      break;
    }
  }
  return Release(version: version, pageUrl: page, asset: asset);
}

/// "1.2.3" -> [1, 2, 3]. Null if it isn't three dot-separated numbers (a prerelease suffix is not
/// accepted: only published releases update installs).
List<int>? parseVersion(String v) {
  final parts = v.split('.');
  if (parts.length != 3) return null;
  final nums = parts.map(int.tryParse).toList();
  if (nums.any((n) => n == null || n < 0)) return null;
  return nums.cast<int>();
}

/// Whether [candidate] is a later version than [current]. False if either doesn't parse.
bool isNewerVersion(String candidate, String current) {
  final a = parseVersion(candidate);
  final b = parseVersion(current);
  if (a == null || b == null) return false;
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}
