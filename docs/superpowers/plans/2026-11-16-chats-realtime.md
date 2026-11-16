# Chats & Real-time Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Family members create 1:1 and group chats and exchange end-to-end-encrypted text and reactions in real time, with read receipts, typing indicators, presence, offline sync and an outbox, on every platform.

**Architecture:** Server: a D1 migration for chats, members, key epochs, wraps, messages and WebSocket tickets; Hono routes for the family directory, chats, membership, key wraps and message history; one `FamilyHub` Durable Object (hibernatable WebSockets, `idFromName("family")`) that sequences and fans out messages and relays ephemeral events, and that REST routes notify over RPC. Client: a drift database (`lib/chat/db/`) is the single source of truth for the UI; `ChatSync` (`lib/chat/`) owns the directory (TOFU identity keys, device-cert checks), chat keys (signed wraps, epochs, missing-wrap repair), the hub connection (ticket, backoff, ping) and the outbox; Riverpod providers expose drift `watch()` streams to responsive Material 3 screens.

**Tech Stack:** Cloudflare Workers + Hono, Durable Objects (SQLite-backed class, hibernation API, RPC), D1, vitest 5 + `@cloudflare/vitest-plugin`. Flutter 3.50, Riverpod 3, go_router 18, drift 2.35 (+ `drift_flutter`, wasm on web), `web_socket_channel` 3, plan 3 `lib/crypto/`.

**Spec:** `docs/superpowers/specs/2026-11-15-famchat-design.md` ("Chats", "Architecture", "Message path", "Sync", "API surface", "D1 schema", "End-to-end encryption", "Devices and membership"). Roadmap row 5.

## Global Constraints

