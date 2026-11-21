// The chat engine: keeps the local database in step with the server and the hub.
// Sync on every connect (directory, chats, keys, history after the last seq, repair, outbox),
// live events, sending through an outbox with idempotent ids, reactions, read receipts,
// typing and presence. The UI only reads the database and the two ephemeral streams.
import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;

import '../api/models.dart';
import '../crypto/encoding.dart';
import '../crypto/envelope.dart';
import '../crypto/keys.dart';
import '../games/rules.dart';
import '../games/rng.dart' show newSeed;
import 'chat_keys.dart';
import 'db/chat_db.dart';
import 'directory.dart';
import 'hub_link.dart';
import 'message_changes.dart';
import 'plaintext.dart';
import 'ulid.dart';
import 'wire.dart';

/// New messages from others that a reconnect's catch-up fetched for one chat this device already
/// knew: what arrived while it was offline. Silent changes (reactions, edits, deletes) and messages
/// failing verification are left out; read state isn't checked here.
class CaughtUp {
  const CaughtUp(this.chatId, this.messages);
  final String chatId;

  /// Oldest first.
  final List<MessageRow> messages;
}

class ChatSync {
  ChatSync({
    required this.db,
    required this.api,
    required this.hub,
    required this.me,
    Directory? directory,
    ChatKeys? keys,
    this.typingTtl = const Duration(seconds: 5),
    this.typingThrottle = const Duration(seconds: 3),
    this.syncRetryDelays = const [Duration(seconds: 2), Duration(seconds: 10), Duration(seconds: 30), Duration(minutes: 1)],
    this.onFamiliesChanged,
    DateTime Function()? now,
  })  : directory = directory ?? Directory(db, api, me),
        _now = now ?? DateTime.now,
        _madeAt = (now ?? DateTime.now)().millisecondsSinceEpoch {
    this.keys = keys ?? ChatKeys(db: db, api: api, directory: this.directory, me: me);
  }

  final ChatDb db;
  final ChatApi api;
  final HubLink hub;
  final LocalIdentity me;
  final Directory directory;
  late final ChatKeys keys;
  final Duration typingTtl, typingThrottle;

  /// Called after a `family` event (and the directory refresh it brings), and after each connect's
  /// directory refresh (events missed while offline): the families list (`GET /families`) may be stale.
  final void Function()? onFamiliesChanged;

  /// After a failed connect-sync, while still connected: wait these (the last repeats) and retry.
  final List<Duration> syncRetryDelays;
  final DateTime Function() _now;

  static const pageSize = 100;

  /// Sends rejected with stale_epoch are retried this many times before they fail.
  static const maxStaleRetries = 3;

  final _subs = <StreamSubscription<Object?>>[];
  Future<void> _chain = Future.value();

  /// Sends run here, one at a time but beside [_chain], so a message doesn't wait for a slow sync.
  Future<void> _sendLane = Future.value();
  final _inflight = <String>{};

  /// Every row handed to the hub since this engine was made (unlike [_inflight], kept across
  /// reconnects): the server may have stored it even if no ack came back.
  final _handedToHub = <String>{};
  final int _madeAt;
  final _staleRetries = <String, int>{};
  final _lastTypingSent = <String, DateTime>{};

  /// Chats whose wraps were already fetched during the current queued job (one fetch per pass).
  final _keysFetched = <String>{};
  Timer? _syncRetry;
  int _syncFailures = 0;

  Set<String> _online = {};
  final _onlineCtl = StreamController<Set<String>>.broadcast();
  final _typing = <String, Map<String, Timer>>{};
  final _typingCtl = StreamController<Map<String, Set<String>>>.broadcast();

  /// Users with at least one connected device.
  Stream<Set<String>> get online => _onlineCtl.stream;
  Set<String> get onlineNow => Set.unmodifiable(_online);

  final _caughtUpCtl = StreamController<CaughtUp>.broadcast();

  /// After each (re)connect's sync: a chat's messages that came in while this device was offline.
  /// Desktop notifications use it, since the socket brought none of them as live events.
  Stream<CaughtUp> get caughtUp => _caughtUpCtl.stream;

  /// chat id → users typing there now.
  Stream<Map<String, Set<String>>> get typingUsers => _typingCtl.stream;
  Set<String> typingNow(String chatId) => {...?_typing[chatId]?.keys};

  /// Completes when the work queued so far (sync, events, sends) is done.
  Future<void> get idle async {
    for (;;) {
      final c = _chain, l = _sendLane;
      await c;
      await l;
      await Future<void>.delayed(Duration.zero);
      if (identical(c, _chain) && identical(l, _sendLane)) return;
    }
  }

