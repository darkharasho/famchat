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

/// A reminder of mine that came: now (the server's `reminder` frame) or while every device of mine
/// was off ([missed]: found at the next open).
class FiredReminder {
  const FiredReminder({required this.chatId, required this.messageId, required this.at, this.missed = false});
  final String chatId, messageId;

  /// The time it was set for (Unix ms).
  final int at;
  final bool missed;
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
    _stopped = false;
    db.myUserId = me.userId;
    db.clock = () => _now().millisecondsSinceEpoch;
    await db.bindDevice(me.deviceId);
    unawaited(_enqueue(_reclassifyUnknown));
    // Disappearing messages whose time came while the app was closed go first; then a timer waits
    // for the next one (re-armed whenever messages change).
    unawaited(_enqueue(_sweep));
    _subs.add(db.watchNextExpiry().listen(_armSweep));
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
        unawaited(_flushScheduled().catchError((_) {}));
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
    _sweepTimer?.cancel();
    _sweepTimer = null;
    _stopped = true;
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
    try {
      await refreshStars();
    } catch (_) {
      // Stars wait for the next sync or `stars` event; they never hold up messages and keys.
    }
    try {
      await syncGone();
    } catch (_) {
      // Tombstones wait for the next sync; the device's own timers still run meanwhile.
    }
    try {
      await refreshReminders();
    } catch (_) {
      // Reminders wait for the next sync or `reminders` event.
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
    try {
      // After the keys: it decrypts what other devices scheduled and re-encrypts what needs it.
      await refreshScheduled();
    } catch (_) {
      // The list waits for the next sync or `scheduled` event; messages don't wait for it.
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
      if (existing.seq == null) {
        await db.ackMessage(m.id, seq: m.seq, createdAt: m.createdAt, disappearSecs: m.disappearSecs);
      }
      _inflight.remove(m.id);
      row = existing;
    } else {
      // One of my scheduled messages arriving: delivered at its time, or re-sent late by another of
      // my devices after a key change (then it shows "sent late" here too).
      final sched = m.senderUserId == me.userId ? await db.scheduledById(m.id) : null;
      row = (decrypted ?? await _decrypt(m)).copyWith(
        expiresAt: Value(_expiryOf(m, chat.myLastReadSeq, db.myReadAt(m.chatId))),
        scheduledFor: Value(sched?.state == 'needs_resend' ? sched!.deliverAt : null),
      );
      await db.insertMessageIfAbsent(row);
    }
    if (m.senderUserId == me.userId) await db.deleteScheduled(m.id);
    await db.setSyncedSeq(m.chatId, m.seq);
    // A change to another message isn't chat activity (0 leaves last_message_at as it is).
    await db.noteActivity(m.chatId, m.seq, changeKinds.contains(row.kind) ? 0 : m.createdAt);
    return existing == null ? row : null;
  }

  /// When this device deletes [m] (docs/protocol.md "Disappearing messages"), or null for no timer:
  /// my own at sent + timer; someone else's at my read time + timer once my read position
  /// ([myLastReadSeq]) passed it, until then at the backstop (sent + timer + 30 days). [readAt]: a
  /// time I had read up to [myLastReadSeq] by (see [ChatDb.myReadAt]); now when unknown or later.
  int? _expiryOf(MessageDto m, int myLastReadSeq, int? readAt) {
    final secs = m.disappearSecs;
    if (secs == null) return null;
    if (m.senderUserId == me.userId) return m.createdAt + secs * 1000;
    final backstop = m.createdAt + secs * 1000 + disappearBackstop.inMilliseconds;
    if (m.seq > myLastReadSeq) return backstop;
    final now = _now().millisecondsSinceEpoch;
    final read = (readAt != null && readAt < now ? readAt : now) + secs * 1000;
    return read < backstop ? read : backstop;
  }

