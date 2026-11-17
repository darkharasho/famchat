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
import '../chat/wire.dart';
import '../crypto/encoding.dart';
import '../crypto/media.dart';
import 'media_api.dart';
import 'media_db.dart';
import 'photo.dart';
import 'video.dart';
import '../voice/waveform.dart';

/// Where one blob lives and how to open it.
class MediaRef {
  const MediaRef({required this.id, required this.key, required this.sha256, required this.purpose});

  /// The server's media key (`/api/media/:id`).
  final String id;

  /// The 32-byte media key and the SHA-256 of the encrypted blob.
  final Uint8List key, sha256;
  final MediaPurpose purpose;

  /// What the local cache stores this blob's plaintext under: the same media key named with another
  /// hash (a forged message) never gets this entry.
  String get cacheKey => '$id|${b64url(sha256)}|${purpose.name}';

  @override
  bool operator ==(Object other) =>
      other is MediaRef && other.id == id && other.purpose == purpose && b64url(other.sha256) == b64url(sha256) &&
      b64url(other.key) == b64url(key);

  @override
  int get hashCode => Object.hash(id, purpose, b64url(sha256));
}

extension PhotoRefs on PhotoBody {
  MediaRef get fullRef => MediaRef(id: mediaKey, key: key, sha256: sha256, purpose: MediaPurpose.file);
  MediaRef get thumbRef => MediaRef(id: thumbKey, key: key, sha256: thumbSha256, purpose: MediaPurpose.thumb);
}

extension VideoRefs on VideoBody {
  MediaRef get ref => MediaRef(id: mediaKey, key: key, sha256: sha256, purpose: MediaPurpose.file);

  /// The poster frame, if the sender could make one.
  MediaRef? get thumbRef =>
      thumbKey == null ? null : MediaRef(id: thumbKey!, key: key, sha256: thumbSha256!, purpose: MediaPurpose.thumb);
}

extension PreviewImageRef on PreviewImage {
  MediaRef get ref => MediaRef(id: mediaKey, key: key, sha256: sha256, purpose: MediaPurpose.thumb);
}

extension VoiceRef on VoiceBody {
  MediaRef get ref => MediaRef(id: mediaKey, key: key, sha256: sha256, purpose: MediaPurpose.file);
}

/// A staged blob: its media key and the SHA-256 of its ciphertext.
typedef StagedBlob = ({String id, Uint8List sha256});

/// Runs CPU-heavy work (encryption, hashing) elsewhere: a background isolate off the web.
typedef Offload = Future<R> Function<R>(FutureOr<R> Function() task);

Future<R> _inline<R>(FutureOr<R> Function() task) async => task();

Future<(Uint8List, Uint8List)> _encryptAndHash(Uint8List key, Uint8List plaintext, MediaPurpose purpose) async {
  final blob = await encryptMedia(key: key, plaintext: plaintext, purpose: purpose);
  return (blob, await sha256Of(blob));
}

/// The plaintext, or null when [blob] doesn't hash to [sha256] (decryption failures throw).
Future<Uint8List?> _verifyAndDecrypt(Uint8List key, Uint8List blob, Uint8List sha256, MediaPurpose purpose) async {
  if (!await sha256Matches(blob, sha256)) return null;
  return decryptMedia(key: key, blob: blob, purpose: purpose);
}

class MediaService {
  MediaService({
    required this.db,
    required this.api,
    required this.sync,
    required this.processor,
    this.cacheBytes = 256 * 1024 * 1024,
    this.retryDelays = const [Duration(seconds: 5), Duration(seconds: 15), Duration(minutes: 1)],
    Offload? offload,
    DateTime Function()? now,
  })  : _offload = offload ?? _inline,
        _now = now ?? DateTime.now;

  final MediaDb db;
  final MediaApi api;
  final ChatSync sync;
  final PhotoProcessor processor;

  /// Upper bound of decrypted media kept locally.
  final int cacheBytes;

  /// Waits before re-trying an upload that failed for a transient reason (the last repeats).
  final List<Duration> retryDelays;

  final Offload _offload;
  final DateTime Function() _now;

  /// Upload rows of a message that isn't in the chat database are left alone this long: a send may
  /// be between staging its blobs and queueing its message.
  static const orphanGrace = Duration(minutes: 10);