  Future<void> start() async {
    db.myUserId = me.userId;
    await db.bindDevice(me.deviceId);
    unawaited(_enqueue(_reclassifyUnknown));
    _subs.add(hub.events.listen((e) {
      // A send's ack is recorded at once: the chain may be busy with a slow sync, and the
      // message should stop "sending" (and let the app sleep) as soon as the server has it.
      if (e['type'] == 'ack') unawaited(_onSendLane(() => _recordAck(e)).catchError((_) {}));
      _enqueue(() => _onEvent(e));
    }));
    _subs.add(hub.connection.listen((up) {
      if (up) {
        // Waiting messages go out now; the sync after them can take a while on a slow network.
        unawaited(_flushOutbox().catchError((_) {}));
        _enqueue(_connectSync);
      } else {
        _syncRetry?.cancel();
        _inflight.clear();
        _setOnline({});
        for (final t in _typing.values.expand((m) => m.values)) {
          t.cancel();
        }
        _typing.clear();
        _emitTyping();
      }
    }));
    await hub.start();
  }

  Future<void> stop() async {
    _syncRetry?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await hub.stop();
    for (final t in _typing.values.expand((m) => m.values)) {
      t.cancel();
    }
    _typing.clear();
  }

  /// Runs [f] after everything queued before it; a failure is logged, not propagated, so one bad
  /// event can't stall the queue.
  Future<void> _enqueue(Future<void> Function() f) {
    final next = _chain.then((_) {
      _keysFetched.clear();
      return f();
    }).catchError((Object e, StackTrace st) {
      // ignore: avoid_print
      if (e is! NetworkException && e is! SignedOutException) print('chat sync: $e\n$st');
    });
    _chain = next;
    return next;
  }

  // ---------------------------------------------------------------------------------------------
  // Sync

  /// [syncAll] for a new connection: the outbox is flushed even if the sync fails, and a failed
  /// sync is retried with backoff while the connection stays up.
  Future<void> _connectSync() async {
    _syncRetry?.cancel();
    try {
      await syncAll();
      _syncFailures = 0;
    } catch (_) {
      if (hub.connected) {
        final delay = syncRetryDelays[_syncFailures < syncRetryDelays.length ? _syncFailures : syncRetryDelays.length - 1];
        _syncFailures++;
        _syncRetry = Timer(delay, () => _enqueue(_connectSync));
      }
      try {
        await _flushOutbox();
      } catch (_) {
        // Sends need only the epoch key; anything else waits for the retry.
      }
      rethrow;
    }
  }

  /// What a (re)connect runs: directory, chats, keys, history, repair, outbox.
  Future<void> syncAll() async {
    await directory.refresh();
    // A `family` event may have been missed while disconnected.
    onFamiliesChanged?.call();
    final chats = await api.chats();
    final ids = {for (final c in chats) c.id};
    final locals = await db.allChats();
    // A chat new to this device downloads its history: that's not news to notify about.
    final known = {for (final c in locals) c.id};
    for (final local in locals) {
      if (!ids.contains(local.id)) await db.deleteChat(local.id);
    }
    for (final c in chats) {
      await db.upsertChat(c);
      // A read made while offline: the server still has an older position for me.
      final server = c.members.where((m) => m.userId == me.userId).firstOrNull?.lastReadSeq ?? 0;
      final local = (await db.chatById(c.id))!.myLastReadSeq;
      if (local > server) hub.send({'type': 'read', 'chatId': c.id, 'seq': local});
    }
    await keys.fetch();
    for (final c in chats) {
      try {
        await keys.ensureCurrentEpoch(c.id);
      } on ApiException {
        // Retried on the next sync or event.
      }
    }
    for (final c in chats) {
      final fresh = <MessageRow>[];
      await _catchUp(c.id, fresh: fresh);
      final news = [
        for (final r in fresh)
          if (r.senderUserId != me.userId && !changeKinds.contains(r.kind) && r.kind != 'invalid') r,
      ];
      if (known.contains(c.id) && news.isNotEmpty) _caughtUpCtl.add(CaughtUp(c.id, news));
    }
    await _retryUndecryptable();
    try {
      await keys.repairMissing();
    } on ApiException {
      // Someone else's device state changed meanwhile; next sync.
    }
    await _flushOutbox();
  }

