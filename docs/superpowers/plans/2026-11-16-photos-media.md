# Photos & Media Quota Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Family members send end-to-end-encrypted photos (compressed, with a thumbnail) that upload with progress and retry through the outbox, open full screen, and expire gracefully when the family's 8 GB media cap evicts them; admins see usage.

**Architecture:** Server: an R2 bucket (`MEDIA`) holds only ciphertext; a D1 `media` table with triggers keeps a running total in `media_usage`; `POST /api/media` streams a body into R2 under a client-chosen ULID key, and when the total passes 8 GiB the FamilyHub (single-threaded, so evictions never race) expires the oldest objects until below 7.5 GiB and sends `media_expired` to each affected chat's members. Client: `lib/crypto/media.dart` encrypts each blob with a fresh key (XChaCha20-Poly1305, single-shot); `lib/media/` holds a separate drift database (decrypted LRU cache, pending upload blobs, expired keys), `MediaApi` over HTTP, a `PhotoProcessor` (platform decode + `image` JPEG encode) and `MediaService`, which plugs into `ChatSync`'s outbox through one `beforeSend` gate so photo messages are only sent after their blobs are uploaded.

**Tech Stack:** Cloudflare Workers + Hono, R2, D1 (triggers), FamilyHub DO RPC, vitest + `@cloudflare/vitest-plugin`. Flutter 3.50, Riverpod 3, drift, `cryptography`, `image_picker` 1.2 (all six platforms; desktop implementations use `file_selector`), `image` 4.x.

**Spec:** `docs/superpowers/specs/2026-11-15-famchat-design.md` ("Media", "Media storage cap", "API surface", "D1 schema"). Roadmap row 7. Wire contract extends `docs/protocol.md`.

## Global Constraints

- Errors stay `{error: code}`. New codes: `too_large` 413, `media_expired` 410, `conflict` 409.
- Photos: max 2048 px on the long side, JPEG; thumbnail max 320 px JPEG; HEIC→JPEG (platform decoders); re-encoding strips EXIF (location).
- Per-file byte caps (ciphertext): `photo` 15 MiB, `thumb` 1 MiB, `voice` 8 MiB (10 min of 48 kbps AAC ≈ 3.6 MB; duration is checked by the client).
- Cap 8 GiB (`8 * 2**30`), evict to below 7.5 GiB (`7.5 * 2**30`), oldest first, a message's blobs (same `message_id`) together.
- Blob format: `nonce(24) ‖ ct ‖ mac(16)`, XChaCha20-Poly1305, AAD = `"famchat-media-v1" ‖ str(purpose)` with purpose `"file"` or `"thumb"`. The domain string is not a prefix of any existing one (`famchat-envelope-v1`, `famchat-wrap-v1`, `famchat-sealed-box-v1`, `famchat-device-cert-v1`) nor vice versa.
- `sha256` fields are SHA-256 of the **ciphertext blob** (the exact R2 object), b64url. The signed envelope pins the blob, which also closes the non-key-committing AEAD gap for media.
- Plaintext `photo` kind: `{"kind":"photo","mediaKey","thumbKey","key","sha256","thumbSha256","width","height","bytes","mime":"image/jpeg"}`; `key` b64url 32 bytes; `bytes` = plaintext JPEG size of the full image.
- `lib/crypto/` stays Flutter-free; `lib/media/` is Flutter-free except `photo_processor.dart` and `providers.dart`; no `dart:io` under `lib/`.
- Plan 6 edits `hub.ts`, `chat_sync.dart` and the chat DB in parallel: keep edits there to small additive hooks; media state lives in its own drift DB (`famchat_media`) so the chat DB schema doesn't change.
- Vitest `maxWorkers` ≤ 2; one build/test process at a time.

## Review Focus

