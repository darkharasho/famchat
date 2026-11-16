// The media half of the REST API (docs/protocol.md "Media"): encrypted blobs in, encrypted blobs out.
import 'dart:typed_data';

/// Kinds the server knows, with their byte caps (ciphertext).
const mediaKindLimits = {'photo': 15 * 1024 * 1024, 'thumb': 1024 * 1024, 'voice': 8 * 1024 * 1024};

class MediaUsage {
  const MediaUsage({
    required this.usedBytes,
    required this.capBytes,
    required this.evictToBytes,
    required this.files,
    required this.expiredFiles,
  });

  final int usedBytes, capBytes, evictToBytes, files, expiredFiles;

  factory MediaUsage.fromJson(Map<String, Object?> j) {
    int f(String k) => j[k] is int ? j[k] as int : throw FormatException('bad $k');
    return MediaUsage(
      usedBytes: f('usedBytes'),
      capBytes: f('capBytes'),
      evictToBytes: f('evictToBytes'),
      files: f('files'),
      expiredFiles: f('expiredFiles'),
    );
  }
}

/// Errors are `ApiException` (`too_large` 413, `not_found` 404, `conflict` 409, `media_expired` 410),
/// `NetworkException` or `SignedOutException` from `lib/api/models.dart`.
abstract interface class MediaApi {
  /// Stores [bytes] (already encrypted) under [key], a ULID this device made.
  Future<void> upload({
    required String key,
    required String chatId,
    required String kind,
    String? messageId,
    required Uint8List bytes,
    void Function(int sent, int total)? onProgress,
  });

  Future<Uint8List> download(String key);

  /// Admin only.
  Future<MediaUsage> usage();
}