  /// Fetches every message after the chat's synced seq; rows stored for the first time are added
  /// to [fresh]. Each page is stored in one transaction, so the chat (and any game in it) updates
  /// once per page instead of replaying every missed message on screen.
  Future<void> _catchUp(String chatId, {List<MessageRow>? fresh}) async {
    for (;;) {
      final chat = await db.chatById(chatId);
      if (chat == null) return;
      final page = await api.messages(chatId, after: chat.syncedSeq, limit: pageSize);
      // Decrypting may fetch keys or devices, so it happens before the transaction.
      final decrypted = <String, MessageRow>{
        for (final m in page)
          if (m.seq > chat.syncedSeq && await db.messageById(m.id) == null) m.id: await _decrypt(m),
      };
      await db.transaction(() async {
        for (final m in page) {
          final row = await _apply(m, catchingUp: true, decrypted: decrypted[m.id]);
          if (row != null) fresh?.add(row);
        }
      });
      if (page.length < pageSize) return;
    }
  }

  /// Stores [m]; returns its row when this is the first time this device stores it (else null).
  /// [decrypted] is [m] already decrypted, if it was.
  Future<MessageRow?> _apply(MessageDto m, {bool catchingUp = false, MessageRow? decrypted}) async {
    var chat = await db.chatById(m.chatId);
    if (chat == null) {
      await _refreshChat(m.chatId);
      chat = await db.chatById(m.chatId);
      if (chat == null) return null;
      if (!catchingUp) {
        await _catchUp(m.chatId);
        return null;
      }
    }
    if (m.seq <= chat.syncedSeq) return null;
    if (m.seq > chat.syncedSeq + 1 && !catchingUp) {
      await _catchUp(m.chatId);
      return null;
    }
    final existing = await db.messageById(m.id);
    final MessageRow row;
    if (existing != null) {
      if (existing.seq == null) await db.ackMessage(m.id, seq: m.seq, createdAt: m.createdAt);
      _inflight.remove(m.id);
      row = existing;
    } else {
      row = decrypted ?? await _decrypt(m);
      await db.insertMessageIfAbsent(row);
    }
    await db.setSyncedSeq(m.chatId, m.seq);
    // A change to another message isn't chat activity (0 leaves last_message_at as it is).
    await db.noteActivity(m.chatId, m.seq, changeKinds.contains(row.kind) ? 0 : m.createdAt);
    return existing == null ? row : null;
  }

  /// Verifies and decrypts; never throws for bad input. Kinds: text, reaction, photo, voice, unknown,
  /// undecryptable (key not held yet; envelope kept), invalid (fails verification for good).
  Future<MessageRow> _decrypt(MessageDto m) async {
    final base = MessageRow(
      id: m.id,
      chatId: m.chatId,
      seq: m.seq,
      senderUserId: m.senderUserId,
      senderDeviceId: m.senderDeviceId,
      kind: 'invalid',
      body: null,
      targetId: null,
      envelope: null,
      createdAt: m.createdAt,
      state: 'sent',
    );
    final Envelope env;
    try {
      env = Envelope.fromJson(m.envelope);
    } on CryptoFailure {
      return base;
    }
    final waiting = base.copyWith(kind: 'undecryptable', envelope: Value(jsonEncode(m.envelope)));
    final VerifiedDevice? device;
    try {
      device = await directory.device(m.senderDeviceId);
    } catch (_) {
      return waiting; // couldn't ask the directory; retried on the next sync
    }
    if (device == null || device.userId != m.senderUserId) return base;
    // A sender under a changed, unacknowledged identity key waits for the user's OK.
    if (!device.trusted) return waiting;
    var key = await keys.key(m.chatId, env.epoch);
    if (key == null && _keysFetched.add(m.chatId)) {
      try {
        await keys.fetch(chatId: m.chatId);
      } on ApiException {
        // Stays undecryptable; a later keys event retries.
      } on NetworkException {
        // Same.
      }
      key = await keys.key(m.chatId, env.epoch);
    }
    if (key == null) return waiting;
    final Plaintext p;
    final List<int> raw;
    try {
      raw = await decryptEnvelope(
        envelope: env,
        chatKey: key,
        chatId: m.chatId,
        messageId: m.id,
        senderDeviceId: m.senderDeviceId,
        senderSignPub: device.signPub,
      );
      p = Plaintext.decode(raw);
    } on CryptoFailure {
      return base;
    } on FormatException {
      return base;
    }
    return _classify(base, p, forwarded: _forwardedFlag(raw));
  }

  /// Whether a decoded plaintext says `"forwarded": true` (kept beside any kind).
  static bool _forwardedFlag(List<int> raw) {
    try {
      final j = jsonDecode(utf8.decode(raw));
      return j is Map && j['forwarded'] == true;
    } on FormatException {
      return false;
    }
  }