1. **Lost upload response / app restart mid-upload:** re-POSTing the same key from the same device with the same size → 200, no double-counting; pending blobs survive restart in the media DB and resume on the next flush. Server test `re-upload of the same key is idempotent`; client test `upload resumes after a network failure and the message is sent once`.
2. **Tampered or swapped blob:** server returns another blob, a truncated blob, or the thumb in place of the full → hash mismatch, nothing cached, error state (not a crash, not wrong pixels). Crypto test `thumb blob does not open as file`; client test `a blob whose hash differs is rejected`.
3. **Expired while offline:** a device that missed the `media_expired` event downloads and gets 410 → the bubble shows "Photo expired" and remembers it. Client test `410 marks the media expired`.
4. **Non-member download / upload into someone else's chat** → 404, never the object. Server tests `non-member cannot download`, `upload to a chat I'm not in → 404`.
5. **Oversized / missing length / huge declared length** → 413 / 400 before R2 is touched; usage unchanged. Server tests `photo over 15 MiB → too_large`, `missing content-length → invalid_request`.

---

## Server contract

| Route | Rules |
|---|---|
| `POST /media?chatId&key&kind&messageId?` | Authed. Body raw bytes, `Content-Length` required (else 400), `0 < len ≤ cap(kind)` (else 413 `too_large`); `kind ∈ photo|thumb|voice`, `key`/`chatId`/`messageId` ULIDs (else 400). Caller member of chat (else 404). Key exists: same uploader device + chat + bytes and not expired → `200 {key, bytes}`; otherwise 409 `conflict`. Body piped through `FixedLengthStream(len)` into `MEDIA.put(key)`; then `INSERT media` (trigger adds to usage). Usage > cap → `hub.evictMedia()`. → `201 {key, bytes}`. |
| `GET /media/:key` | Authed. Row missing or caller not a member of its chat → 404; `expired_at` set or object gone → 410 `media_expired`. Streams the object: `content-type: application/octet-stream`, `content-length`, `cache-control: private, no-store`. |
| `GET /admin/usage` | Admin. `{usedBytes, capBytes, evictToBytes, files, expiredFiles}` (files/expiredFiles count rows). |
| Hub event | `{type:"media_expired", chatId, keys:[...]}` to that chat's current members after an eviction. |

---

### Task 1: Media crypto helper

**Files:** Create `app/lib/crypto/media.dart`, `app/test/crypto/media_test.dart`; modify `app/tool/gen_crypto_vectors.dart`, `app/test/crypto/vector_inputs.dart`, `app/test/crypto/vectors_v1.dart` (regenerated), `app/test/crypto/vectors_test.dart`.

**Interfaces (Produces):**
- `enum MediaPurpose { file, thumb }` (AAD string = `name`).
- `Uint8List newMediaKey()` (32 random bytes).
- `Uint8List mediaAad(MediaPurpose p)`.
- `Future<Uint8List> encryptMedia({required List<int> key, required List<int> plaintext, required MediaPurpose purpose, @visibleForTesting List<int>? nonce})`.
- `Future<Uint8List> decryptMedia({required List<int> key, required List<int> blob, required MediaPurpose purpose})` — throws `CryptoFailure`.
- `Future<Uint8List> sha256Of(List<int> bytes)`; `Future<bool> sha256Matches(List<int> bytes, List<int> expected)` (constant-time compare).
- `const maxMediaBlobBytes = 16 * 1024 * 1024` (encrypt/decrypt refuse more).

- [ ] **Step 1: Failing tests:** `round-trips file and thumb`; `wrong key fails`; `flipped byte in nonce/ct/mac fails`; `thumb blob does not open as file`; `truncated blob fails` (< 40 bytes); `aad domain is not a prefix of another domain` (all five domain strings pairwise); `sha256Matches detects a change`; vectors test `media vector` (fixed key 32×0x11, nonce 24×0x09, plaintext "famchat photo", purpose file → pinned b64url; and its sha256).
- [ ] **Step 2:** `flutter test test/crypto/media_test.dart test/crypto/vectors_test.dart` → FAIL.
- [ ] **Step 3: Implement**; add the vector to the generator, regenerate `vectors_v1.dart`, check the existing vectors are byte-identical; cross-check the blob once with an independent XChaCha (Node HChaCha20 + `chacha20-poly1305`).
- [ ] **Step 4:** run → PASS, plus `flutter test --platform chrome test/crypto/media_test.dart`.
- [ ] **Step 5: Commit** `feat(crypto): media blob encryption with fixed vector`

### Task 2: Server storage, upload, download, quota

**Files:** Create `server/migrations/0005_media.sql`, `server/src/lib/media.ts`, `server/src/routes/media.ts`, `server/test/media.test.ts`, `server/test/media-helpers.ts`; modify `server/wrangler.jsonc` (`r2_buckets: [{binding:"MEDIA", bucket_name:"famchat-media"}]`), `server/src/env.ts` (`MEDIA: R2Bucket`), `server/src/index.ts` (mount `/media`), `server/src/lib/errors.ts`, `server/src/hub.ts` (`evictMedia` RPC), `server/src/routes/admin.ts` (`GET /usage`), `server/test/helpers.ts` (`resetDb` clears media + resets usage, empties the bucket), `docs/protocol.md`, spec "API surface" (`/admin/usage`).

**Interfaces (Produces):**
- Tables: `media(key PK, uploader_id, uploader_device_id, chat_id, message_id NULL, kind CHECK IN ('photo','thumb','voice'), bytes INT, created_at, expired_at NULL)`, index `(expired_at, created_at)`; `media_usage(id=1 PK, bytes)` seeded `(1,0)`; triggers `media_usage_ins` (AFTER INSERT: `+ NEW.bytes`) and `media_usage_exp` (AFTER UPDATE OF expired_at WHEN OLD IS NULL AND NEW NOT NULL: `- NEW.bytes`).
- `lib/media.ts`: `MEDIA_CAP = 8 * 2**30`, `MEDIA_TARGET = 7.5 * 2**30`, `KIND_LIMITS = {photo: 15 MiB, thumb: 1 MiB, voice: 8 MiB}`, `mediaUsage(db): Promise<number>`, `evictOldest(env, notify: (userIds, event) => Promise<void>, cap = MEDIA_CAP, target = MEDIA_TARGET): Promise<string[]>` (pages oldest live rows 500 at a time, takes rows until `usage − freed < target`, then adds live siblings with the same `message_id`; marks `expired_at` in chunks of ≤ 90 keys; deletes R2 objects in chunks of ≤ 1000; notifies each chat's current members `{type:"media_expired", chatId, keys}`; returns expired keys).
- `FamilyHub.evictMedia(): Promise<number>` — serialized on its own promise chain; re-checks usage > cap inside.

- [ ] **Step 1: Failing tests** (`media.test.ts`; bytes via `crypto.getRandomValues`): `uploads and downloads the same bytes` (201, row, usage += len, GET returns identical bytes, octet-stream, no-store); `re-upload of the same key is idempotent` (200, usage counted once); `same key from another device → conflict`; `upload to a chat I'm not in → 404`; `non-member cannot download` (404); `unknown key → 404`; `bad kind / key / chatId → 400`; `missing content-length → invalid_request` (ReadableStream body); `photo over 15 MiB → too_large` (usage unchanged, nothing in R2); `thumb over 1 MiB → too_large`; `voice up to 8 MiB accepted`; `passing 8 GiB evicts oldest to below 7.5 GiB` (insert rows directly: 9 × 0.9 GiB fake rows with tiny R2 objects, two sharing a message id across the cut; upload 10 bytes → oldest expired, `expired_at` set, objects deleted, usage < 7.5 GiB, siblings both expired, newest kept); `expired media → 410 media_expired`; `eviction notifies chat members over the hub` (open sockets as in `hub.test.ts`; member gets `media_expired` with the keys, non-member doesn't); `usage total matches the sum of live rows`; admin: `usage for admins` (`capBytes 8589934592`, `evictToBytes 8053063680`), `usage forbidden for members` (403).
- [ ] **Step 2:** `cd server && npx vitest run test/media.test.ts` → FAIL.
- [ ] **Step 3: Implement.** Extract the WebSocket test client from `hub.test.ts` into `test/ws-client.ts` only if needed to share; otherwise duplicate the minimal `connect` helper in `media-helpers.ts`.
- [ ] **Step 4:** `npm test && npm run typecheck` → pass.
- [ ] **Step 5: Commit** `feat(server): encrypted media upload/download on R2 with 8 GB quota eviction`

