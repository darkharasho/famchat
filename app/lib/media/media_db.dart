// Local media state, kept apart from the chat database: decrypted media (a bounded LRU cache),
// encrypted blobs waiting to upload, and media keys known to be expired. Belongs to one signed-in
// device, like the chat database.
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'media_db.g.dart';

/// Decrypted media by media key.
@DataClassName('CachedMediaRow')
class CachedMedia extends Table {
  TextColumn get key => text()();
  BlobColumn get bytes => blob()();
  IntColumn get size => integer()();
  IntColumn get lastUsed => integer()();

  @override
  Set<Column> get primaryKey => {key};
}

/// Encrypted blobs of this device's unsent media messages. Once uploaded a row keeps `done = true`
/// (and drops its bytes) until the message is sent: the outbox needs positive evidence of upload.
@DataClassName('PendingUploadRow')
class PendingUploads extends Table {
  TextColumn get key => text()();
  TextColumn get messageId => text()();
  TextColumn get chatId => text()();

  /// photo | thumb | voice (the server's kinds).
  TextColumn get kind => text()();
  BlobColumn get cipher => blob()();

  /// Upload order within a message (thumbnail first).
  IntColumn get position => integer()();

  BoolColumn get done => boolean().withDefault(const Constant(false))();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {key};
}

@DataClassName('ExpiredMediaRow')
class ExpiredMedia extends Table {
  TextColumn get key => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DataClassName('MediaMetaRow')
class MediaMeta extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [CachedMedia, PendingUploads, ExpiredMedia, MediaMeta])
class MediaDb extends _$MediaDb {
  MediaDb(super.e, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  @override
  int get schemaVersion => 1;

  /// Wipes everything if the database belonged to another device (see `ChatDb.bindDevice`).
  Future<void> bindDevice(String deviceId) => transaction(() async {
        final row = await (select(mediaMeta)..where((m) => m.key.equals('deviceId'))).getSingleOrNull();
        if (row?.value == deviceId) return;
        for (final t in allTables) {
          await delete(t).go();
        }
        await into(mediaMeta).insert(MediaMetaRow(key: 'deviceId', value: deviceId));
      });

  Future<void> wipe() => transaction(() async {
        for (final t in allTables) {
          await delete(t).go();
        }
      });

  // --- cache ---

  /// The cached bytes, marking them recently used.
  Future<Uint8List?> cacheGet(String key) async {
    final row = await (select(cachedMedia)..where((c) => c.key.equals(key))).getSingleOrNull();
    if (row == null) return null;
    await (update(cachedMedia)..where((c) => c.key.equals(key)))
        .write(CachedMediaCompanion(lastUsed: Value(_now().microsecondsSinceEpoch)));
    return row.bytes;
  }

  /// Stores [bytes] and evicts least recently used entries until the total is at most [maxBytes]
  /// (an entry larger than [maxBytes] on its own isn't kept).
  /// Keeps [bytes] under [key], dropping the least recently used entries past [maxBytes]. Anything
  /// over half of [maxBytes] (a long video) isn't kept: it would push out everything else.
  Future<void> cachePut(String key, Uint8List bytes, {required int maxBytes}) => transaction(() async {
        if (bytes.length > maxBytes ~/ 2) return;
        await into(cachedMedia).insertOnConflictUpdate(
            CachedMediaRow(key: key, bytes: bytes, size: bytes.length, lastUsed: _now().microsecondsSinceEpoch));
        var total = await cacheBytes();
        if (total <= maxBytes) return;
        final rows = await (selectOnly(cachedMedia)
              ..addColumns([cachedMedia.key, cachedMedia.size])
              ..orderBy([OrderingTerm(expression: cachedMedia.lastUsed)]))
            .get();
        for (final r in rows) {
          if (total <= maxBytes) break;
          await (delete(cachedMedia)..where((c) => c.key.equals(r.read(cachedMedia.key)!))).go();
          total -= r.read(cachedMedia.size)!;
        }
      });

  Future<int> cacheBytes() async {
    final q = selectOnly(cachedMedia)..addColumns([cachedMedia.size.sum()]);
    return (await q.getSingle()).read(cachedMedia.size.sum()) ?? 0;
  }

  /// Drops every cached entry whose key starts with one of [prefixes] (cache keys are
  /// `"<mediaKey>|<sha256>|<purpose>"`).
  Future<void> cacheDropPrefixed(Iterable<String> prefixes) => transaction(() async {
        for (final p in prefixes) {
          final prefix = '$p|';
          await (delete(cachedMedia)..where((c) => c.key.substr(1, prefix.length).equals(prefix))).go();
        }
      });

  // --- uploads ---

  Future<void> putUpload({
    required String key,
    required String messageId,
    required String chatId,
    required String kind,
    required Uint8List cipher,
    required int position,
    int? createdAt,
  }) =>
      into(pendingUploads).insertOnConflictUpdate(PendingUploadsCompanion.insert(
        key: key,
        messageId: messageId,
        chatId: chatId,
        kind: kind,
        cipher: cipher,
        position: position,
        createdAt: createdAt ?? _now().millisecondsSinceEpoch,
      ));

  /// Every blob of [messageId] (uploaded or not), in upload order.
  Future<List<PendingUploadRow>> uploadsFor(String messageId) => (select(pendingUploads)
        ..where((u) => u.messageId.equals(messageId))
        ..orderBy([(u) => OrderingTerm(expression: u.position)]))
      .get();

  /// Whether [messageId] has blobs not uploaded yet.
  Future<bool> hasUploads(String messageId) async =>
      (await (selectOnly(pendingUploads)
                ..addColumns([pendingUploads.key])
                ..where(pendingUploads.messageId.equals(messageId) & pendingUploads.done.not())
                ..limit(1))
              .getSingleOrNull()) !=
      null;

  /// Message ids with upload rows (done or not).
  Future<Set<String>> uploadMessageIds() async {
    final q = selectOnly(pendingUploads, distinct: true)..addColumns([pendingUploads.messageId]);
    return {for (final r in await q.get()) r.read(pendingUploads.messageId)!};
  }

  /// The blob reached the server: keep the row as evidence, drop the bytes.
  Future<void> markUploaded(String key) => (update(pendingUploads)..where((u) => u.key.equals(key)))
      .write(PendingUploadsCompanion(done: const Value(true), cipher: Value(Uint8List(0))));

  Future<void> deleteUploadsFor(String messageId) =>
      (delete(pendingUploads)..where((u) => u.messageId.equals(messageId))).go();

  // --- expiry ---

  Future<void> markExpired(Iterable<String> keys) => batch((b) => b.insertAllOnConflictUpdate(
        expiredMedia,
        [for (final k in keys) ExpiredMediaRow(key: k)],
      ));

  Future<bool> isExpired(String key) async =>
      await (select(expiredMedia)..where((e) => e.key.equals(key))).getSingleOrNull() != null;

  Stream<Set<String>> watchExpired() => select(expiredMedia).watch().map((rows) => {for (final r in rows) r.key});
}

/// The app's media database (`famchat_media`; IndexedDB/OPFS via wasm on the web).
MediaDb openMediaDb() => MediaDb(
      driftDatabase(
        name: 'famchat_media',
        web: DriftWebOptions(
          sqlite3Wasm: Uri.parse('sqlite3.wasm'),
          driftWorker: Uri.parse('drift_worker.js'),
        ),
      ),
    );