  /// [base] stored as plaintext [p]'s kind.
  static MessageRow _classify(MessageRow base, Plaintext p, {bool forwarded = false}) {
    final body = jsonEncode({...p.toJson(), if (forwarded && p is! UnknownBody) 'forwarded': true});
    return switch (p) {
      TextBody() => base.copyWith(kind: 'text', body: Value(body)),
      ReactionBody(:final target) => base.copyWith(kind: 'reaction', body: Value(body), targetId: Value(target)),
      EditBody(:final target) => base.copyWith(kind: 'edit', body: Value(body), targetId: Value(target)),
      DeleteBody(:final target) => base.copyWith(kind: 'delete', body: Value(body), targetId: Value(target)),
      PhotoBody() => base.copyWith(kind: 'photo', body: Value(body)),
      VoiceBody() => base.copyWith(kind: 'voice', body: Value(body)),
      GifBody() => base.copyWith(kind: 'gif', body: Value(body)),
      VideoBody() => base.copyWith(kind: 'video', body: Value(body)),
      GameBody() => base.copyWith(kind: 'game', body: Value(body)),
      MoveBody(:final target) => base.copyWith(kind: 'move', body: Value(body), targetId: Value(target)),
      UnknownBody() => base.copyWith(kind: 'unknown', body: Value(body)),
    };
  }

  /// Messages an older version stored as `unknown` (their whole body is kept): once this version
  /// knows the kind they show as it (or as invalid when their fields don't check out).
  Future<void> _reclassifyUnknown() async {
    for (final r in await db.unknownKind()) {
      final body = r.body;
      if (body == null) continue;
      final Plaintext p;
      try {
        p = Plaintext.decode(utf8.encode(body));
      } on FormatException {
        await db.replaceMessage(r.copyWith(kind: 'invalid', body: const Value(null), targetId: const Value(null)));
        continue;
      }
      if (p is! UnknownBody) await db.replaceMessage(_classify(r, p, forwarded: _forwardedFlag(utf8.encode(body))));
    }
  }

  Future<void> _retryUndecryptable() async {
    for (final r in await db.undecryptable()) {
      final env = r.envelope;
      if (env == null || r.seq == null) continue;
      final row = await _decrypt(MessageDto(
        chatId: r.chatId,
        seq: r.seq!,
        id: r.id,
        senderUserId: r.senderUserId,
        senderDeviceId: r.senderDeviceId,
        envelope: (jsonDecode(env) as Map).cast<String, Object?>(),
        createdAt: r.createdAt,
      ));
      if (row.kind != 'undecryptable') await db.replaceMessage(row);
    }
  }