### Task 3: Client media layer (API, store, service, photo kind, outbox gate)

**Files:** Create `app/lib/media/media_api.dart`, `app/lib/media/http_media_api.dart`, `app/lib/media/media_db.dart` (+ `.g.dart`), `app/lib/media/media_service.dart`, `app/test/media/media_service_test.dart`, `app/test/media/http_media_api_test.dart`, `app/test/support/fake_media.dart`; modify `app/lib/chat/plaintext.dart` (`PhotoBody`), `app/lib/chat/chat_sync.dart` (hook only), `app/lib/api/api_client.dart` (`authedUpload`, `authedBytes`), `app/test/support/fake_chat_backend.dart` (`media_expired` delivery helper), `app/test/chat/wire_test.dart` (plaintext cases).

**Interfaces (Produces):**
- `PhotoBody extends Plaintext {mediaKey, thumbKey, key (Uint8List), sha256, thumbSha256 (Uint8List), width, height, bytes, mime}`; `Plaintext.decode` validates ULID-ish non-empty keys, 32-byte key/hashes, positive ints, else `FormatException`. `ChatSync` stores it as kind `photo`.
- `ChatSync`: `Future<bool> Function(MessageRow row)? beforeSend` (set by MediaService; false = not yet, row stays pending); `Future<String> enqueueMessage(String chatId, Plaintext p, {String? id})` (public form of `_enqueueMessage`); `void flushSoon()` (queues `_flushOutbox`); `Future<void> markFailed(String id)`.
- `abstract interface class MediaApi { Future<void> upload({required String key, required String chatId, required String kind, String? messageId, required Uint8List bytes, void Function(int sent, int total)? onProgress}); Future<Uint8List> download(String key); Future<MediaUsage> usage(); }`; `MediaUsage{usedBytes, capBytes, evictToBytes, files, expiredFiles}`; `HttpMediaApi(ApiClient)`; `ApiClient.authedUpload(path, {query, bytes, onProgress, timeout})` (StreamedRequest, 64 KiB chunks, content-length set; timeout `30 s + 1 s per 50 kB`) and `ApiClient.authedBytes(path)`.
- `MediaDb` (drift, `openMediaDb()` name `famchat_media`): `CachedMedia(key PK, bytes BLOB, size, lastUsed)`, `PendingUploads(key PK, messageId, chatId, kind, blob BLOB)`, `ExpiredMedia(key PK)`, `MediaMeta(key PK, value)`; `bindDevice`, `wipe`, `cacheGet(key)` (touches lastUsed), `cachePut(key, bytes, {maxBytes})` (evicts LRU until total ≤ maxBytes), `uploadsFor(messageId)`, `putUpload`, `deleteUpload`, `markExpired(keys)`, `isExpired(key)`, `watchExpired()`.
- `class MediaRef { key, Uint8List fileKey, sha256; MediaPurpose purpose }`.
- `class MediaService { MediaService({db, api, sync, PhotoProcessor processor, int cacheBytes, List<Duration> retryDelays}); Future<void> start(); Future<void> stop(); Future<String> sendPhoto(String chatId, Uint8List original); Stream<double> progress(String messageId); double? progressNow(String messageId); Future<Uint8List?> load(MediaRef ref); Stream<Set<String>> get expired; }`
  - `sendPhoto`: process → `newMediaKey()` → encrypt thumb (`thumb`) and full (`file`) → hashes → `cachePut` plaintexts under their keys → `putUpload` both ciphertexts with the new message id → `sync.enqueueMessage(chatId, PhotoBody, id:)`.
  - `beforeSend(row)`: kind other than photo or no pending uploads → true; else start (once per message) a background upload of each blob in order (thumb first), reporting combined progress, then `deleteUpload` and `sync.flushSoon()`; `ApiException` 4xx (not 408/429) → `sync.markFailed`; network/5xx → retry after `retryDelays` (last repeats) while not stopped; returns false.
  - `load(ref)`: expired → null; cache hit → bytes; else de-duplicated in-flight download → `sha256Matches` (mismatch → throws `CryptoFailure`) → `decryptMedia` → `cachePut` → bytes; `ApiException(410)` → `markExpired`, null.
  - Listens to `sync.hub.events` for `media_expired` → `markExpired(keys)` and drops those keys from the cache.
  - `start` drops pending uploads whose message is gone or no longer pending.
