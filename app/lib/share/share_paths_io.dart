import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'share.dart' show sharedPathAllowed;

/// Android: another app can share a `file://` path into FamChat's own storage (its chat database,
/// its decrypted files). Each shared path is resolved (links followed) and refused when it's in
/// FamChat's data directory, except files directly in the cache directory, where the share plugin
/// copies what's shared as content:// streams. Elsewhere every path passes.
Future<bool Function(String path)> sharedPathFilter() async {
  if (!Platform.isAndroid) return (_) => true;
  // /data/user/<n>/<package>/files and /data/user/<n>/<package>/cache.
  final data = (await getApplicationSupportDirectory()).parent.path;
  final cache = (await getTemporaryDirectory()).path;
  final package = data.substring(data.lastIndexOf('/') + 1);
  final private = {data, _resolved(data), '/data/data/$package', '/data/user/0/$package', ?_resolved('/data/data/$package')}
      .whereType<String>()
      .toList();
  final caches = {cache, ?_resolved(cache)}.toList();
  return (path) {
    final real = _resolved(path);
    return real != null && sharedPathAllowed(real, privateDirs: private, cacheDirs: caches);
  };
}

String? _resolved(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } catch (_) {
    return null;
  }
}
