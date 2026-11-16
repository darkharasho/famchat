// The media pipeline: encrypt and stage blobs, upload them before their message leaves the outbox,
// download, verify and decrypt on demand with a bounded local cache, and track expired media.
// Generic over kinds: a photo stages two blobs (thumb, file); plan 8's voice stages one.
import 'dart:async';
import 'dart:typed_data';

import '../api/models.dart';
import '../chat/chat_sync.dart';
import '../chat/db/chat_db.dart';
import '../chat/plaintext.dart';
import '../chat/ulid.dart';
import '../crypto/encoding.dart';
import '../crypto/media.dart';
import 'media_api.dart';
import 'media_db.dart';
import 'photo.dart';

/// Where one blob lives and how to open it.
class MediaRef {
  const MediaRef({required this.id, required this.key, required this.sha256, required this.purpose});

  /// The server's media key (`/api/media/:id`).
  final String id;

  /// The 32-byte media key and the SHA-256 of the encrypted blob.
  final Uint8List key, sha256;
  final MediaPurpose purpose;

  @override
  bool operator ==(Object other) => other is MediaRef && other.id == id && other.purpose == purpose;

  @override
  int get hashCode => Object.hash(id, purpose);
}

extension PhotoRefs on PhotoBody {
  MediaRef get fullRef => MediaRef(id: mediaKey, key: key, sha256: sha256, purpose: MediaPurpose.file);
  MediaRef get thumbRef => MediaRef(id: thumbKey, key: key, sha256: thumbSha256, purpose: MediaPurpose.thumb);
}

/// A staged blob: its media key and the SHA-256 of its ciphertext.
typedef StagedBlob = ({String id, Uint8List sha256});

class MediaService {
  MediaService({
    required this.db,
    required this.api,
    required this.sync,
    required this.processor,
    this.cacheBytes = 256 * 1024 * 1024,
    this.retryDelays = const [Duration(seconds: 5), Duration(seconds: 15), Duration(minutes: 1)],
  });

  final MediaDb db;
  final MediaApi api;
  final ChatSync sync;
  final PhotoProcessor processor;

  /// Upper bound of decrypted media kept locally.
  final int cacheBytes;

  /// Waits before re-trying an upload that failed for a transient reason (the last repeats).
  final List<Duration> retryDelays;

  final _uploading = <String>{};
  final _failures = <String, int>{};
  final _retryTimers = <String, Timer>{};
  final _progress = <String, double>{};
  final _progressCtl = StreamController<(String, double)>.broadcast();
  final _loads = <String, Future<Uint8List?>>{};
  StreamSubscription<Map<String, Object?>>? _events;
  bool _stopped = false;

  Future<void> start() async {
    await db.bindDevice(sync.me.deviceId);
    sync.beforeSend = _beforeSend;
    _events = sync.hub.events.listen(_onEvent);
    // Blobs of messages that are gone (chat left, data wiped) or already sent are never needed.
    for (final id in await db.uploadMessageIds()) {
      final row = await sync.db.messageById(id);
      if (row == null || row.state == 'sent') await db.deleteUploadsFor(id);
    }
    sync.flushSoon();
  }

  Future<void> stop() async {
    _stopped = true;
    for (final t in _retryTimers.values) {
      t.cancel();
    }
    _retryTimers.clear();
    await _events?.cancel();
    if (sync.beforeSend == _beforeSend) sync.beforeSend = null;
  }

  // ---------------------------------------------------------------------------------------------
  // Sending

  /// Compresses, encrypts and queues a photo; returns the message id. The message stays in the outbox
  /// until both blobs are uploaded. Throws [UnsupportedImageException] for an image that won't decode.
  Future<String> sendPhoto(String chatId, Uint8List original) async {
    final p = await processor.process(original);
    final key = newMediaKey();
    final messageId = newUlid();
    final thumb = await stage(
        chatId: chatId, messageId: messageId, kind: 'thumb', purpose: MediaPurpose.thumb, key: key, plaintext: p.thumb, position: 0);
    final full = await stage(
        chatId: chatId, messageId: messageId, kind: 'photo', purpose: MediaPurpose.file, key: key, plaintext: p.full, position: 1);
    return sync.enqueueMessage(
      chatId,
      PhotoBody(
        mediaKey: full.id,
        thumbKey: thumb.id,
        key: key,
        sha256: full.sha256,
        thumbSha256: thumb.sha256,
        width: p.width,
        height: p.height,
        bytes: p.full.length,
      ),
      id: messageId,
    );
  }