- `PhotoProcessor` interface (Task 4 implements): `Future<ProcessedPhoto> process(Uint8List original)`; `ProcessedPhoto{Uint8List full, thumb; int width, height}`; throws `UnsupportedImageException`.
- `FakeMediaApi` (test support): in-memory blobs with the server's rules (limits, idempotency, membership via `FakeChatBackend`, `expire(keys)` that also delivers `media_expired` to members), `failNextUploads`, `uploads` log, `tamper(key, bytes)`.

- [ ] **Step 1: Failing tests:** plaintext: `photo round-trips`, `photo with a short key is rejected`. service (two `TestDevice`s, `FakeMediaApi`, `FakeProcessor`): `photo goes from Alice to Bob and decrypts with a matching hash`; `the message is sent only after both blobs uploaded` (no `send` frame before uploads complete); `progress reaches 1`; `upload resumes after a network failure and the message is sent once`; `a 413 marks the message failed and retry re-uploads`; `a blob whose hash differs is rejected` (nothing cached); `410 marks the media expired`; `media_expired event marks keys expired and drops the cache`; `cache evicts least recently used beyond the limit`; `concurrent loads download once`; `start drops uploads whose message is gone`. http: `upload sends query, octet-stream body and content-length; 413 → ApiException(413,'too_large')`; `download returns bytes; 410 → ApiException(410,'media_expired')`.
- [ ] **Step 2:** `flutter test test/media/ test/chat/wire_test.dart` → FAIL.
- [ ] **Step 3: Implement** (`dart run build_runner build` for `media_db.g.dart`).
- [ ] **Step 4:** run those plus `test/chat/` → PASS; `flutter analyze` clean.
- [ ] **Step 5: Commit** `feat(app): encrypted media pipeline with upload outbox, verified downloads and cache`