  final _uploading = <String>{};
  final _failures = <String, int>{};
  final _retryTimers = <String, Timer>{};
  final _progress = <String, double>{};
  final _progressCtl = StreamController<(String, double?)>.broadcast();
  final _loads = <String, Future<Uint8List?>>{};
  StreamSubscription<Map<String, Object?>>? _events;
  bool _stopped = false;

  Future<void> start() async {
    await db.bindDevice(sync.me.deviceId);
    sync.beforeSend = _beforeSend;
    _events = sync.hub.events.listen(_onEvent);
    // Upload rows of sent messages, and of messages long gone (chat left, data wiped), aren't needed.
    final cutoff = _now().subtract(orphanGrace).millisecondsSinceEpoch;
    for (final id in await db.uploadMessageIds()) {
      final row = await sync.db.messageById(id);
      if (row?.state == 'sent' || (row == null && (await db.uploadsFor(id)).every((u) => u.createdAt < cutoff))) {
        await db.deleteUploadsFor(id);
      }
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

  /// Encrypts and queues a processed video (its file, and its poster frame when there is one);
  /// returns the message id. Throws [VideoTooLargeException] past [maxVideoBytes] and
  /// [ArgumentError] for an empty file or a length outside (0, [VideoBody.maxDurationMs]].
  Future<String> sendVideo(String chatId, ProcessedVideo v) async {
    if (v.bytes.length > maxVideoBytes) throw VideoTooLargeException(v.bytes.length);
    if (v.bytes.isEmpty || v.width < 1 || v.height < 1) throw ArgumentError.value(v.bytes.length, 'bytes', 'empty video');
    final ms = v.duration.inMilliseconds;
    if (ms < 1 || ms > VideoBody.maxDurationMs) throw ArgumentError.value(v.duration, 'duration', 'bad length');
    return _stageVideo(chatId, file: v.bytes, thumb: v.thumb, width: v.width, height: v.height, durationMs: ms);
  }

  Future<String> _stageVideo(
    String chatId, {
    required Uint8List file,
    required Uint8List? thumb,
    required int width,
    required int height,
    required int durationMs,
    bool forwarded = false,
  }) async {
    final key = newMediaKey();
    final messageId = newUlid();
    final t = thumb == null || thumb.length + mediaOverhead > mediaKindLimits['thumb']!
        ? null
        : await stage(
            chatId: chatId, messageId: messageId, kind: 'thumb', purpose: MediaPurpose.thumb, key: key, plaintext: thumb, position: 0);
    final f = await stage(
        chatId: chatId, messageId: messageId, kind: 'video', purpose: MediaPurpose.file, key: key, plaintext: file, position: 1);
    return sync.enqueueMessage(
      chatId,
      VideoBody(
        mediaKey: f.id,
        key: key,
        sha256: f.sha256,
        thumbKey: t?.id,
        thumbSha256: t?.sha256,
        width: width,
        height: height,
        durationMs: durationMs,
        bytes: file.length,
      ),
      id: messageId,
      forwarded: forwarded,
    );
  }

  /// Queues a text with a preview of its link: the preview's image (when it decodes) becomes an
  /// encrypted thumbnail, uploaded before the message is sent. Throws [ArgumentError] for empty or
  /// too-long text.
  Future<String> sendTextWithPreview(
    String chatId,
    String text,
    FetchedPreview fetched, {
    String? replyTo,
    List<String> mentions = const [],
  }) async {
    final t = validMessageText(text);
    if (t == null) throw ArgumentError.value(text, 'text', 'empty or longer than $maxTextLength characters');
    final messageId = newUlid();
    PreviewImage? image;
    if (fetched.image case final bytes?) {
      try {
        final p = await processor.process(bytes);
        final (w, h) = fitWithin(p.width, p.height, maxThumbSide);
        final key = newMediaKey();
        final blob = await stage(
            chatId: chatId, messageId: messageId, kind: 'thumb', purpose: MediaPurpose.thumb, key: key, plaintext: p.thumb, position: 0);
        image = PreviewImage(mediaKey: blob.id, key: key, sha256: blob.sha256, width: w, height: h);
      } on UnsupportedImageException {
        image = null;
      } on ArgumentError {
        image = null; // too large for a thumbnail
      }
    }
    return sync.enqueueMessage(
      chatId,
      TextBody(
        t,
        replyTo: replyTo,
        mentions: mentions.take(maxMentions).toList(),
        preview: LinkPreview(
          url: fetched.url,
          title: fetched.title,
          description: fetched.description,
          siteName: fetched.siteName,
          image: image,
        ),
      ),
      id: messageId,
    );
  }

  /// Encrypts and queues a recorded voice clip (one `voice` blob); returns the message id. Throws
  /// [ArgumentError] for an empty clip, a length outside (0, [maxVoiceDuration]], or too many bytes.
  Future<String> sendVoice(String chatId, RecordedVoice v) async {
    if (v.bytes.isEmpty) throw ArgumentError.value(v.bytes.length, 'bytes', 'empty recording');
    if (v.duration <= Duration.zero || v.duration > maxVoiceDuration) {
      throw ArgumentError.value(v.duration, 'duration', 'voice messages are at most ${maxVoiceDuration.inMinutes} minutes');
    }
    final key = newMediaKey();
    final messageId = newUlid();
    final clip = await stage(
        chatId: chatId, messageId: messageId, kind: 'voice', purpose: MediaPurpose.file, key: key, plaintext: v.bytes, position: 0);
    return sync.enqueueMessage(
      chatId,
      VoiceBody(
        mediaKey: clip.id,
        key: key,
        sha256: clip.sha256,
        durationMs: v.duration.inMilliseconds,
        waveform: v.waveform.take(VoiceBody.maxWaveform).toList(),
        bytes: v.bytes.length,
      ),
      id: messageId,
    );
  }

  /// Copies a photo, voice or video message into [chatId] (forwarding): its blobs are loaded, then encrypted
  /// under a new key and uploaded again, since media access follows the chat it was sent to. Returns
  /// the new message id, or null when the media expired. Throws [ArgumentError] for other kinds.
  Future<String?> forwardMedia(String chatId, Plaintext body) async {
    final key = newMediaKey();
    final messageId = newUlid();
    switch (body) {
      case PhotoBody():
        final full = await load(body.fullRef);
        final thumb = await load(body.thumbRef);
        if (full == null || thumb == null) return null;
        final t = await stage(
            chatId: chatId, messageId: messageId, kind: 'thumb', purpose: MediaPurpose.thumb, key: key, plaintext: thumb, position: 0);
        final f = await stage(
            chatId: chatId, messageId: messageId, kind: 'photo', purpose: MediaPurpose.file, key: key, plaintext: full, position: 1);
        return sync.enqueueMessage(
          chatId,
          PhotoBody(
            mediaKey: f.id,
            thumbKey: t.id,
            key: key,
            sha256: f.sha256,
            thumbSha256: t.sha256,
            width: body.width,
            height: body.height,
            bytes: full.length,
            mime: body.mime,
          ),
          id: messageId,
          forwarded: true,
        );
      case VoiceBody():
        final clip = await load(body.ref);
        if (clip == null) return null;
        final c = await stage(
            chatId: chatId, messageId: messageId, kind: 'voice', purpose: MediaPurpose.file, key: key, plaintext: clip, position: 0);
        return sync.enqueueMessage(
          chatId,
          VoiceBody(
            mediaKey: c.id,
            key: key,
            sha256: c.sha256,
            durationMs: body.durationMs,
            waveform: body.waveform,
            bytes: clip.length,
          ),
          id: messageId,
          forwarded: true,
        );
      case VideoBody():
        final file = await load(body.ref);
        if (file == null) return null;
        final thumbRef = body.thumbRef;
        final thumb = thumbRef == null ? null : await load(thumbRef);
        return _stageVideo(chatId,
            file: file, thumb: thumb, width: body.width, height: body.height, durationMs: body.durationMs, forwarded: true);
      default:
        throw ArgumentError.value(body.kind, 'body', 'not a media message');
    }
  }

  /// Encrypts [plaintext] under [key], caches the plaintext (so the sender sees it at once) and keeps
  /// the blob for upload before message [messageId] is sent. For new kinds (voice): stage each blob,
  /// then `sync.enqueueMessage(chatId, body, id: messageId)` (and add the kind to
  /// `ChatSync.mediaKinds`).
  Future<StagedBlob> stage({
    required String chatId,
    required String messageId,
    required String kind,
    required MediaPurpose purpose,
    required Uint8List key,
    required Uint8List plaintext,
    required int position,
  }) async {
    final limit = mediaKindLimits[kind];
    if (limit == null || plaintext.length + mediaOverhead > limit) {
      throw ArgumentError.value(plaintext.length, 'plaintext', 'too large for $kind');
    }
    final (blob, sha) = await _offload(() => _encryptAndHash(key, plaintext, purpose));
    final id = newUlid();
    await db.cachePut(MediaRef(id: id, key: key, sha256: sha, purpose: purpose).cacheKey, plaintext, maxBytes: cacheBytes);
    await db.putUpload(key: id, messageId: messageId, chatId: chatId, kind: kind, cipher: blob, position: position);
    return (id: id, sha256: sha);
  }

  /// Upload progress (0–1) of [messageId]'s blobs; null once it isn't uploading (failed or stopped).
  Stream<double?> progress(String messageId) =>
      _progressCtl.stream.where((e) => e.$1 == messageId).map((e) => e.$2);

  double? progressNow(String messageId) => _progress[messageId];

  void _setProgress(String messageId, double? v) {
    if (v == null) {
      _progress.remove(messageId);
    } else {
      _progress[messageId] = v;
    }
    _progressCtl.add((messageId, v));
  }

  /// The outbox gate. A media message is sent only with positive evidence that its blobs are on the
  /// server; one whose blobs are gone (local media storage lost) can never be sent and fails.
  Future<bool> _beforeSend(MessageRow row) async {
    final rows = await db.uploadsFor(row.id);
    if (rows.isEmpty) {
      if (!ChatSync.mediaKinds.contains(row.kind)) return true;
      await sync.db.setMessageState(row.id, 'failed');
      return false;
    }
    if (rows.every((r) => r.done)) return true;
    if (!_stopped && !_retryTimers.containsKey(row.id) && _uploading.add(row.id)) unawaited(_upload(row.id));
    return false;
  }

  Future<void> _upload(String messageId) async {
    try {
      final rows = await db.uploadsFor(messageId);
      final todo = rows.where((r) => !r.done).toList();
      final total = todo.fold<int>(0, (a, r) => a + r.cipher.length);
      var done = 0;
      _setProgress(messageId, 0);
      for (final r in todo) {
        await api.upload(
          key: r.key,
          chatId: r.chatId,
          kind: r.kind,
          messageId: messageId,
          bytes: r.cipher,
          onProgress: (sent, _) {
            if (!_stopped) _setProgress(messageId, total == 0 ? 1 : (done + sent) / total);
          },
        );
        done += r.cipher.length;
        await db.markUploaded(r.key);
      }
      _uploading.remove(messageId);
      _failures.remove(messageId);
      if (_stopped) return;
      _setProgress(messageId, 1);
      sync.flushSoon();
    } on ApiException catch (e) {
      _uploading.remove(messageId);
      if (_stopped) return; // a newer service owns this message now
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
      if (!_stopped) _retryLater(messageId);
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
  Future<Uint8List?> load(MediaRef ref) => _loads[ref.cacheKey] ??= _load(ref).whenComplete(() {
        // A block body: returning the removed future would make this future wait on itself.
        _loads.remove(ref.cacheKey);
      });

  Future<Uint8List?> _load(MediaRef ref) async {
    if (await db.isExpired(ref.id)) return null;
    final cached = await db.cacheGet(ref.cacheKey);
    if (cached != null) return cached;
    final Uint8List blob;
    try {
      blob = await api.download(ref.id);
    } on ApiException catch (e) {
      if (e.status != 410) rethrow;
      await db.markExpired([ref.id]);
      return null;
    }
    final plain = await _offload(() => _verifyAndDecrypt(ref.key, blob, ref.sha256, ref.purpose));
    if (plain == null) throw const CryptoFailure('media hash mismatch');
    await db.cachePut(ref.cacheKey, plain, maxBytes: cacheBytes);
    return plain;
  }

  void _onEvent(Map<String, Object?> e) {
    if (e['type'] != 'media_expired') return;
    final keys = [...?(e['keys'] as List?)?.whereType<String>()];
    if (keys.isEmpty) return;
    unawaited(() async {
      await db.markExpired(keys);
      await db.cacheDropPrefixed(keys);
    }());
  }
}