- Errors stay `{error: code}`. New codes: `wraps_mismatch` 409, `epoch_exists` 409, `stale_epoch` 409, `upgrade_required` 426.
- Times are Unix milliseconds. IDs are ULIDs (26 chars Crockford base32, `^[0-9A-HJKMNP-TV-Z]{26}$`); message and chat ids are made by the client.
- Wrap and envelope formats are plan 3's (`lib/crypto/wrap.dart`, `envelope.dart`); wire JSON for a wrap is `ChatKeyWrap.toJson()` (`chatId, epoch, recipientDeviceId, wrapperDeviceId, sealed, sig`), for an envelope `Envelope.toJson()` (`v, epoch, nonce, ct, sig`).
- Plaintext (inside the envelope) is UTF-8 JSON: `{"kind":"text","text":s}` (1–4000 chars after trim) or `{"kind":"reaction","target":messageId,"emoji":e}` (`e == ""` removes the reaction). Unknown kinds are stored and shown as "Unsupported message".
- The server never sees chat keys or plaintext; it checks shapes and membership only.
- A device accepts a wrap only if the wrapper device's cert verifies against its user's identity key **and** that user is a current member of the chat (per the server's member list). Envelope sender devices must have a cert that verifies against the sender user's identity key; the server's `senderUserId` must own the device.
- Identity keys are trusted on first use and stored locally; a later different key is accepted (admin resets are legitimate) but flagged on every chat with that user until acknowledged.
- `lib/crypto/` stays Flutter-free; `lib/chat/` (except `providers.dart`) is Flutter-free too, so unit tests run on the VM.
- The web build must compile: no `dart:io` or `drift/native.dart` imports under `lib/`; open the DB with `drift_flutter`'s `driftDatabase(... web: DriftWebOptions(sqlite3Wasm: Uri.parse('sqlite3.wasm'), driftWorker: Uri.parse('drift_worker.js')))` as in `lib/spikes/db_spike.dart`.
- Vitest `maxWorkers` ≤ 2; one build/test process at a time. Don't touch deploy workflows or the `assets` block plan 12 adds to `server/wrangler.jsonc`.

## Review Focus

1. **Lost ack / duplicate send:** the socket drops after the hub stored a message but before the ack → on reconnect the outbox resends the same id; the hub answers `ack` with the original `seq`, no second row, no second fan-out. Task 3 test `resending an id acks the original seq`; Task 7 test `outbox resend after reconnect does not duplicate`.
2. **Gaps and reordering:** a `msg` arrives with `seq` > local `syncedSeq + 1` (missed while reconnecting) → the client fetches `after=syncedSeq` before applying, so nothing is skipped and the list stays ordered. Task 7 test `a gap triggers a catch-up fetch`.
3. **Key for an epoch not yet held** (message from a new epoch, or wraps arriving after messages) → the message is stored as undecryptable with its envelope, and decrypted once the key arrives, not dropped. Task 7 test `a message decrypts later when its key arrives`.
4. **Server-forged wraps or sender:** a wrap signed by a device of a non-member, or an envelope whose sender device belongs to another user / has a bad cert → rejected, never decrypted with a made-up key. Task 5 tests `wrap from a non-member is rejected`, `wrap with a cert that does not chain is rejected`; Task 7 test `a message whose device is not the sender user's is rejected`.
5. **Leave/remove while sending:** epoch rotates while a message waits in the outbox → the hub answers `stale_epoch`, the client creates or fetches the new epoch and re-encrypts the same message id; a removed member's send gets `not_member` and is marked failed. Task 3 test `send with an old epoch is refused`; Task 7 test `stale_epoch re-encrypts under the new epoch`.

---

## Server contract (all under `/api`, all authed with `requireAuth` except `GET /ws`)

Shapes used below:
- `ChatOut = {id, kind: "direct"|"group", title: string|null, createdBy, currentEpoch, epochReady: bool, lastSeq, lastMessageAt: number|null, createdAt, members: [{userId, joinedSeq, lastReadSeq}]}`
- `MessageOut = {chatId, seq, id, senderUserId, senderDeviceId, envelope, createdAt}`
- `Wrap = ChatKeyWrap JSON`

| Route | Rules |
|---|---|
| `GET /users` | `{users: [{id, name, isAdmin, identityPub, devices: [{id, name, platform, encPub, signPub, certSig, revoked: bool}]}]}`, every user, every device (revoked ones too, for verifying history). |
| `GET /chats` | `{chats: ChatOut[]}` where caller is a member. |
| `GET /chats/:id` | `{chat: ChatOut}`; not a member → 404. |
| `POST /chats` | Body `{id, kind:"direct", userId, wraps}` or `{id, kind:"group", title (1–60), userIds (≥1, not caller), wraps}`. Caller always a member. Direct: other user must exist and differ; if the pair already has a direct chat → `200 {chat, created:false}` (wraps ignored). Same `id` already exists and caller created it → `200 {chat, created:false}`; exists otherwise → 400 `invalid_request`. Wraps must be **exactly** one per live device of every member for epoch 1, `chatId == id`, `wrapperDeviceId ==` caller device, else 409 `wraps_mismatch`. Creates epoch 1. → `201 {chat, created:true}`; hub event `chat` to members. |
| `POST /chats/:id/members` | Group only (direct → 400). Body `{userIds, wraps}`; caller member; new users exist and aren't members. Wraps for the current epoch must exactly cover the new users' live devices (else 409 `wraps_mismatch`); wraps for older existing epochs for those devices are accepted too. `joined_seq = last_seq`. → `{chat}`; event `chat` to all members. |
| `DELETE /chats/:id/members/:userId` | Group only. Self = leave (any member); other = remove (creator only, else 403; target not a member → 404). Deletes the member row, `current_epoch += 1` (not ready until created). → 204; events `removed {chatId}` to the removed user, `chat {chatId}` to the rest. |
| `POST /chats/:id/epochs` | Body `{epoch, wraps}`; caller member; `epoch != current_epoch` → 409 `stale_epoch`; epoch row exists → 409 `epoch_exists`; wraps exactly cover live member devices → else 409 `wraps_mismatch`. → 201; event `keys {chatId, epoch}` to members. |
| `GET /chats/:id/messages?after=N` or `?before=N`, `limit` (1–200, default 100) | Member only. `after`: seq > N ascending; `before`: the `limit` rows with seq < N, returned ascending. Neither → after=0. `{messages: MessageOut[]}`. |
| `GET /keys/wraps[?chatId=]` | `{wraps: Wrap[]}` addressed to the caller device, chats where the caller is a member. |
| `PUT /keys/wraps` | Body `{wraps}` (1–500). Each: caller member of `chatId`, `wrapperDeviceId ==` caller device, epoch exists, recipient is a live device of a current member; else 400 for the whole request. `INSERT OR IGNORE` (first wrap wins). → `{added}`; event `keys` to recipient users when added > 0. |
| `GET /keys/missing` | `{missing: [{chatId, epoch, deviceId}]}`: live devices of current members lacking a wrap for an existing epoch, only for (chat, epoch) pairs the caller's device holds a wrap for. |
| `POST /ws/ticket` | `{ticket, expiresAt}`; one-time, 30 s. |
| `GET /ws?ticket=` | No upgrade header → 426 `upgrade_required`; bad/used/expired ticket or revoked device → 401. Forwards to the hub with `x-famchat-user`/`x-famchat-device`. |

`DELETE /devices/:id` additionally calls `hub.disconnectDevice(id)`.

Hub WebSocket messages (JSON text frames):
- Client → hub: `{type:"send", id, chatId, envelope}`, `{type:"typing", chatId}`, `{type:"read", chatId, seq}`, `{type:"ping"}` (auto-answered `{type:"pong"}`).
- Hub → client: `{type:"hello", online:[userId]}` on connect; `{type:"ack", id, seq, createdAt}`; `{type:"error", id?, error}` (`invalid_request`, `not_member`, `stale_epoch`, `conflict`); `{type:"msg", message: MessageOut}`; `{type:"typing", chatId, userId}`; `{type:"read", chatId, userId, seq}`; `{type:"presence", userId, online}`; `{type:"chat", chatId}`; `{type:"removed", chatId}`; `{type:"keys", chatId, epoch?}`.
- `send` rules: envelope is an object with `v == 1`, `epoch == current_epoch`, epoch created (else `stale_epoch`), b64url `nonce`/`ct`/`sig`, JSON ≤ 64 KiB; caller member (else `not_member`); an existing id from the same device in the same chat → `ack` with the stored seq and no fan-out; existing id otherwise → `conflict`. Sends are processed one at a time in arrival order; seq is assigned in one D1 batch (`UPDATE chats … last_seq+1` then `INSERT … SELECT last_seq`). `msg` goes to every socket of every member except the sending socket. Members with no open socket are passed to `PushHook.notify({chatId, senderUserId, userIds, messageId})` (no-op until plan 9).

---

## File Structure

| File | Responsibility |
|---|---|
| `server/migrations/0003_chats.sql` | chats, chat_members, chat_epochs, chat_key_wraps, messages, ws_tickets |
| `server/src/lib/chatdb.ts` | `chatOut`, membership helpers, wrap validation/coverage |
| `server/src/routes/users.ts`, `chats.ts`, `keys.ts`, `ws.ts` | REST routes |
| `server/src/hub.ts` | `FamilyHub` DO, `hubStub(env)`, `PushHook` |
| `server/test/{users,chats,members,keys,messages,hub}.test.ts`, `test/chat-helpers.ts` | tests |
| `docs/protocol.md` | REST + WebSocket contract |
| `app/lib/chat/ulid.dart` | `newUlid()` |
| `app/lib/chat/wire.dart` | DTOs + `ChatApi` interface + `MissingWrap` |
| `app/lib/chat/http_chat_api.dart` | `HttpChatApi` over `ApiClient` |
| `app/lib/chat/db/chat_db.dart` (+ `.g.dart`) | drift schema and queries |
| `app/lib/chat/directory.dart` | users/devices, TOFU, cert checks |
| `app/lib/chat/chat_keys.dart` | chat keys, wraps, epochs, repair |
| `app/lib/chat/hub_link.dart` | `HubLink` interface, `HubConnection` (WebSocket, ticket, backoff, ping) |
| `app/lib/chat/plaintext.dart` | plaintext JSON kinds |
| `app/lib/chat/chat_sync.dart` | sync, outbox, events, sending, reactions, reads, typing, presence |
| `app/lib/chat/providers.dart` | Riverpod wiring |
| `app/lib/screens/chats/*.dart` | chat list, responsive shell, conversation, new chat, group info |
| `app/test/support/fake_chat_backend.dart` | in-memory server + hub for multi-device tests |

---

### Task 1: Migration, directory and chat creation/listing

**Files:** Create `server/migrations/0003_chats.sql`, `server/src/lib/chatdb.ts`, `server/src/routes/users.ts`, `server/src/routes/chats.ts`, `server/test/chat-helpers.ts`, `server/test/users.test.ts`, `server/test/chats.test.ts`; modify `server/src/index.ts`, `server/src/lib/errors.ts`, `server/test/helpers.ts` (`resetDb` clears the new tables first).

**Interfaces (Produces):**
- Tables: `chats(id PK, kind CHECK IN ('direct','group'), title, created_by, direct_key UNIQUE /* "<minUserId>:<maxUserId>" for direct */, current_epoch INT NOT NULL DEFAULT 1, last_seq INT NOT NULL DEFAULT 0, last_message_at, created_at)`; `chat_members(chat_id, user_id, joined_seq, last_read_seq DEFAULT 0, joined_at, PK(chat_id,user_id))` + index on `user_id`; `chat_epochs(chat_id, epoch, created_by_device, created_at, PK(chat_id,epoch))`; `chat_key_wraps(chat_id, epoch, device_id, wrapper_device_id, sealed, sig, created_at, PK(chat_id,epoch,device_id))` + index on `device_id`; `messages(chat_id, seq, id UNIQUE, sender_user_id, sender_device_id, envelope TEXT, created_at, PK(chat_id,seq))`; `ws_tickets(hash PK, user_id, device_id, expires_at)`.
- `chatdb.ts`: `isUlid(s)`, `chatOut(db, chatId): Promise<ChatOut|null>`, `isMember(db, chatId, userId)`, `parseWraps(v): WrapIn[]` (400 on shape), `liveDeviceIds(db, userIds): Promise<string[]>`, `checkCoverage(wraps, {chatId, epoch, wrapper, deviceIds})` (409 `wraps_mismatch` unless the epoch-`epoch` wraps' recipients equal `deviceIds` exactly, no duplicates), `wrapInserts(db, wraps)`.
- `chat-helpers.ts`: `fakeWrap(chatId, epoch, recipient, wrapper)`, `wrapsFor(chatId, epoch, wrapper, deviceIds)`, `createChat(token, body)`, `api(token, method, path, body?)`.

- [ ] **Step 1: Failing tests.** `users.test.ts`: `lists every user with devices` (two users, one revoked device → `revoked: true`, cert fields equal the inserted keys); `requires auth`. `chats.test.ts`: `creates a group with wraps for every member device` (201, `created:true`, members include caller with `joinedSeq 0`, `currentEpoch 1`, `epochReady true`); `direct chat is deduped per pair` (A creates with B, then B creates with A → 200, same id); `missing or extra wrap → wraps_mismatch` (omit B's second device; add a wrap for a stranger device); `wrapper must be the caller device` (409); `group needs a title and other users` (400 each); `unknown user` (400); `direct with self` (400); `same id re-post by creator returns existing` (200); `list shows only own chats`; `GET /chats/:id not a member → 404`.
- [ ] **Step 2: Run** `cd server && npx vitest run test/users.test.ts test/chats.test.ts` → FAIL.
- [ ] **Step 3: Implement** migration, `chatdb.ts`, routes; mount `/users`, `/chats`. Inserts for chat + members + epoch 1 + wraps go in one `db.batch`. Hub events are added in Task 3 (leave a `notify(c, userIds, event)` helper that is a no-op until then).
- [ ] **Step 4: Run** `npm test && npm run typecheck` → pass.
- [ ] **Step 5: Commit** `feat(server): chats schema, family directory, chat creation`

### Task 2: Membership, epochs, key wraps and history

**Files:** Modify `server/src/routes/chats.ts`; create `server/src/routes/keys.ts`, `server/test/members.test.ts`, `server/test/keys.test.ts`, `server/test/messages.test.ts`.

**Interfaces:** routes in the contract table (`/chats/:id/members`, `/chats/:id/epochs`, `/chats/:id/messages`, `/keys/*`). Messages are inserted directly in tests (hub comes in Task 3).

- [ ] **Step 1: Failing tests.** members: `add to group with current-epoch wraps` (`joinedSeq == lastSeq`); `add without wraps for a new device → wraps_mismatch`; `add to a direct chat → 400`; `leave bumps the epoch` (`currentEpoch 2`, `epochReady false`, caller gone); `creator removes a member`; `non-creator cannot remove another` (403); `removed user can no longer read messages` (404). epochs: `create the next epoch` (201, `epochReady true`); `second creator gets epoch_exists`; `old epoch → stale_epoch`; `wraps must cover live member devices`. keys: `GET wraps returns only mine`; `PUT repair wraps for a member's new device` (added 1, then duplicate added 0 and the first wrap stays); `PUT refuses a wrap for a non-member device` (400); `PUT refuses wrapper != caller` (400); `missing lists devices without wraps for epochs I hold`. messages: `after returns ascending rows above seq`; `before returns the latest rows below seq ascending`; `limit is capped at 200`; `non-member → 404`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** `npm test && npm run typecheck` → pass.
- [ ] **Step 5: Commit** `feat(server): chat membership, key epochs, wraps and message history`

### Task 3: FamilyHub Durable Object and WebSocket tickets

**Files:** Create `server/src/hub.ts`, `server/src/routes/ws.ts`, `server/test/hub.test.ts`, `docs/protocol.md`; modify `server/wrangler.jsonc` (`durable_objects.bindings [{name:"HUB", class_name:"FamilyHub"}]`, `migrations [{tag:"v1-hub", new_sqlite_classes:["FamilyHub"]}]`), `server/src/env.ts` (`HUB: DurableObjectNamespace<FamilyHub>`), `server/src/index.ts` (`export { FamilyHub }`, mount `/ws`), `server/src/routes/chats.ts`, `keys.ts`, `devices.ts` (real notifications); spec "API surface" (ws/users/keys lines).

**Interfaces (Produces):**
- `class FamilyHub extends DurableObject<Env>`: `fetch(req)` (WebSocket accept with tags `u:<userId>`, `d:<deviceId>`, attachment `{userId, deviceId}`; `setWebSocketAutoResponse` for ping/pong), `webSocketMessage`, `webSocketClose`, RPC `notify(userIds: string[], event: object): Promise<void>`, `disconnectDevice(deviceId): Promise<void>`, `onlineUserIds(): string[]`.
- `export interface PushHook { notify(job: {chatId, senderUserId, messageId, userIds: string[]}): Promise<void> }`, `export let pushHook: PushHook` (no-op; plan 9 replaces with a Queue producer), and `setPushHookForTests`.
- `hubStub(env)` = `env.HUB.get(env.HUB.idFromName("family"))`.

- [ ] **Step 1: Failing tests** (open sockets via `SELF.fetch(BASE/api/ws?ticket=…, {headers:{upgrade:"websocket"}})`, `res.webSocket.accept()`, a `nextMessage(ws, type)` helper with timeout): ticket: `ticket is one-time` (second use 401); `expired ticket 401`; `no upgrade header 426`. hub: `hello lists online users`; `presence online/offline broadcast`; `send is acked with seq 1 then 2 and fanned out to the other member, not to non-members`; `sender's other device receives msg`; `resending an id acks the original seq` (one row, no second msg); `id reused in another chat → conflict`; `non-member send → not_member`; `send with an old epoch is refused` (after a leave → `stale_epoch`); `bad envelope → invalid_request`; `typing reaches other members only`; `read updates last_read_seq (never backwards) and broadcasts`; `creating a chat notifies members with chat event`; `leave sends removed to the leaver`; `revoking a device closes its socket`; `members with no socket are passed to the push hook`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement**; write `docs/protocol.md` from the contract section above. **Step 4: Run** `npm test && npm run typecheck` → pass.
- [ ] **Step 5: Commit** `feat(server): FamilyHub Durable Object, WebSocket tickets, protocol doc`

### Task 4: Client wire layer and local database

**Files:** Create `app/lib/chat/ulid.dart`, `wire.dart`, `http_chat_api.dart`, `db/chat_db.dart` (+ generated `chat_db.g.dart` via `dart run build_runner build`), `plaintext.dart`; modify `app/lib/api/api_client.dart` (public `Future<Map<String,Object?>?> authedJson(String method, String path, {Object? body})`); tests `app/test/chat/wire_test.dart`, `app/test/chat/chat_db_test.dart`.

**Interfaces (Produces):**
- `String newUlid([DateTime? now])`.
- DTOs with `fromJson` (throw `FormatException`): `UserDto{id,name,isAdmin,identityPub,devices}`, `DeviceDto{id,userId,name,platform,encPub,signPub,certSig,revoked}`, `MemberDto{userId,joinedSeq,lastReadSeq}`, `ChatDto{id,kind,title,createdBy,currentEpoch,epochReady,lastSeq,lastMessageAt,createdAt,members}`, `MessageDto{chatId,seq,id,senderUserId,senderDeviceId,envelope,createdAt}`, `MissingWrap{chatId,epoch,deviceId}`.
- `abstract interface class ChatApi { users(); chats(); chat(id); createChat({id, kind, title, userIds, wraps}) → ({ChatDto chat, bool created}); addMembers(chatId, userIds, wraps) → ChatDto; removeMember(chatId, userId); createEpoch(chatId, epoch, wraps); messages(chatId, {after, before, limit}); wraps({chatId}); putWraps(wraps) → int; missingWraps(); wsTicket() → String }`; `HttpChatApi(ApiClient)` implements it.
- `Plaintext` sealed: `TextBody(text)`, `ReactionBody(target, emoji)`, `UnknownBody(kind)`; `Plaintext.decode(List<int>)`, `encode()`.
- drift `ChatDb(QueryExecutor)`, `openChatDb()` (drift_flutter, name `famchat_chats`), tables: `LocalChats(id PK, kind, title?, createdBy, currentEpoch, epochReady, lastSeq, lastMessageAt?, createdAt, myLastReadSeq, syncedSeq)`, `LocalMembers(chatId, userId, joinedSeq, lastReadSeq; PK)`, `LocalMessages(id PK, chatId, seq?, senderUserId, senderDeviceId, kind /* text|reaction|unknown|undecryptable */, body /* plaintext JSON or null */, targetId?, envelope? /* kept while undecryptable */, createdAt, state /* pending|sent|failed */)` + index `(chatId, seq)`, `LocalKeys(chatId, epoch, key BLOB; PK)`, `LocalUsers(id PK, name, isAdmin, identityPub, trustedIdentityPub)`, `LocalDevices(id PK, userId, encPub, signPub, certSig, revoked, certValid)`, `Meta(key PK, value)`.
  Queries: `upsertChat(ChatDto)` (keeps `syncedSeq`/`myLastReadSeq`), `replaceMembers`, `deleteChat(id)` (cascades its messages/keys/members), `insertMessageIfAbsent`, `ackMessage(id, seq, createdAt)`, `pendingOutbox()` (own `state==pending` ordered by createdAt), `watchChatList(myUserId)` → `Stream<List<ChatListItem{chat, members, lastText, unread}>>` sorted by `lastMessageAt ?? createdAt` desc, `watchMessages(chatId)` (sent by seq, then pending by createdAt), `watchMembers(chatId)`, `watchUsers()`, `bindDevice(deviceId)` (wipes all tables when the stored `deviceId` differs).
- [ ] **Step 1: Failing tests:** wire round-trip parsing of the contract shapes; `HttpChatApi` against a `MockClient` (paths, `wraps_mismatch` → `ApiException(409,'wraps_mismatch')`); `ulid sorts by time and is 26 chars`; plaintext encode/decode incl. unknown kind and an empty-text rejection; db: `chat list sorts by activity and counts unread from others only (not reactions)`, `upsert keeps local sync state`, `insertMessageIfAbsent dedupes by id`, `ack moves a pending message into seq order`, `bindDevice to another device wipes data`.
- [ ] **Step 2: Run** `flutter test test/chat/` → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS; `flutter analyze` clean.
- [ ] **Step 5: Commit** `feat(app): chat wire types, HTTP chat API and local drift database`

### Task 5: Directory and chat keys

**Files:** Create `app/lib/chat/directory.dart`, `app/lib/chat/chat_keys.dart`, `app/test/support/fake_chat_backend.dart`, `app/test/chat/directory_test.dart`, `app/test/chat/chat_keys_test.dart`.

**Interfaces (Produces):**
- `class LocalIdentity { userId, deviceId; DeviceKeys keys; }`.
- `class VerifiedDevice { id, userId; Uint8List encPub, signPub; bool revoked; }`
- `class Directory { Directory(ChatDb db, ChatApi api); Future<void> refresh(); Future<VerifiedDevice?> device(String id); Future<List<VerifiedDevice>> liveDevices(Iterable<String> userIds); Future<void> acknowledgeIdentity(String userId); }` — refresh stores users; first sight sets `trustedIdentityPub`; `certValid` = cert verifies against the user's current `identityPub` (`verifyDeviceCert`); `device()` returns null for unknown or invalid-cert devices (refreshes once on unknown).
- `class ChatKeys { ChatKeys({db, api, directory, me}); Future<Uint8List?> key(chatId, epoch); Future<List<ChatKeyWrap>> wrapKey({chatId, epoch, key, devices}); Future<int> fetch({String? chatId}); Future<bool> ensureCurrentEpoch(String chatId); Future<List<ChatKeyWrap>> wrapsForNewDevices(String chatId, List<String> userIds); Future<int> repairMissing(); }`
  - `fetch` verifies each wrap: wrapper device via `directory.device`, wrapper's user in the chat's local member list, then `unwrapChatKey`; bad wraps are skipped silently (they never yield a key).
  - `ensureCurrentEpoch`: chat ready and key held → true; ready but key missing → `fetch(chatId)`; not ready → new key, wraps for live member devices, `createEpoch`; on `epoch_exists` → `fetch`; on `wraps_mismatch` → refresh directory + chat once and retry; on `stale_epoch` → refresh chat and retry once.
  - `wrapsForNewDevices`: every epoch key held for the chat, for every live device of `userIds`.
  - `repairMissing`: `missingWraps()` → wrap held keys for verified devices → `putWraps`.
- `FakeChatBackend` (test support): in-memory family server + hub with the Task 1–3 rules (users, devices with real certs, chats, members, epochs, wraps coverage, messages, seq, idempotency, events). `FakeDevice addUser(String name)` returns a `TestDevice{LocalIdentity me, ChatApi api, FakeHubLink hub}`; `addDevice(userId)`; `FakeHubLink` implements `HubLink` (Task 6) with `connect()/drop()` and `bool dropNextAck`.

- [ ] **Step 1: Failing tests:** directory: `first identity is trusted`, `changed identity is flagged until acknowledged`, `device with a bad cert is not verified`. keys: `creator wraps for every member device and the other member unwraps`; `wrap from a non-member is rejected`; `wrap with a cert that does not chain is rejected`; `wrap moved to another device fails`; `ensureCurrentEpoch after a leave creates epoch 2 once` (two members race → one `createEpoch` wins, the other fetches the same key); `repair adds wraps for a member's new device`; `wrapsForNewDevices covers every held epoch`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(app): family directory with TOFU and chat key epochs`

### Task 6: Hub connection

**Files:** Create `app/lib/chat/hub_link.dart`, `app/test/chat/hub_connection_test.dart`.

**Interfaces (Produces):**
- `abstract interface class HubLink { Stream<Map<String,Object?>> get events; Stream<bool> get connection; bool get connected; bool send(Map<String,Object?> msg); Future<void> start(); Future<void> stop(); }`
- `class HubConnection implements HubLink { HubConnection({required Future<String> Function() ticket, required Uri apiBase, WebSocketChannel Function(Uri)? connect, List<Duration> backoff = const [1s,2s,4s,8s,16s,30s], Duration pingEvery = 25s, Duration pongTimeout = 10s, Random? random}); static Uri wsUri(Uri apiBase, String ticket); }` — `wss`/`ws` from `https`/`http`, path `/api/ws`, query `ticket`. Backoff index resets after a connection that stayed up ≥ 10 s; ±20 % jitter; a `SignedOutException` from `ticket` stops reconnecting. `connection` emits true on `ready` and false on close/error. Ping `{type:"ping"}` every `pingEvery`; no frame for `pongTimeout` after a ping → close and reconnect.

- [ ] **Step 1: Failing tests** (fake `StreamChannel` pairs via `StreamChannelController` wrapped as `WebSocketChannel`-like; use `fakeAsync`): `wsUri maps schemes`; `connects with a fresh ticket each time`; `reconnects with backoff after a drop`; `missing pong forces a reconnect`; `stop prevents reconnect`; `signed out stops reconnecting`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(app): hub WebSocket connection with ticket auth and backoff`

### Task 7: ChatSync engine

**Files:** Create `app/lib/chat/chat_sync.dart`, `app/test/chat/chat_sync_test.dart`.

**Interfaces (Produces):**
- `class ChatSync { ChatSync({required ChatDb db, required ChatApi api, required HubLink hub, required LocalIdentity me, Directory? directory, ChatKeys? keys}); Future<void> start(); Future<void> stop(); Future<void> syncAll(); Future<String> openDirect(String userId); Future<String> createGroup(String title, List<String> userIds); Future<String> sendText(String chatId, String text); Future<void> react(String chatId, String messageId, String emoji); Future<void> markRead(String chatId); void typing(String chatId); Future<void> addMembers(String chatId, List<String> userIds); Future<void> leave(String chatId); Future<void> removeMember(String chatId, String userId); Future<void> retry(String messageId); Stream<Set<String>> get online; Stream<Map<String, Set<String>>> get typingUsers; }`
- `syncAll` (runs on every connect, serialized): directory refresh → `chats()` upsert / delete absent → `keys.fetch()` → `ensureCurrentEpoch` for unready chats → per chat fetch `after=syncedSeq` in pages of 100 until short → retry undecryptable → `repairMissing` → flush outbox.
- Applying a `MessageDto`: dedupe by id (an own pending row gets its seq); seq ≤ `syncedSeq` ignored; seq > `syncedSeq+1` → fetch the gap first; decrypt (key by epoch; missing → one `keys.fetch(chatId)` then store `undecryptable` with the envelope); sender device must verify and belong to `senderUserId`; reactions store `targetId`.
- Outbox: `sendText` inserts a pending row (plaintext body) then flushes; flush encrypts each pending message under the current epoch with its stored id and sends `send`; `ack` → `ackMessage`; `error stale_epoch` → refresh the chat, `ensureCurrentEpoch`, resend; `not_member` → `failed`; `invalid_request`/`conflict` → `failed`. Pending rows resend on every reconnect.
- Events: `msg` apply; `chat` → `chat(id)` upsert (+ ensure epoch, fetch keys); `removed` → delete chat locally; `keys` → fetch + retry undecryptable; `read` → member `lastReadSeq` (own user → `myLastReadSeq`); `typing` → typing map entry expiring after 5 s; `hello`/`presence` → online set.
- `markRead`: newest seq in the chat > `myLastReadSeq` → set locally and send `read`. `typing` sends at most every 3 s per chat.
- `openDirect` returns an existing local direct chat with that user or creates one (server dedupes too); `addMembers` on a direct chat throws `ArgumentError` — the UI creates a new group instead.

- [ ] **Step 1: Failing tests** (two or three `TestDevice`s on one `FakeChatBackend`, real crypto, `NativeDatabase.memory()`): `text goes from Alice to Bob`; `Alice's second device sees her own message`; `outbox resend after reconnect does not duplicate` (`dropNextAck`, reconnect → one row with seq 1 on both sides); `offline send flushes on connect`; `a gap triggers a catch-up fetch`; `a message decrypts later when its key arrives`; `a message whose device is not the sender user's is rejected`; `reaction aggregates and can be removed`; `read receipt reaches the sender and clears the reader's unread on other devices`; `typing expires after 5 s` (fakeAsync); `presence follows connections`; `leave rotates and the rest keep talking` (Carol leaves → Alice's next send uses epoch 2; Carol's device cannot fetch epoch 2); `stale_epoch re-encrypts under the new epoch`; `removed member's send fails`; `added member reads history`; `openDirect twice returns the same chat`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(app): chat sync engine with outbox, receipts, typing and presence`

### Task 8: Providers, chat list and new chat

**Files:** Create `app/lib/chat/providers.dart`, `app/lib/screens/chats/chats_shell.dart`, `chat_list.dart`, `new_chat_screen.dart`, `app/test/screens/chat_list_test.dart`, `app/test/screens/new_chat_test.dart`; modify `app/lib/router.dart`, delete the "Chats coming soon" body in `home_screen.dart` (Home becomes `ChatsShell`), update `app/test/app_test.dart`/other tests that expect "Chats coming soon", `app/test/support/app_harness.dart` (override `chatDbProvider` with memory DB, `chatApiProvider`/`hubLinkProvider` with fakes).

**Interfaces (Produces):**
- Providers: `chatDbProvider` (`openChatDb()`, closed on dispose), `chatApiProvider` (`HttpChatApi(ref.watch(apiClientProvider))`), `hubLinkProvider` (`HubConnection` from `chatApiProvider.wsTicket`), `chatSyncProvider` (`ChatSync?`: built when `SignedIn`, `bindDevice` then `start()`; `stop()` on dispose/sign-out), `chatListProvider` (stream), `messagesProvider(chatId)`, `membersProvider(chatId)`, `usersProvider`, `onlineProvider`, `typingProvider(chatId)`.
- Routes: `/` (shell, list), `/chats/:id` (shell with conversation), `/chats/:id/info`, `/new`; `/devices`, `/invite`, `/spikes` unchanged.
- `ChatsShell({String? chatId})`: width ≥ 720 → list (360 px) | divider | conversation or "Select a chat"; narrower → list at `/`, conversation full screen at `/chats/:id`. App bar menu: New chat, Devices, Invite someone (admin), Platform spikes, Sign out.
- Chat list tile: avatar (initial; group icon), title (group title or other member's name), last message preview ("Photo"-free: text, or "Reacted 👍"), time, unread badge, presence dot for direct chats, identity-changed warning icon.
- `NewChatScreen({List<String> preselected = const []})`: checklist of family members (not me); one picked → "Chat" opens/creates the direct chat; two or more → title field (prefilled "A, B") and "Create group".

- [ ] **Step 1: Failing tests:** `chat list shows chats newest first with unread badges`; `tapping a chat opens it (narrow) / shows it beside the list (wide, 1000 px)`; `empty state offers New chat`; `menu still reaches Devices`; `picking one person opens a direct chat`; `picking two asks for a title and creates a group`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** full `flutter test` → PASS; `flutter analyze`.
- [ ] **Step 5: Commit** `feat(app): chat list, responsive shell and new chat`

### Task 9: Conversation and group info

**Files:** Create `app/lib/screens/chats/conversation_view.dart`, `message_bubble.dart`, `group_info_screen.dart`, `app/test/screens/conversation_test.dart`, `app/test/screens/group_info_test.dart`.

**Interfaces:** Consumes Task 8 providers and `ChatSync` methods.
- Conversation: header (title, presence "Online" for direct / member count for groups, info button); identity-changed banner "<Name>'s security key changed. This happens after an account reset." + "OK" (`acknowledgeIdentity`); message list (reverse `ListView`, own bubbles right/primary container, others left with sender name in groups, time, pending clock / failed "Tap to retry"), reactions row under the bubble (emoji + count, own highlighted, tap toggles), long-press (touch) or hover button (desktop/web) → emoji picker `👍 ❤️ 😂 😮 😢 🙏`; "Seen" under my latest sent message when every other member's `lastReadSeq` ≥ its seq (groups: "Seen by N" for partial); typing line "<Name> is typing…"; composer (multiline, Enter sends on desktop/web, Shift+Enter newline; send button); calls `markRead` when shown and when new messages arrive.
- Group info: title, member list with presence dots, "Add people" (group → picker → `addMembers`; direct → `NewChatScreen(preselected: [other])` creating a new group), "Leave group" (confirm), creator sees "Remove" per member (confirm).

- [ ] **Step 1: Failing tests:** `sending shows the message pending then sent`; `incoming message appears and is marked read`; `long-press reacts and the count shows`; `Seen appears once the other member read it`; `typing indicator shows the other member`; `identity change banner can be acknowledged`; group info: `members listed and creator can remove`; `leave returns to the list`; `adding from a 1:1 opens new group with that person preselected`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** full `flutter test`, `flutter analyze`, `flutter test --platform chrome test/crypto/` → pass.
- [ ] **Step 5: Commit** `feat(app): conversation view, reactions, receipts and group info`

### Task 10: Finish

- [ ] Whole-branch review by a fresh Opus reviewer; fix Critical/Important with a failing test first.
- [ ] `git fetch && git rebase origin/main` (keep plan 12's `assets` block and `main.dart` changes alongside ours); full server and app suites.
- [ ] Push `plan5-chats`, open the PR, watch CI (`app`, `server`) to green.