### Task 4: Photo processing, picking, bubble, viewer, admin storage screen

**Files:** Create `app/lib/media/photo_processor.dart`, `app/lib/media/providers.dart`, `app/lib/screens/chats/photo_view.dart` (thumbnail widget + full-screen viewer), `app/lib/screens/storage_screen.dart`, `app/test/media/photo_processor_test.dart`, `app/test/screens/photo_bubble_test.dart`, `app/test/screens/storage_screen_test.dart`; modify `pubspec.yaml` (`image_picker`, `image`), `message_bubble.dart`, `conversation_view.dart` (attach button), `chat_list.dart` (preview "📷 Photo"), `chats_shell.dart` (admin "Storage" menu), `router.dart` (`/storage`, admin only), `test/support/chat_harness.dart` (media overrides), iOS `Info.plist` (`NSPhotoLibraryUsageDescription`, `NSCameraUsageDescription`), macOS `DebugProfile/Release.entitlements` (`com.apple.security.files.user-selected.read-only`).

**Interfaces (Produces):**
- `class PlatformPhotoProcessor implements PhotoProcessor` — reads dimensions with `ui.ImageDescriptor`, decodes at the target size with `instantiateCodec(targetWidth/targetHeight)` (platform codecs: JPEG/PNG/WebP/GIF/HEIC where the OS decodes it), `toByteData(rawRgba)`, JPEG-encodes with `image` (`quality 85` full, `75` thumb) in `Isolate.run` off the web, inline on the web. Never upscales.
- Providers: `mediaDbProvider`, `mediaApiProvider`, `photoProcessorProvider`, `mediaServiceProvider` (`MediaService?`, built with `chatSyncProvider`), `mediaBytesProvider` (`FutureProvider.family<Uint8List?, MediaRef>`), `uploadProgressProvider(messageId)`, `expiredMediaProvider`, `mediaUsageProvider`.
- `PhotoThumb({PhotoBody body, String messageId, bool mine, VoidCallback onOpen})` — box sized from width/height (max 260 × 320), states: loading, image, uploading (progress ring over the image), expired (`Key('media-expired')`, "Photo expired"), error ("Couldn't load photo", tap retries).
- `PhotoViewer({PhotoBody body})` — black full-screen route, `InteractiveViewer`, close button, loads the full image (thumb shown blurred meanwhile).
- `StorageScreen` — "Media storage", `LinearProgressIndicator(usedBytes / capBytes)`, "X.X GB of 8.0 GB used", file count, the eviction sentence.

- [ ] **Step 1: Failing tests:** processor (`tester.runAsync`): `a 3000×1000 PNG becomes a 2048×683 JPEG and a 320×107 thumb`; `a small image is not upscaled`; `garbage bytes throw UnsupportedImageException`. widget: `own photo shows its thumbnail and upload progress`; `incoming photo thumbnail opens the viewer with the full image`; `expired photo shows Photo expired`; `chat list previews a photo`; `admin opens Storage and sees usage`; `members don't see Storage`.
- [ ] **Step 2:** run → FAIL. **Step 3: Implement.** **Step 4:** full `flutter test`, `flutter analyze` → pass.
- [ ] **Step 5: Commit** `feat(app): photo picking, compression, photo bubble, viewer and admin storage screen`

### Task 5: Finish

- [ ] Create the R2 bucket `famchat-media` (if absent).
- [ ] Whole-branch review by a fresh Opus reviewer; fix Critical/Important with a failing test first.
- [ ] `git fetch && git merge origin/main`; full server and app suites; `flutter build web --release` once.
- [ ] Push `plan7-media`, open the PR, watch CI to green.