  Future<void> _refreshChat(String chatId) async {
    try {
      await db.upsertChat(await api.chat(chatId));
    } on ApiException catch (e) {
      if (e.code != 'not_found') rethrow;
      await db.deleteChat(chatId);
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Events

  Future<void> _onEvent(Map<String, Object?> e) async {
    switch (e['type']) {
      case 'msg':
        final m = e['message'];
        if (m is Map<String, Object?>) await _apply(MessageDto.fromJson(m));
      case 'ack':
        await _onAck(e);
      case 'error':
        await _onSendError(e);
      case 'chat':
        final chatId = e['chatId'] as String;
        await _refreshChat(chatId);
        if (await db.chatById(chatId) == null) return;
        await keys.fetch(chatId: chatId);
        await keys.ensureCurrentEpoch(chatId);
        await _catchUp(chatId);
        await _retryUndecryptable();
        await _flushOutbox();
      case 'removed':
        await db.deleteChat(e['chatId'] as String);
      case 'device':
        // A device was added (pairing) or revoked: refresh who gets wraps. A new one gets the keys
        // this device holds now, instead of when some member next reconnects.
        final acked = await directory.refresh();
        if (acked.isNotEmpty) await _retryUndecryptable();
        if (e['revoked'] != true || acked.isNotEmpty) await _repair();
      case 'reset':
        // An account was reset (or the reset was claimed): a verified one is trusted without the
        // manual banner, and the user's new device gets the history from this one.
        // Always retry and repair: the trust may have moved in a refresh made outside this queue.
        await directory.refresh();
        await _retryUndecryptable();
        await _repair();
      case 'profile':
        // Someone changed their profile photo: the directory has the new key.
        await directory.refresh();
      case 'family':
        // A family I'm in was renamed, approved, joined or left: who shares a family with whom may
        // have changed, and so has the families list.
        await directory.refresh();
        onFamiliesChanged?.call();
      case 'account_deleted':
        // Someone's account was deleted: they're renamed and their devices revoked. The `chat`
        // events that come with it move each shared chat to a new epoch.
        await directory.refresh();
      case 'keys':
        await keys.fetch(chatId: e['chatId'] as String?);
        await _retryUndecryptable();
        await _flushOutbox();
      case 'read':
        final chatId = e['chatId'] as String, userId = e['userId'] as String, seq = e['seq'] as int;
        await db.setMemberRead(chatId, userId, seq);
        if (userId == me.userId) await db.setMyLastRead(chatId, seq);
      case 'typing':
        _onTyping(e['chatId'] as String, e['userId'] as String);
      case 'hello':
        _setOnline({...(e['online'] as List).cast<String>()});
      case 'presence':
        final u = e['userId'] as String;
        _setOnline(e['online'] == true ? {..._online, u} : ({..._online}..remove(u)));
    }
  }

  Future<void> _repair() async {
    try {
      await keys.repairMissing();
    } on ApiException {
      // Membership changed meanwhile; the next sync repairs.
    }
  }

  /// Marks the acked row sent (also run early, on the send lane: see [start]).
  Future<MessageRow?> _recordAck(Map<String, Object?> e) async {
    final id = e['id'] as String, seq = e['seq'] as int, at = e['createdAt'] as int;
    _inflight.remove(id);
    _staleRetries.remove(id);
    final row = await db.messageById(id);
    if (row != null && row.seq == null) await db.ackMessage(id, seq: seq, createdAt: at);
    return row;
  }

  Future<void> _onAck(Map<String, Object?> e) async {
    final seq = e['seq'] as int, at = e['createdAt'] as int;
    final row = await _recordAck(e);
    if (row == null) return;
    final chat = await db.chatById(row.chatId);
    if (chat == null) return;
    if (seq == chat.syncedSeq + 1) {
      await db.setSyncedSeq(row.chatId, seq);
      await db.noteActivity(row.chatId, seq, at);
    } else if (seq > chat.syncedSeq + 1) {
      await _catchUp(row.chatId);
    }
  }

  Future<void> _onSendError(Map<String, Object?> e) async {
    final id = e['id'];
    if (id is! String) return;
    _inflight.remove(id);
    final row = await db.messageById(id);
    if (row == null || row.state != 'pending') return;
    switch (e['error']) {
      case 'stale_epoch':
        final n = (_staleRetries[id] ?? 0) + 1;
        _staleRetries[id] = n;
        if (n > maxStaleRetries) {
          await db.setMessageState(id, 'failed');
          return;
        }
        await _refreshChat(row.chatId);
        if (await db.chatById(row.chatId) == null) {
          await db.setMessageState(id, 'failed');
          return;
        }
        await keys.ensureCurrentEpoch(row.chatId);
        await _onSendLane(() async => _sendRow((await db.messageById(id))!));
      case 'not_member':
        await db.setMessageState(id, 'failed');
        await _refreshChat(row.chatId);
      case 'no_shared_family':
        // The other person is no longer in a family with us: this can't be sent. Their `former`
        // flag is in the directory now, so the chat turns read-only.
        await db.setMessageState(id, 'failed');
        await directory.refresh();
      case 'internal':
        // Stays pending; resent on the next connect or flush.
        break;
      default:
        await db.setMessageState(id, 'failed');
    }
  }

  void _setOnline(Set<String> s) {
    _online = s;
    _onlineCtl.add(onlineNow);
  }

  void _onTyping(String chatId, String userId) {
    final m = _typing[chatId] ??= {};
    m[userId]?.cancel();
    m[userId] = Timer(typingTtl, () {
      _typing[chatId]?.remove(userId);
      if (_typing[chatId]?.isEmpty ?? false) _typing.remove(chatId);
      _emitTyping();
    });
    _emitTyping();
  }

  void _emitTyping() => _typingCtl.add({for (final e in _typing.entries) e.key: e.value.keys.toSet()});

  // ---------------------------------------------------------------------------------------------
  // Sending

  /// Runs [f] on the send lane, after the sends queued before it. Like [_enqueue], a failure is
  /// logged, not propagated to the lane; the returned future does carry it.
  Future<void> _onSendLane(Future<void> Function() f) {
    final run = _sendLane.then((_) => f());
    _sendLane = run.catchError((Object e, StackTrace st) {
      // ignore: avoid_print
      if (e is! NetworkException && e is! SignedOutException) print('chat send: $e\n$st');
    });
    return run;
  }

  /// Sends every pending message not already in flight (on the send lane).
  Future<void> _flushOutbox() => _onSendLane(_flushOutboxNow);

  Future<void> _flushOutboxNow() async {
    if (!hub.connected) return;
    for (final row in await db.pendingOutbox(me.deviceId)) {
      if (_inflight.contains(row.id)) continue;
      await _sendRow(row);
    }
  }

  /// Encrypts [row] under the chat's current epoch (same id every time) and sends it.
  Future<void> _sendRow(MessageRow row) async {
    if (row.state != 'pending' || !hub.connected) return;
    final gate = beforeSend;
    try {
      if (gate == null ? mediaKinds.contains(row.kind) : !await gate(row)) return; // media not uploaded yet
    } catch (_) {
      return; // the gate's storage failed: keep the row pending, don't stall the rest of the outbox
    }
    final ok = await keys.ensureCurrentEpoch(row.chatId);
    final chat = await db.chatById(row.chatId);
    if (chat == null) {
      await db.setMessageState(row.id, 'failed');
      return;
    }
    if (!ok) return; // waits for the epoch's key (a keys/chat event or the next sync retries)
    final key = (await keys.key(row.chatId, chat.currentEpoch))!;
    final env = await encryptEnvelope(
      chatKey: key,
      epoch: chat.currentEpoch,
      chatId: row.chatId,
      messageId: row.id,
      senderDeviceId: me.deviceId,
      signKey: me.keys.sign,
      plaintext: utf8.encode(row.body!),
    );
    if (hub.send({
      'type': 'send',
      'id': row.id,
      'chatId': row.chatId,
      'envelope': env.toJson(),
      // Changes to other messages notify no one (docs/protocol.md "send").
      if (changeKinds.contains(row.kind)) 'silent': true,
      // The server can't read the text: it needs these to push the people mentioned.
      if (_mentionsOf(row) case final m when m.isNotEmpty) 'mentions': m,
    })) {
      _inflight.add(row.id);
      _handedToHub.add(row.id);
    }
  }

  static List<String> _mentionsOf(MessageRow row) {
    if (row.kind != 'text' || row.body == null) return const [];
    try {
      final p = Plaintext.decode(utf8.encode(row.body!));
      return p is TextBody ? p.mentions : const [];
    } on FormatException {
      return const [];
    }
  }

  /// Called before each outbox send; false keeps the row pending without sending it (the media
  /// layer returns false until a message's blobs are uploaded, then calls [flushSoon]).
  Future<bool> Function(MessageRow row)? beforeSend;

  /// Kinds that reference uploaded blobs: held in the outbox while no [beforeSend] gate is set.
  static const mediaKinds = {'photo', 'voice', 'video'};

  /// Whether this device has a message the server hasn't acknowledged yet (sending, or waiting
  /// for a connection or an upload).
  Future<bool> hasUnsent() async => (await db.pendingOutbox(me.deviceId)).isNotEmpty;

  /// Queues an outbox flush (on the send lane).
  void flushSoon() => unawaited(_flushOutbox().catchError((_) {}));

  /// Queues any plaintext kind (media messages; [id] lets the caller tie uploads to the message).
  /// [forwarded] marks a copy of another message (`"forwarded": true`).
  Future<String> enqueueMessage(String chatId, Plaintext p, {String? id, bool forwarded = false}) =>
      _enqueueMessage(chatId, p, id: id, forwarded: forwarded);

  Future<String> _enqueueMessage(String chatId, Plaintext p, {String? targetId, String? id, bool forwarded = false}) async {
    id ??= newUlid(_now());
    await db.insertMessageIfAbsent(MessageRow(
      id: id,
      chatId: chatId,
      seq: null,
      senderUserId: me.userId,
      senderDeviceId: me.deviceId,
      kind: p.kind,
      body: jsonEncode({...p.toJson(), if (forwarded) 'forwarded': true}),
      targetId: targetId,
      envelope: null,
      createdAt: _now().millisecondsSinceEpoch,
      state: 'pending',
    ));
    unawaited(_flushOutbox().catchError((_) {}));
    return id;
  }

  /// Queues a text message (optionally a reply to [replyTo]) and returns its id. Throws
  /// [ArgumentError] for empty or too-long text.
  /// [mentions]: users @mentioned in it (see `lib/chat/mentions.dart`).
  Future<String> sendText(String chatId, String text, {String? replyTo, List<String> mentions = const []}) {
    final t = validMessageText(text);
    if (t == null) throw ArgumentError.value(text, 'text', 'empty or longer than $maxTextLength characters');
    return _enqueueMessage(chatId, TextBody(t, replyTo: replyTo, mentions: mentions.take(maxMentions).toList()));
  }

  /// Replaces the text of this user's text message [messageId]. Throws [ArgumentError] for empty or
  /// too-long text.
  Future<void> editText(String chatId, String messageId, String text) {
    final t = validMessageText(text);
    if (t == null) throw ArgumentError.value(text, 'text', 'empty or longer than $maxTextLength characters');
    return _enqueueMessage(chatId, EditBody(messageId, t), targetId: messageId);
  }

  /// Whether [attachPreview] would attach a preview of [url] to [messageId] now.
  Future<bool> canAttachPreview(String chatId, String messageId, String url) async {
    final own = await _ownText(chatId, messageId);
    return own != null && !own.$2 && previewFits(own.$1, url);
  }

  /// The text this user's text message [messageId] shows now (after edits) and whether it shows a
  /// link preview; null when it's gone, deleted, someone else's, or not a text.
  Future<(String, bool)?> _ownText(String chatId, String messageId) async {
    final m = await db.messageById(messageId);
    if (m == null || m.chatId != chatId || m.senderUserId != me.userId) return null;
    final changes = messageChanges([m, ...await db.changesTo(chatId, messageId)]);
    final text = changes.textOf(m);
    return text == null ? null : (text, changes.previewOf(m) != null);
  }

  /// Attaches [preview] to this user's text [messageId], sent before its link's preview was ready:
  /// a preview-only edit repeating the text as it stands (docs/protocol.md "Link previews"). [id]
  /// lets the caller tie the preview's image upload to the edit. Returns the edit's id, or null
  /// when the message is gone, no longer has the link, or already shows a preview. Runs in the sync
  /// queue, like deletes, so the check and the enqueue see the same message.
  Future<String?> attachPreview(String chatId, String messageId, LinkPreview preview, {String? id}) async {
    String? sent;
    await _enqueue(() async {
      final own = await _ownText(chatId, messageId);
      if (own == null) return;
      final (text, hasPreview) = own;
      if (hasPreview || !previewFits(text, preview.url)) return;
      sent = await _enqueueMessage(
        chatId,
        EditBody(messageId, text, preview: preview, previewOnly: true),
        targetId: messageId,
        id: id,
      );
    });
    return sent;
  }

  /// Unsends this user's message [messageId] for everyone. A message still in this device's outbox
  /// is just dropped.
  /// Runs in the sync queue, so the outbox can't start sending the message meanwhile.
  Future<void> deleteMessage(String chatId, String messageId) => _enqueue(() async {
        final row = await db.messageById(messageId);
        // Only a row this engine made and never handed to the hub can't be on the server yet.
        if (row != null &&
            row.seq == null &&
            row.senderDeviceId == me.deviceId &&
            row.createdAt >= _madeAt &&
            !_handedToHub.contains(messageId)) {
          await db.deleteMessages([messageId, for (final c in await db.changesTo(chatId, messageId)) c.id]);
          return;
        }
        await _enqueueMessage(chatId, DeleteBody(messageId), targetId: messageId);
      });

  /// Mutes [chatId] for this user until [until] (Unix ms), or unmutes it (null).
  Future<void> mute(String chatId, int? until) async {
    await api.muteChat(chatId, until);
    await db.setMutedUntil(chatId, until);
  }

  /// Sets this user's reaction on [messageId]; an empty [emoji] removes it.
  Future<void> react(String chatId, String messageId, String emoji) =>
      _enqueueMessage(chatId, ReactionBody(messageId, emoji), targetId: messageId);

  /// Starts [game] in [chatId]; the returned id (the message's) is the game's id. [first] moves first.
  /// A [GameType.seeded] game gets [seed], or a fresh [newSeed]. [optionalJumps] is checkers' house rule.
  Future<String> startGame(
    String chatId,
    GameType game, {
    required String first,
    int? seed,
    bool optionalJumps = false,
    bool wholeDeck = false,
  }) => _enqueueMessage(
    chatId,
    GameBody(
      game,
      first,
      seed: game.seeded ? seed ?? newSeed() : null,
      optionalJumps: optionalJumps,
      wholeDeck: wholeDeck,
    ),
  );

  /// Sends [action] (docs/protocol.md "Games") for game [gameId] at move number [ply].
  Future<String> sendMove(String chatId, String gameId, GameType game, int ply, Map<String, Object?> action) =>
      _enqueueMessage(chatId, MoveBody(gameId, game, ply, action, rules: game.rules), targetId: gameId);

  /// Trusts [userId]'s changed identity key (the banner's OK): their waiting messages are shown and
  /// their new devices get the chat keys this device holds.
  /// Renames this user; the directory is refreshed, so the new name shows at once. Throws
  /// [ArgumentError] for a blank or too-long name.
  Future<void> rename(String name) async {
    final t = name.trim();
    if (t.isEmpty || t.runes.length > maxNameLength) throw ArgumentError.value(name, 'name', 'blank or too long');
    await api.setName(t);
    await _enqueue(() => directory.refresh());
  }

  /// Longest display name (the server's limit).
  static const maxNameLength = 40;

  /// Sets this user's profile photo ([jpeg], see `lib/profile/avatar.dart`), or removes it when
  /// null; returns the new photo's key. The directory is refreshed, so it shows at once.
  Future<String?> setAvatar(Uint8List? jpeg) async {
    final String? key;
    if (jpeg == null) {
      await api.removeAvatar();
      key = null;
    } else {
      key = await api.setAvatar(jpeg);
    }
    await _enqueue(() => directory.refresh());
    return key;
  }

  Future<void> acknowledgeIdentity(String userId) async {
    await directory.acknowledgeIdentity(userId);
    await _enqueue(() async {
      await _retryUndecryptable();
      await keys.repairMissing();
    });
  }

  /// Puts a failed message back in the outbox.
  Future<void> retry(String messageId) async {
    await db.setMessageState(messageId, 'pending');
    unawaited(_flushOutbox().catchError((_) {}));
  }

  /// Marks everything stored in [chatId] as read (locally and on the server).
  Future<void> markRead(String chatId) async {
    final chat = await db.chatById(chatId);
    final newest = await db.maxSeq(chatId);
    if (chat == null || newest == null || newest <= chat.myLastReadSeq) return;
    await db.setMyLastRead(chatId, newest);
    hub.send({'type': 'read', 'chatId': chatId, 'seq': newest});
  }

  /// Call on every keystroke; sends at most one typing event per [typingThrottle].
  void typing(String chatId) {
    final now = _now();
    final last = _lastTypingSent[chatId];
    if (last != null && now.difference(last) < typingThrottle) return;
    if (hub.send({'type': 'typing', 'chatId': chatId})) _lastTypingSent[chatId] = now;
  }

  // ---------------------------------------------------------------------------------------------
  // Chats and membership

  /// The direct chat with [userId], created if there is none (the server dedupes per pair).
  Future<String> openDirect(String userId) async {
    for (final c in await db.allChats()) {
      if (c.kind != 'direct') continue;
      final members = {for (final m in await db.membersOf(c.id)) m.userId};
      if (members.length == 2 && members.contains(userId) && members.contains(me.userId)) return c.id;
    }
    return _create('direct', null, [userId]);
  }

  /// A new group of [userIds] in [familyId] (null: the server picks; docs/protocol.md "Chats").
  Future<String> createGroup(String title, List<String> userIds, {int? familyId}) =>
      _create('group', title.trim(), userIds, familyId: familyId);

  Future<String> _create(String kind, String? title, List<String> userIds, {int? familyId}) async {
    final others = userIds.where((u) => u != me.userId).toSet().toList();
    final id = newUlid(_now());
    final key = newChatKey();
    for (var attempt = 0;; attempt++) {
      final devices = await directory.liveDevices([me.userId, ...others]);
      if (attempt == 0 && others.any((u) => !devices.any((d) => d.userId == u))) {
        await directory.refresh();
        continue;
      }
      final wraps = await keys.wrapKey(chatId: id, epoch: 1, key: key, devices: await directory.liveDevices([me.userId, ...others]));
      try {
        final r = await api.createChat(id: id, kind: kind, title: title, userIds: others, wraps: wraps, familyId: familyId);
        if (r.chat.id == id) await db.putKey(id, 1, key);
        await db.upsertChat(r.chat);
        if (r.chat.id != id) {
          await keys.fetch(chatId: r.chat.id);
          unawaited(_enqueue(() => _catchUp(r.chat.id)));
        }
        return r.chat.id;
      } on ApiException catch (e) {
        if (e.code != 'wraps_mismatch' || attempt >= 2) rethrow;
        await directory.refresh();
      }
    }
  }

  /// Adds people to a group; they get every epoch key this device holds, so they see the history.
  /// Throws [ArgumentError] for a direct chat (the UI makes a new group instead).
  Future<void> addMembers(String chatId, List<String> userIds) async {
    final chat = await db.chatById(chatId);
    if (chat == null) throw ArgumentError.value(chatId, 'chatId', 'unknown chat');
    if (chat.kind == 'direct') throw ArgumentError.value(chatId, 'chatId', 'direct chats keep two people; create a group');
    for (var attempt = 0;; attempt++) {
      await keys.ensureCurrentEpoch(chatId);
      final wraps = await keys.wrapsForNewDevices(chatId, userIds);
      try {
        await db.upsertChat(await api.addMembers(chatId, userIds, wraps));
        return;
      } on ApiException catch (e) {
        if (attempt >= 2 || (e.code != 'wraps_mismatch' && e.code != 'stale_epoch')) rethrow;
        await directory.refresh();
        await _refreshChat(chatId);
      }
    }
  }

  Future<void> leave(String chatId) async {
    await api.removeMember(chatId, me.userId);
    await db.deleteChat(chatId);
  }

  /// Removes someone (group creator only). This device creates the new epoch right away.
  Future<void> removeMember(String chatId, String userId) async {
    await api.removeMember(chatId, userId);
    await _refreshChat(chatId);
    await keys.ensureCurrentEpoch(chatId);
  }
}
