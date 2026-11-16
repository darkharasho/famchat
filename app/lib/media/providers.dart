// Riverpod wiring for media: one MediaService beside each ChatSync, and per-blob loads for widgets.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../chat/providers.dart';
import '../session/session_controller.dart';
import 'http_media_api.dart';
import 'media_api.dart';
import 'media_db.dart';
import 'media_service.dart';
import 'photo.dart';
import 'photo_picker.dart';
import 'photo_processor.dart';

final mediaDbProvider = Provider<MediaDb>((ref) {
  final db = openMediaDb();
  ref.onDispose(db.close);
  return db;
});

/// Where encryption and hashing run (null: inline). Tests under fake time use inline.
final mediaOffloadProvider = Provider<Offload?>((ref) => kIsWeb ? null : _isolateOffload);

final mediaApiProvider = Provider<MediaApi>((ref) => HttpMediaApi(ref.watch(apiClientProvider)));

final photoProcessorProvider = Provider<PhotoProcessor>((ref) => PlatformPhotoProcessor());

final photoPickerProvider = Provider<PhotoPicker>((ref) => pickPhotos);

/// Decrypted media kept locally: smaller on the web, where storage may live in memory.
const mediaCacheBytes = kIsWeb ? 48 * 1024 * 1024 : 256 * 1024 * 1024;

/// The media pipeline for the running chat engine, or null when signed out. Signing out wipes it.
final mediaServiceProvider = Provider<MediaService?>((ref) {
  ref.listen(sessionProvider, (prev, next) {
    if (prev is SignedIn && next is SignedOut) unawaited(ref.read(mediaDbProvider).wipe());
  });
  final sync = ref.watch(chatSyncProvider);
  if (sync == null) return null;
  final media = MediaService(
    db: ref.watch(mediaDbProvider),
    api: ref.watch(mediaApiProvider),
    sync: sync,
    processor: ref.watch(photoProcessorProvider),
    cacheBytes: mediaCacheBytes,
    offload: ref.watch(mediaOffloadProvider),
  );
  unawaited(media.start());
  ref.onDispose(() => unawaited(media.stop()));
  return media;
});

/// Encryption and hashing in a background isolate (pure-Dart crypto there). `compute` runs inline on
/// the web, which has no isolates.
Future<R> _isolateOffload<R>(FutureOr<R> Function() task) => compute((_) => task(), null);

/// A blob's decrypted bytes; null when it expired. Errors (hash mismatch, network) surface as errors.
final mediaBytesProvider = FutureProvider.autoDispose.family<Uint8List?, MediaRef>(
  (ref, mediaRef) async {
    final media = ref.watch(mediaServiceProvider);
    if (media == null) throw StateError('signed out');
    return media.load(mediaRef);
  },
  retry: mediaRetry,
);

/// Network trouble retries a few times (1 s, 2 s, 4 s); a blob that fails verification never does.
Duration? mediaRetry(int retryCount, Object error) =>
    error is NetworkException && retryCount < 3 ? Duration(seconds: 1 << retryCount) : null;

/// Upload progress (0–1) of a message's media, or null when it isn't uploading.
final uploadProgressProvider = StreamProvider.autoDispose.family<double?, String>((ref, messageId) async* {
  final media = ref.watch(mediaServiceProvider);
  if (media == null) {
    yield null;
    return;
  }
  yield media.progressNow(messageId);
  yield* media.progress(messageId);
});

/// Media keys known to be expired.
final expiredMediaProvider = StreamProvider<Set<String>>((ref) {
  final media = ref.watch(mediaServiceProvider);
  if (media == null) return Stream.value(const {});
  return media.expired;
});

final mediaUsageProvider = FutureProvider.autoDispose<MediaUsage>((ref) => ref.watch(mediaApiProvider).usage());