  /// Encrypts [plaintext] under [key], caches the plaintext (so the sender sees it at once) and keeps
  /// the blob for upload before message [messageId] is sent. For new kinds (voice): stage each blob,
  /// then `sync.enqueueMessage(chatId, body, id: messageId)`.
  Future<StagedBlob> stage({
    required String chatId,
    required String messageId,
    required String kind,
    required MediaPurpose purpose,
    required Uint8List key,
    required Uint8List plaintext,
    required int position,
  }) async {
    final blob = await encryptMedia(key: key, plaintext: plaintext, purpose: purpose);
    final limit = mediaKindLimits[kind];
    if (limit == null || blob.length > limit) throw ArgumentError.value(blob.length, 'plaintext', 'too large for $kind');
    final id = newUlid();
    await db.cachePut(id, plaintext, maxBytes: cacheBytes);
    await db.putUpload(PendingUploadRow(
        key: id, messageId: messageId, chatId: chatId, kind: kind, cipher: blob, position: position));
    return (id: id, sha256: await sha256Of(blob));
  }

  /// Upload progress (0–1) of [messageId]'s blobs; nothing while it isn't uploading.
  Stream<double> progress(String messageId) =>
      _progressCtl.stream.where((e) => e.$1 == messageId).map((e) => e.$2);

  double? progressNow(String messageId) => _progress[messageId];

  void _setProgress(String messageId, double? v) {
    if (v == null) {
      _progress.remove(messageId);
    } else {
      _progress[messageId] = v;
    }
    _progressCtl.add((messageId, v ?? 0));
  }

  /// The outbox gate: a message with blobs still to upload isn't sent; its upload starts instead.
  Future<bool> _beforeSend(MessageRow row) async {
    if (!await db.hasUploads(row.id)) return true;
    if (!_stopped && !_retryTimers.containsKey(row.id) && _uploading.add(row.id)) unawaited(_upload(row.id));
    return false;
  }

  Future<void> _upload(String messageId) async {
    try {
      final rows = await db.uploadsFor(messageId);
      final total = rows.fold<int>(0, (a, r) => a + r.cipher.length);
      var done = 0;
      _setProgress(messageId, 0);
      for (final r in rows) {
        await api.upload(
          key: r.key,
          chatId: r.chatId,
          kind: r.kind,
          messageId: messageId,
          bytes: r.cipher,
          onProgress: (sent, _) => _setProgress(messageId, total == 0 ? 1 : (done + sent) / total),
        );
        done += r.cipher.length;
        await db.deleteUpload(r.key);
      }
      _failures.remove(messageId);
      _setProgress(messageId, 1);
      _uploading.remove(messageId);
      if (!_stopped) sync.flushSoon();
    } on ApiException catch (e) {
      _uploading.remove(messageId);
      if (e.status >= 400 && e.status < 500 && e.status != 408 && e.status != 429) {
        // Too large, not a member any more, key conflict: retrying won't help until the user asks.
        _failures.remove(messageId);
        _setProgress(messageId, null);
        await sync.db.setMessageState(messageId, 'failed');
      } else {
        _retryLater(messageId);
      }
    } on SignedOutException {
      _uploading.remove(messageId);
    } catch (_) {
      _uploading.remove(messageId);
      _retryLater(messageId);
    }
  }

  void _retryLater(String messageId) {
    if (_stopped) return;
    final n = _failures[messageId] ?? 0;
    _failures[messageId] = n + 1;
    final delay = retryDelays[n < retryDelays.length ? n : retryDelays.length - 1];
    _retryTimers[messageId]?.cancel();
    _retryTimers[messageId] = Timer(delay, () {
      _retryTimers.remove(messageId);
      sync.flushSoon();
    });
  }

  // ---------------------------------------------------------------------------------------------
  // Receiving

  /// Media keys known to be expired (from events or a 410).
  Stream<Set<String>> get expired => db.watchExpired();

  /// The decrypted blob, from the cache or downloaded (once, however many callers ask), or null if it
  /// expired. Throws [CryptoFailure] when the blob doesn't match the message (hash or MAC), and
  /// `ApiException`/`NetworkException` when it can't be fetched.
  Future<Uint8List?> load(MediaRef ref) => _loads[ref.id] ??= _load(ref).whenComplete(() {
        // A block body: returning the removed future would make this future wait on itself.
        _loads.remove(ref.id);
      });

  Future<Uint8List?> _load(MediaRef ref) async {
    if (await db.isExpired(ref.id)) return null;
    final cached = await db.cacheGet(ref.id);
    if (cached != null) return cached;
    final Uint8List blob;
    try {
      blob = await api.download(ref.id);
    } on ApiException catch (e) {
      if (e.status != 410) rethrow;
      await db.markExpired([ref.id]);
      return null;
    }
    if (!await sha256Matches(blob, ref.sha256)) throw const CryptoFailure('media hash mismatch');
    final plain = await decryptMedia(key: ref.key, blob: blob, purpose: ref.purpose);
    await db.cachePut(ref.id, plain, maxBytes: cacheBytes);
    return plain;
  }

  void _onEvent(Map<String, Object?> e) {
    if (e['type'] != 'media_expired') return;
    final keys = [...?(e['keys'] as List?)?.whereType<String>()];
    if (keys.isEmpty) return;
    unawaited(() async {
      await db.markExpired(keys);
      await db.cacheDrop(keys);
    }());
  }
}