  /// Past the timer, the server deletes a message by then even if not everyone read it.
  static const disappearBackstop = Duration(days: 30);

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
      disappearSecs: m.disappearSecs,
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
    return _classify(base, p, raw: _fields(raw));
  }

  /// A decoded plaintext's JSON object (empty if it isn't one).
  static Map<String, Object?> _fields(List<int> raw) {
    try {
      final j = jsonDecode(utf8.decode(raw));
      return j is Map<String, Object?> ? j : const {};
    } on FormatException {
      return const {};
    }
  }

  /// [base] stored as plaintext [p]'s kind. Fields of [raw] this version doesn't know (like
  /// `"forwarded"`, or ones a newer version added, such as a photo's caption before captions) are
  /// kept, so they show once the app updates.
  static MessageRow _classify(MessageRow base, Plaintext p, {Map<String, Object?> raw = const {}}) {
    final body = jsonEncode({...raw, ...p.toJson()});
    return switch (p) {
      TextBody() => base.copyWith(kind: 'text', body: Value(body)),
      ReactionBody(:final target) => base.copyWith(kind: 'reaction', body: Value(body), targetId: Value(target)),
      EditBody(:final target) => base.copyWith(kind: 'edit', body: Value(body), targetId: Value(target)),
      DeleteBody(:final target) => base.copyWith(kind: 'delete', body: Value(body), targetId: Value(target)),
      PinBody(:final target) => base.copyWith(kind: 'pin', body: Value(body), targetId: Value(target)),
      PhotoBody() => base.copyWith(kind: 'photo', body: Value(body)),
      VoiceBody() => base.copyWith(kind: 'voice', body: Value(body)),
      GifBody() => base.copyWith(kind: 'gif', body: Value(body)),
      VideoBody() => base.copyWith(kind: 'video', body: Value(body)),
      FileBody() => base.copyWith(kind: 'file', body: Value(body)),
      GameBody() => base.copyWith(kind: 'game', body: Value(body)),
      MoveBody(:final target) => base.copyWith(kind: 'move', body: Value(body), targetId: Value(target)),
      PollBody() => base.copyWith(kind: 'poll', body: Value(body)),
      VoteBody(:final target) => base.copyWith(kind: 'vote', body: Value(body), targetId: Value(target)),
      PollEndBody(:final target) => base.copyWith(kind: 'poll_end', body: Value(body), targetId: Value(target)),
      TranscriptBody(:final target) => base.copyWith(kind: 'transcript', body: Value(body), targetId: Value(target)),
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
      if (p is! UnknownBody) await db.replaceMessage(_classify(r, p, raw: _fields(utf8.encode(body))));
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
        disappearSecs: r.disappearSecs,
      ));
      if (row.kind != 'undecryptable') await db.replaceMessage(row.copyWith(expiresAt: Value(r.expiresAt)));
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
      case 'stars':
        await refreshStars();
      case 'scheduled':
        await refreshScheduled();
      case 'reminders':
        await refreshReminders();
      case 'reminder':
        // One of my reminders came: it's no longer set (the server deleted it), and it's shown.
        final chatId = e['chatId'], messageId = e['messageId'], at = e['at'];
        if (chatId is String && messageId is String && at is int) {
          await _onReminderLane(() => db.deleteReminder(messageId));
          _fire(FiredReminder(chatId: chatId, messageId: messageId, at: at));
        }
      case 'needs_resend':
        // My scheduled message's key changed before it went out: re-encrypt it and send it now.
        if (e['id'] case final String id) await _onSchedLane(() => _needsResend(id));
      case 'gone':
        // The server deleted these disappearing messages (everyone read them, or the backstop).
        final ids = [...?(e['ids'] as List?)?.whereType<String>()];
        if (ids.isNotEmpty) await purge(ids);
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
        await _onSchedLane(_openWaitingScheduled);
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
        if (e['lastSeenAt'] case final int at) await db.setLastSeen(u, at);
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
    // A scheduled message of mine was delivered (at its time, or sent now).
    await db.deleteScheduled(id);
    final row = await db.messageById(id);
    if (row != null && row.seq == null) {
      // The ack doesn't say which timer the server stamped: it took the chat's at delivery, which
      // this device knows from the chat's last `chat` event.
      final secs = e.containsKey('disappearSecs')
          ? e['disappearSecs'] as int?
          : (await db.chatById(row.chatId))?.disappearSecs;
      await db.ackMessage(id, seq: seq, createdAt: at, disappearSecs: secs);
    }
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
      // My own change to another message (a vote, reaction, pin, …) isn't chat activity either.
      await db.noteActivity(row.chatId, seq, changeKinds.contains(row.kind) ? 0 : at);
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
      // A scheduled message re-sent late uploaded its blobs when it was scheduled (here or on
      // another of my devices); the server keeps them under its id.
      if (row.scheduledFor == null && (gate == null ? mediaKinds.contains(row.kind) : !await gate(row))) return; // media not uploaded yet
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
    final env = await _encrypt(chat, row.id, row.body!);
    final change = changeKinds.contains(row.kind);
    // A change lives as long as its target: it takes the target's timer (none included), not the
    // chat's as it is now. Unknown until the target is stored: then the chat's, as the target gets.
    final target = change && row.targetId != null ? await db.messageById(row.targetId!) : null;
    if (hub.send({
      'type': 'send',
      'id': row.id,
      'chatId': row.chatId,
      'envelope': env.toJson(),
      // Changes to other messages notify no one (docs/protocol.md "send").
      if (change) 'silent': true,
      if (target != null && target.seq != null) 'disappearSecs': target.disappearSecs,
      // The server can't read the text: it needs these to push the people mentioned.
      if (_mentionsOf(row) case final m when m.isNotEmpty) 'mentions': m,
    })) {
      _inflight.add(row.id);
      _handedToHub.add(row.id);
    }
  }

  /// [body] encrypted under [chat]'s current epoch as message [id] from this device (the epoch's key
  /// must be here: see [ChatKeys.ensureCurrentEpoch]).
  Future<Envelope> _encrypt(ChatRow chat, String id, String body) async => encryptEnvelope(
        chatKey: (await keys.key(chat.id, chat.currentEpoch))!,
        epoch: chat.currentEpoch,
        chatId: chat.id,
        messageId: id,
        senderDeviceId: me.deviceId,
        signKey: me.keys.sign,
        plaintext: utf8.encode(body),
      );

  static List<String> _mentionsOf(MessageRow row) {
    if ((row.kind != 'text' && !captionKinds.contains(row.kind)) || row.body == null) return const [];
    try {
      final p = Plaintext.decode(utf8.encode(row.body!));
      return switch (p) {
        TextBody(:final mentions) || PhotoBody(:final mentions) || VideoBody(:final mentions) => mentions,
        _ => const [],
      };
    } on FormatException {
      return const [];
    }
  }

  /// Called before each outbox send; false keeps the row pending without sending it (the media
  /// layer returns false until a message's blobs are uploaded, then calls [flushSoon]).
  Future<bool> Function(MessageRow row)? beforeSend;

  /// Kinds that reference uploaded blobs: held in the outbox while no [beforeSend] gate is set.
  static const mediaKinds = {'photo', 'voice', 'video', 'file'};

  /// Whether this device has a message the server hasn't acknowledged yet (sending, or waiting
  /// for a connection or an upload).
  Future<bool> hasUnsent() async => (await db.pendingOutbox(me.deviceId)).isNotEmpty;

  /// Queues an outbox flush (on the send lane) and hands waiting scheduled messages to the server.
  void flushSoon() {
    unawaited(_flushOutbox().catchError((_) {}));
    unawaited(_flushScheduled().catchError((_) {}));
  }

  /// A media message whose blobs can't be uploaded (refused, or lost here): it fails, in the outbox
  /// or, not yet on the server, among the scheduled ones.
  Future<void> failUnsendable(String id) async {
    await db.setMessageState(id, 'failed');
    final s = await db.scheduledById(id);
    if (s != null && !s.onServer) await db.setScheduledState(id, 'failed');
  }

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
  /// [at]: schedule it for then instead (see [scheduleMessage]).
  Future<String> sendText(String chatId, String text, {String? replyTo, List<String> mentions = const [], DateTime? at}) {
    final t = validMessageText(text);
    if (t == null) throw ArgumentError.value(text, 'text', 'empty or longer than $maxTextLength characters');
    final body = TextBody(t, replyTo: replyTo, mentions: mentions.take(maxMentions).toList());
    return at == null ? _enqueueMessage(chatId, body) : scheduleMessage(chatId, body, at);
  }

  /// Replaces the text of this user's text message [messageId]. Throws [ArgumentError] for empty or
  /// too-long text.
  /// Pins [messageId] for everyone in the chat, or unpins it (docs/protocol.md "Pins").
  Future<String> pinMessage(String chatId, String messageId, {required bool pinned}) =>
      _enqueueMessage(chatId, PinBody(messageId, pinned: pinned), targetId: messageId);

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
    if (m == null || m.chatId != chatId || m.senderUserId != me.userId || m.kind != 'text') return null;
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

  /// Stars or unstars [messageId] for this user: here at once, then on the server (on the next sync
  /// if offline). A refusal (the message or chat is gone) undoes it here.
  Future<void> star(String chatId, String messageId, {required bool starred}) async {
    await db.setStar(chatId, messageId, starred: starred, at: _now().millisecondsSinceEpoch);
    await _onStarLane(() => _pushStar(chatId, messageId, starred));
  }

  /// Star pushes and refreshes run one at a time, in order: a quick star-then-unstar reaches the
  /// server in that order, and a refresh can't land on top of a newer toggle.
  Future<void> _starLane = Future.value();
  Future<void> _onStarLane(Future<void> Function() work) {
    final next = _starLane.then((_) => work());
    _starLane = next.catchError((_) {});
    return next;
  }

  Future<void> _pushStar(String chatId, String messageId, bool starred) async {
    try {
      await api.setStar(chatId, messageId, starred);
    } on ApiException catch (e) {
      if (e.status != 404) return; // retried on the next sync
      await db.dropStar(messageId); // the message or chat is gone
      return;
    } catch (_) {
      return; // offline: retried on the next sync
    }
    // Confirmed, unless it changed again meanwhile.
    final now = await db.starOf(messageId);
    if (now == null || now.starred != starred) return;
    if (starred) {
      await db.setStar(chatId, messageId, starred: true, at: now.starredAt, pending: false);
    } else {
      await db.dropStar(messageId);
    }
  }

  /// Sends stars made offline, then takes the server's list.
  Future<void> refreshStars() => _onStarLane(() async {
        for (final p in await db.pendingStars()) {
          await _pushStar(p.chatId, p.messageId, p.starred);
        }
        final stars = await api.stars();
        await db.replaceStars([for (final s in stars) (chatId: s.chatId, messageId: s.messageId, starredAt: s.starredAt)]);
      });

  /// Pins [chatId] to the top of this user's chat list, or unpins it.
  Future<void> pin(String chatId, bool pinned) async {
    await api.setChatState(chatId, pinned: pinned);
    // The `chat` event that follows brings the server's time.
    await db.setChatState(chatId, pinnedAt: Value(pinned ? _now().millisecondsSinceEpoch : null));
  }

  /// Archives [chatId] for this user (it comes back when a newer message arrives), or unarchives it.
  Future<void> archive(String chatId, bool archived) async {
    await api.setChatState(chatId, archived: archived);
    await db.setChatState(chatId, archivedAt: Value(archived ? _now().millisecondsSinceEpoch : null));
  }

  /// "Mark as unread" (until the chat is opened), or clears it.
  Future<void> markUnread(String chatId, bool unread) async {
    await db.setChatState(chatId, markedUnread: unread);
    await api.setChatState(chatId, unread: unread);
  }

  /// Renames group [chatId].
  Future<void> renameChat(String chatId, String title) async {
    final chat = await api.renameChat(chatId, title.trim());
    await db.upsertChat(chat);
  }

  /// Longest group title (the server's limit).
  static const maxTitleLength = 60;

  /// The timers a chat's disappearing messages may have (seconds); null is off.
  static const disappearOptions = [86400, 604800, 7776000];

  /// Sets [chatId]'s disappearing-message timer for everyone in it (any member may): one of
  /// [disappearOptions], or null to turn it off. Messages already sent keep the timer they had.
  Future<void> setDisappearing(String chatId, int? secs) async {
    if (secs != null && !disappearOptions.contains(secs)) throw ArgumentError.value(secs, 'secs', 'not a timer option');
    final chat = await api.setDisappearing(chatId, secs);
    await db.upsertChat(chat);
  }

  // ---------------------------------------------------------------------------------------------
  // Scheduled messages (docs/protocol.md "Scheduled messages")

  /// How far ahead a message can be scheduled (or a reminder set): the server's window.
  static const scheduleMin = Duration(minutes: 1), scheduleMax = Duration(days: 366);

  /// Whether [at] is between [scheduleMin] and [scheduleMax] from now.
  bool canScheduleAt(DateTime at) {
    final ahead = at.difference(_now());
    return ahead >= scheduleMin && ahead <= scheduleMax;
  }

  /// Scheduled-message work runs here, one job at a time (handing them to the server, refreshes,
  /// re-sends, cancels), so a refresh never lands in the middle of an edit. A failure is logged,
  /// not propagated to the lane; the returned future does carry it.
  Future<void> _schedLane = Future.value();
  Future<T> _onSchedLane<T>(Future<T> Function() f) {
    final run = _schedLane.then((_) => f());
    _schedLane = run.then((_) {}, onError: (Object e, StackTrace st) {
      // The caller gets its own errors (API refusals, bad input); only surprises are logged.
      if (e is! NetworkException && e is! SignedOutException && e is! ApiException && e is! StateError && e is! ArgumentError) {
        // ignore: avoid_print
        print('chat schedule: $e\n$st');
      }
    });
    return run;
  }

  /// Schedules [p] in [chatId] for [at] and returns its id ([id] lets the media layer tie the
  /// blobs it staged to it). The plaintext stays here; once its blobs are uploaded it's encrypted
  /// under the current epoch and handed to the server, which delivers it at [at] even if every
  /// device of mine is off. Throws [ArgumentError] when [at] isn't [scheduleMin] to [scheduleMax]
  /// ahead.
  Future<String> scheduleMessage(String chatId, Plaintext p, DateTime at, {String? id}) async {
    if (!canScheduleAt(at)) throw ArgumentError.value(at, 'at', 'not between a minute and 366 days ahead');
    id ??= newUlid(_now());
    final now = _now().millisecondsSinceEpoch;
    await db.putScheduled(ScheduledRow(
      id: id,
      chatId: chatId,
      kind: p.kind,
      body: jsonEncode(p.toJson()),
      envelope: null,
      deliverAt: at.millisecondsSinceEpoch,
      state: 'local',
      onServer: false,
      senderDeviceId: me.deviceId,
      createdAt: now,
      updatedAt: now,
    ));
    unawaited(_flushScheduled().catchError((_) {}));
    return id;
  }

  /// Hands every scheduled message made here and not on the server yet to it (on the lane).
  Future<void> _flushScheduled() => _onSchedLane(() async {
        for (final s in await db.scheduledToSubmit()) {
          try {
            await _submit(s);
          } on NetworkException {
            return; // offline: the next connect or flush
          } on ApiException {
            // Stays as it is; the next flush tries again.
          }
        }
      });

  /// [s] as the outbox gate and the mention list see a message.
  MessageRow _probe(ScheduledRow s, String body) => MessageRow(
        id: s.id,
        chatId: s.chatId,
        seq: null,
        senderUserId: me.userId,
        senderDeviceId: me.deviceId,
        kind: s.kind ?? _kindOf(body),
        body: body,
        targetId: null,
        envelope: null,
        createdAt: s.createdAt,
        state: 'pending',
      );

  static String _kindOf(String body) {
    try {
      return Plaintext.decode(utf8.encode(body)).kind;
    } on FormatException {
      return 'unknown';
    }
  }

  Future<void> _submit(ScheduledRow s) async {
    final body = s.body;
    if (body == null) return;
    final probe = _probe(s, body);
    final gate = beforeSend;
    try {
      // The same gate as the outbox: media is uploaded under the message id first.
      if (gate == null ? mediaKinds.contains(probe.kind) : !await gate(probe)) return;
    } catch (_) {
      return;
    }
    final fresh = await db.scheduledById(s.id);
    if (fresh == null || fresh.state != 'local' || fresh.onServer) return; // cancelled or failed meanwhile
    if (fresh.deliverAt - _now().millisecondsSinceEpoch < scheduleMin.inMilliseconds) {
      // Its time came while it waited (for an upload or a connection): it goes now, as a message.
      await _toOutbox(fresh, body);
      return;
    }
    for (var attempt = 0;; attempt++) {
      final ok = await keys.ensureCurrentEpoch(s.chatId);
      final chat = await db.chatById(s.chatId);
      if (chat == null) {
        await db.setScheduledState(s.id, 'failed');
        return;
      }
      if (!ok) return; // waits for the epoch's key, like the outbox
      final env = await _encrypt(chat, s.id, body);
      try {
        final d = await api.putScheduled(
          s.id,
          chatId: s.chatId,
          envelope: env.toJson(),
          deliverAt: fresh.deliverAt,
          mentions: _mentionsOf(probe),
        );
        await db.putScheduled(_rowOf(d, body: body));
        return;
      } on ApiException catch (e) {
        if (e.code == 'stale_epoch' && attempt < maxStaleRetries) {
          // The key changed: refresh the chat, get the new epoch's key and encrypt again.
          await _refreshChat(s.chatId);
          continue;
        }
        if (e.status >= 500 || e.status == 408 || e.status == 429) rethrow;
        if (e.status == 400 && fresh.deliverAt - _now().millisecondsSinceEpoch < 2 * scheduleMin.inMilliseconds) {
          await _toOutbox(fresh, body); // too close to its time now
          return;
        }
        await db.setScheduledState(s.id, 'failed');
        return;
      }
    }
  }

  /// [d] as stored here, with its plaintext [body] (null when it can't be read here).
  ScheduledRow _rowOf(ScheduledDto d, {String? body}) => ScheduledRow(
        id: d.id,
        chatId: d.chatId,
        kind: body == null ? null : _kindOf(body),
        body: body,
        envelope: jsonEncode(d.envelope),
        deliverAt: d.deliverAt,
        state: d.state,
        onServer: true,
        senderDeviceId: d.senderDeviceId,
        createdAt: d.createdAt,
        updatedAt: d.updatedAt,
      );

  /// Moves [s] into the outbox, to go now with a normal `send` under the same id: the server
  /// delivers a scheduled message of mine that way exactly once, whichever of my devices sends it.
  /// [scheduledFor] marks a late one (see [LocalMessages.scheduledFor]).
  Future<void> _toOutbox(ScheduledRow s, String body, {int? scheduledFor}) async {
    await db.transaction(() async {
      await db.insertMessageIfAbsent(MessageRow(
        id: s.id,
        chatId: s.chatId,
        seq: null,
        senderUserId: me.userId,
        senderDeviceId: me.deviceId,
        kind: _kindOf(body),
        body: body,
        targetId: null,
        envelope: null,
        createdAt: _now().millisecondsSinceEpoch,
        state: 'pending',
        scheduledFor: scheduledFor,
      ));
      await db.deleteScheduled(s.id);
    });
    unawaited(_flushOutbox().catchError((_) {}));
  }

  /// A `needs_resend` frame for [id].
  Future<void> _needsResend(String id) async {
    final s = await db.scheduledById(id);
    if (s == null || !s.onServer || s.state == 'cancelling') {
      await _refreshScheduledNow(); // brings it and re-sends it, or finishes cancelling it
      return;
    }
    await _resend(s.copyWith(state: 'needs_resend'));
  }

  /// Re-encrypts [s] under the current epoch and sends it now (late), from its plaintext here or,
  /// when this device has none (scheduled on a device since wiped), from what the server holds,
  /// decrypted with the key of the epoch it was encrypted under. Left listed when neither works.
  Future<void> _resend(ScheduledRow s) async {
    if (await db.messageById(s.id) != null) {
      await db.deleteScheduled(s.id); // already on its way from here (or delivered)
      return;
    }
    final env = s.envelope;
    final body = s.body ??
        (env == null || s.senderDeviceId == null
            ? null
            : await _openScheduled(s.id, s.chatId, s.senderDeviceId!, (jsonDecode(env) as Map).cast<String, Object?>()));
    if (body == null) {
      await db.putScheduled(s);
      return;
    }
    await _toOutbox(s, body, scheduledFor: s.deliverAt);
  }

  /// The plaintext JSON of my scheduled message [id] as the server holds it ([envelope], signed by
  /// my device [senderDeviceId]), decrypted with the key of its epoch (older epochs' keys stay
  /// here), or null when it can't be.
  Future<String?> _openScheduled(String id, String chatId, String senderDeviceId, Map<String, Object?> envelope) async {
    try {
      final env = Envelope.fromJson(envelope);
      final device = await directory.device(senderDeviceId);
      if (device == null || device.userId != me.userId || !device.trusted) return null;
      var key = await keys.key(chatId, env.epoch);
      if (key == null) {
        await keys.fetch(chatId: chatId);
        key = await keys.key(chatId, env.epoch);
      }
      if (key == null) return null;
      final raw = await decryptEnvelope(
        envelope: env,
        chatKey: key,
        chatId: chatId,
        messageId: id,
        senderDeviceId: senderDeviceId,
        senderSignPub: device.signPub,
      );
      final p = Plaintext.decode(raw);
      if (changeKinds.contains(p.kind)) return null;
      return jsonEncode({..._fields(raw), ...p.toJson()});
    } catch (_) {
      return null;
    }
  }

  /// Takes the server's list of my scheduled messages (`GET /me/scheduled`): ones gone from it
  /// were delivered, cancelled or dropped; ones scheduled or edited on another device are decrypted
  /// for showing; `needs_resend` ones are re-encrypted and sent.
  Future<void> refreshScheduled() => _onSchedLane(_refreshScheduledNow);

  Future<void> _refreshScheduledNow() async {
    await _retryCancels();
    final list = await api.scheduled();
    final ids = {for (final d in list) d.id};
    for (final local in await db.allScheduled()) {
      if (local.onServer && !ids.contains(local.id)) await db.deleteScheduled(local.id);
    }
    final resend = <ScheduledRow>[];
    for (final d in list) {
      // In this device's outbox (being re-sent or sent now) or already delivered.
      if (await db.messageById(d.id) != null) {
        await db.deleteScheduled(d.id);
        continue;
      }
      final local = await db.scheduledById(d.id);
      final env = jsonEncode(d.envelope);
      // Unchanged since this device last saw it (or this device's own hand-off whose answer was
      // lost): the plaintext here is still what the server holds.
      var body = local != null && (local.envelope == env || !local.onServer) ? local.body : null;
      body ??= await _openScheduled(d.id, d.chatId, d.senderDeviceId, d.envelope);
      final row = _rowOf(d, body: body);
      await db.putScheduled(row);
      if (d.state == 'needs_resend') resend.add(row);
    }
    for (final r in resend) {
      await _resend(r);
    }
  }

  /// Scheduled messages listed without their plaintext (their epoch's key wasn't here yet):
  /// decrypted now if they can be.
  Future<void> _openWaitingScheduled() async {
    for (final s in await db.allScheduled()) {
      final env = s.envelope, device = s.senderDeviceId;
      if (s.body != null || env == null || device == null) continue;
      final body = await _openScheduled(s.id, s.chatId, device, (jsonDecode(env) as Map).cast<String, Object?>());
      if (body != null) await db.putScheduled(s.copyWith(body: Value(body), kind: Value(_kindOf(body))));
    }
  }

  /// Cancels my scheduled message [id] everywhere (the server deletes the media uploaded for it).
  Future<void> cancelScheduled(String id) => _onSchedLane(() async {
        final s = await db.scheduledById(id);
        if (s == null) return;
        try {
          await api.deleteScheduled(id);
        } on ApiException catch (e) {
          if (e.status != 404) rethrow; // 404: gone already, or never handed over
        } catch (_) {
          // Offline: the server may hold it (or get it from a hand-off whose answer was lost). It
          // goes from the list now and the cancel is retried on the next refresh.
          await db.setScheduledState(id, 'cancelling');
          return;
        }
        await db.deleteScheduled(id);
      });

  /// Cancels left waiting for the server ([cancelScheduled] offline); throws while still offline.
  Future<void> _retryCancels() async {
    for (final s in await db.allScheduled()) {
      if (s.state != 'cancelling') continue;
      try {
        await api.deleteScheduled(s.id);
      } on ApiException catch (e) {
        if (e.status != 404) rethrow;
      }
      await db.deleteScheduled(s.id);
    }
  }

  /// Sends my scheduled message [id] now.
  Future<void> sendScheduledNow(String id) => _onSchedLane(() async {
        final s = await db.scheduledById(id);
        if (s == null) return;
        if (!s.onServer) {
          // Not on the server yet: it goes like any message (its blobs upload first).
          if (s.body case final body?) await _toOutbox(s, body);
          return;
        }
        if (s.state == 'needs_resend') return _resend(s);
        try {
          await api.sendScheduled(id);
          await db.deleteScheduled(id); // its `msg` and `ack` are on their way
        } on ApiException catch (e) {
          switch (e.code) {
            case 'stale_epoch':
              await _resend(s.copyWith(state: 'needs_resend'));
            case 'not_found':
              await db.deleteScheduled(id); // delivered or cancelled meanwhile
            default:
              rethrow;
          }
        }
      });

  /// Tries a failed scheduled message again: one the server refused or couldn't take is handed to
  /// it again; one the server failed to deliver goes now.
  Future<void> retryScheduled(String id) async {
    final s = await db.scheduledById(id);
    if (s == null) return;
    if (s.onServer) return sendScheduledNow(id);
    await db.setScheduledState(id, 'local');
    await _flushScheduled();
  }

  /// Changes my scheduled message [id]: its text or caption ([text]; for a caption, blank removes
  /// it) with its @[mentions], and/or its time [at]. The server's copy is replaced under the same
  /// id (re-encrypted under the current epoch). Throws [ArgumentError] for a bad time or text, and
  /// [StateError] when it's gone or can't be read here.
  Future<void> editScheduled(String id, {String? text, List<String>? mentions, DateTime? at}) => _onSchedLane(() async {
        final s = await db.scheduledById(id);
        if (s == null) throw StateError('no scheduled message $id');
        if (at != null && !canScheduleAt(at)) throw ArgumentError.value(at, 'at', 'not between a minute and 366 days ahead');
        final env = s.envelope;
        var body = s.body ??
            (env == null || s.senderDeviceId == null
                ? null
                : await _openScheduled(id, s.chatId, s.senderDeviceId!, (jsonDecode(env) as Map).cast<String, Object?>()));
        if (body == null) throw StateError("scheduled message $id can't be read here");
        if (text != null) body = _withText(body, text, mentions);
        final deliverAt = at?.millisecondsSinceEpoch ?? s.deliverAt;
        if (!s.onServer) {
          await db.putScheduled(s.copyWith(
            body: Value(body),
            deliverAt: deliverAt,
            state: 'local',
            updatedAt: _now().millisecondsSinceEpoch,
          ));
          unawaited(_flushScheduled().catchError((_) {}));
          return;
        }
        final probe = _probe(s, body);
        for (var attempt = 0;; attempt++) {
          final ok = await keys.ensureCurrentEpoch(s.chatId);
          final chat = await db.chatById(s.chatId);
          if (chat == null || !ok) throw StateError('no key for chat ${s.chatId}');
          final envelope = await _encrypt(chat, id, body);
          try {
            final d = await api.putScheduled(
              id,
              chatId: s.chatId,
              envelope: envelope.toJson(),
              deliverAt: deliverAt,
              mentions: _mentionsOf(probe),
            );
            await db.putScheduled(_rowOf(d, body: body));
            return;
          } on ApiException catch (e) {
            if (e.code != 'stale_epoch' || attempt >= maxStaleRetries) rethrow;
            await _refreshChat(s.chatId);
          }
        }
      });

  /// [body] with its text (a text) or caption (a photo or video) replaced.
  static String _withText(String body, String text, List<String>? mentions) {
    final j = Map<String, Object?>.from(jsonDecode(body) as Map);
    final t = validMessageText(text);
    switch (j['kind']) {
      case 'text':
        if (t == null) throw ArgumentError.value(text, 'text', 'empty or longer than $maxTextLength characters');
        j['text'] = t;
      case final String k when captionKinds.contains(k):
        if (text.trim().isEmpty) {
          j.remove('caption');
        } else if (t == null) {
          throw ArgumentError.value(text, 'text', 'longer than $maxTextLength characters');
        } else {
          j['caption'] = t;
        }
      default:
        throw ArgumentError.value(text, 'text', 'this message has no text');
    }
    if (mentions != null) {
      if (mentions.isEmpty) {
        j.remove('mentions');
      } else {
        j['mentions'] = mentions.take(maxMentions).toList();
      }
    }
    final out = jsonEncode(j);
    Plaintext.decode(utf8.encode(out)); // still a valid message
    return out;
  }

  // ---------------------------------------------------------------------------------------------
  // Reminders (docs/protocol.md "Reminders")

  /// Sets, clears and refreshes run one at a time, so a refresh can't undo a change made after it
  /// started.
  Future<void> _reminderLane = Future.value();
  Future<void> _onReminderLane(Future<void> Function() work) {
    final next = _reminderLane.then((_) => work());
    _reminderLane = next.catchError((_) {});
    return next;
  }

  /// Sets (or moves) my reminder on [messageId] to [at]: on the server, then here. Throws
  /// [ArgumentError] when [at] isn't [scheduleMin] to [scheduleMax] ahead, [ReminderAfterExpiry]
  /// when the message disappears from this device before then, and the API's errors (offline, or
  /// the message is gone).
  Future<void> setReminder(String chatId, String messageId, DateTime at) {
    if (!canScheduleAt(at)) throw ArgumentError.value(at, 'at', 'not between a minute and 366 days ahead');
    return _onReminderLane(() async {
      final expires = (await db.messageById(messageId))?.expiresAt;
      if (expires != null && at.millisecondsSinceEpoch >= expires) {
        throw ReminderAfterExpiry(DateTime.fromMillisecondsSinceEpoch(expires));
      }
      await api.setReminder(chatId, messageId, at.millisecondsSinceEpoch);
      await db.putReminder(chatId, messageId, at.millisecondsSinceEpoch);
    });
  }

  /// Clears my reminder on [messageId], on the server and here.
  Future<void> clearReminder(String chatId, String messageId) => _onReminderLane(() async {
        await api.clearReminder(chatId, messageId);
        await db.deleteReminder(messageId);
      });

  /// Takes the server's list of my reminders. One kept here that the server no longer lists came
  /// while this device was away when its time has passed (shown now, as missed), else it was
  /// cleared on another device.
  Future<void> refreshReminders() => _onReminderLane(() async {
        final list = await api.reminders();
        final ids = {for (final r in list) r.messageId};
        // A little slack: this device's clock may run a bit behind the server's.
        final now = _now().millisecondsSinceEpoch + reminderClockSlack.inMilliseconds;
        for (final r in await db.allReminders()) {
          if (ids.contains(r.messageId)) continue;
          await db.deleteReminder(r.messageId);
          if (r.at <= now) _fire(FiredReminder(chatId: r.chatId, messageId: r.messageId, at: r.at, missed: true));
        }
        for (final r in list) {
          await db.putReminder(r.chatId, r.messageId, r.at);
        }
      });

  /// A reminder gone from the server's list this close to its time counts as having come (see
  /// [refreshReminders]).
  static const reminderClockSlack = Duration(minutes: 2);

  /// Called with each reminder that comes (the notification layer shows it). Reminders that came
  /// while it's unset are handed over once it's set.
  void Function(FiredReminder r)? get onReminder => _onReminder;
  set onReminder(void Function(FiredReminder r)? f) {
    _onReminder = f;
    if (f != null && _firedBacklog.isNotEmpty) {
      final fired = [..._firedBacklog];
      _firedBacklog.clear();
      fired.forEach(f);
    }
  }

  void Function(FiredReminder r)? _onReminder;
  final _firedBacklog = <FiredReminder>[];

  void _fire(FiredReminder r) {
    final f = _onReminder;
    if (f != null) {
      f(r);
    } else if (_firedBacklog.length < 100) {
      _firedBacklog.add(r);
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Disappearing messages

  Timer? _sweepTimer;
  bool _stopped = false;

  /// Longest a sweep timer waits before looking again (timers drift while a device sleeps).
  static const sweepRecheck = Duration(hours: 1);

  /// Called with the rows each purge removed, so their media (cache, files) goes too; set by the
  /// media layer. Purges made while it's unset are handed over once it's set.
  void Function(List<MessageRow> rows)? get onPurged => _onPurged;
  set onPurged(void Function(List<MessageRow> rows)? f) {
    _onPurged = f;
    if (f != null && _purgedBacklog.isNotEmpty) {
      final rows = [..._purgedBacklog];
      _purgedBacklog.clear();
      f(rows);
    }
  }

  void Function(List<MessageRow> rows)? _onPurged;
  final _purgedBacklog = <MessageRow>[];

  /// Deletes messages [ids] here for good, with their changes, stars and media (see
  /// [ChatDb.purgeMessages]); returns the rows removed.
  Future<List<MessageRow>> purge(Iterable<String> ids) async {
    final wanted = ids.toSet();
    final reminded = [for (final r in await db.allReminders()) if (wanted.contains(r.messageId)) r];
    final rows = await db.purgeMessages(wanted);
    // The server would otherwise still remind me (with a preview) of a message my devices deleted.
    // Best effort: the server also drops reminders for messages past my copy's time.
    for (final r in reminded) {
      unawaited(_onReminderLane(() => api.clearReminder(r.chatId, r.messageId)).catchError((_) {}));
    }
    if (rows.isEmpty) return rows;
    final f = _onPurged;
    if (f != null) {
      f(rows);
    } else if (_purgedBacklog.length < 5000) {
      _purgedBacklog.addAll(rows);
    }
    return rows;
  }

  /// Deletes every message whose time came (in the sync queue); returns how many went.
  Future<int> purgeExpired() async {
    var n = 0;
    await _enqueue(() async => n = await _purgeExpiredNow());
    return n;
  }

  Future<int> _purgeExpiredNow() async {
    final ids = (await db.expiredIds(_now().millisecondsSinceEpoch)).toSet();
    if (ids.isEmpty) return 0;
    return (await purge(ids)).where((r) => ids.contains(r.id)).length;
  }

  /// Purges what expired and waits for the next one. Run on start, by the timer, and on resume.
  Future<void> _sweep() async {
    await _purgeExpiredNow();
    _armSweep(await db.nextExpiry());
  }

  /// The app came back to the foreground: timers may have slept, so look now.
  void sweepSoon() {
    if (!_stopped) unawaited(_enqueue(_sweep));
  }

  void _armSweep(int? at) {
    _sweepTimer?.cancel();
    _sweepTimer = null;
    if (at == null || _stopped) return;
    var wait = Duration(milliseconds: at - _now().millisecondsSinceEpoch);
    if (wait.isNegative) wait = Duration.zero;
    if (wait > sweepRecheck) wait = sweepRecheck;
    _sweepTimer = Timer(wait, () {
      _sweepTimer = null;
      if (!_stopped) unawaited(_enqueue(_sweep));
    });
  }

  /// Meta key of the `GET /me/gone` cursor.
  static const goneCursorKey = 'goneCursor';

  /// Drops the messages the server deleted while this device wasn't listening (`GET /me/gone`
  /// from the stored cursor, page by page).
  Future<void> syncGone() async {
    var cursor = int.tryParse(await db.metaValue(goneCursorKey) ?? '') ?? 0;
    for (;;) {
      final page = await api.gone(after: cursor, limit: goneLimit);
      if (page.gone.isNotEmpty) await purge([for (final g in page.gone) g.messageId]);
      if (page.cursor != cursor) {
        cursor = page.cursor;
        await db.setMeta(goneCursorKey, '$cursor');
      }
      if (page.gone.length < goneLimit) return;
    }
  }

  static const goneLimit = 500;

  /// Sets group [chatId]'s photo ([jpeg], see `lib/profile/avatar.dart`), or removes it when null;
  /// returns the new photo's key.
  Future<String?> setChatAvatar(String chatId, Uint8List? jpeg) async {
    final String? key;
    if (jpeg == null) {
      await api.removeChatAvatar(chatId);
      key = null;
    } else {
      key = await api.setChatAvatar(chatId, jpeg);
    }
    await db.setChatAvatarKey(chatId, key);
    return key;
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

  /// Sends [poll] to [chatId]; the returned id (the message's) is the poll's id. Throws
  /// [ArgumentError] for a poll receivers would drop (see [validPoll]).
  /// [at]: schedule it for then instead (see [scheduleMessage]).
  Future<String> sendPoll(String chatId, PollBody poll, {DateTime? at}) {
    final p = validPoll(poll.question, poll.options, multi: poll.multi, replyTo: poll.replyTo);
    if (p == null || p.options.length != poll.options.length) {
      throw ArgumentError.value(poll, 'poll', 'question or options out of limits');
    }
    return at == null ? _enqueueMessage(chatId, p) : scheduleMessage(chatId, p, at);
  }

  /// Sets this user's choices on poll [pollId] (option indexes); empty takes the vote back. Sent silent.
  Future<String> vote(String chatId, String pollId, List<int> choices) =>
      _enqueueMessage(chatId, VoteBody(pollId, List.unmodifiable(choices)), targetId: pollId);

  /// Ends this user's poll [pollId] for everyone (docs/protocol.md "Polls"). Sent silent.
  Future<String> endPoll(String chatId, String pollId) =>
      _enqueueMessage(chatId, PollEndBody(pollId), targetId: pollId);

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
    // Opening a chat clears "mark as unread" (here and on the server, for my other devices).
    if (chat != null && chat.markedUnread) unawaited(markUnread(chatId, false).catchError((_) {}));
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

/// A reminder asked for after the message disappears from this device ([expiresAt]).
class ReminderAfterExpiry implements Exception {
  ReminderAfterExpiry(this.expiresAt);
  final DateTime expiresAt;

  @override
  String toString() => 'ReminderAfterExpiry($expiresAt)';
}
