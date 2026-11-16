# Crypto Core (Dart) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A tested Dart crypto library in `app/lib/crypto/`: device keys, device certificates, sealed boxes, signed chat-key wraps and message envelopes, pinned by fixed test vectors, replacing the plan 2 spike code.

**Architecture:** Small files, one format each, on top of `package:cryptography` (Ed25519, X25519, XChaCha20-Poly1305, HKDF-SHA256). Every signed or authenticated byte string is built with one `ByteWriter` that starts with a fixed domain string and length-prefixes every variable field. Every verify or decrypt failure throws one exception type, `CryptoFailure`. Callers (plans 4–6) decide whose keys to trust; this library only checks signatures against the keys it is given.

**Tech Stack:** Dart / Flutter 3.50, `cryptography ^2.9.0`, `cryptography_flutter ^2.3.4`, `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-11-15-famchat-design.md` (sections "End-to-end encryption" and "Testing"). Roadmap row 3. Plan 2 review follow-ups: `docs/spikes/2026-11-platform-spikes.md`, "Follow-ups".

## Global Constraints

- All code lives in `app/lib/crypto/`, tests in `app/test/crypto/`. Nothing in `lib/crypto/` imports Flutter (pure Dart, so it runs in `flutter test` on the VM and with `--platform chrome`).
- Binary values on the wire are **base64url without padding**. Public keys and seeds are exactly 32 bytes, signatures exactly 64, chat keys exactly 32, XChaCha20 nonces exactly 24.
- Device certificate message is unchanged from plan 1, byte for byte: UTF-8 `"famchat-device-cert-v1"` ‖ `encPub` (32) ‖ `signPub` (32), signed with Ed25519 by `identityPub`. `server/test/fixtures/dart-device-cert.json` must still verify.
- Sealed-box format is unchanged from the spike: `ephPub(32) ‖ nonce(24) ‖ ciphertext ‖ mac(16)`; key = HKDF-SHA256(X25519(eph, recipient), salt = ephPub ‖ recipientPub, info = `"famchat-sealed-box-v1"`, 32 bytes).
- Field encoding inside signed/AAD byte strings: a domain string as raw UTF-8 (no length), then fields in order; strings are `u16 big-endian length ‖ UTF-8`, integers are `u32 big-endian` (or `u8` for `v`), byte fields are raw (fixed-length) or last.
- Every failure to verify, open, decrypt or parse throws `CryptoFailure` (never `TypeError`, `FormatException` or a `cryptography` error).
- Tests: `cd app && flutter test`, and `flutter test --platform chrome test/crypto/` must pass too (CI runs it). Tests that read files carry `testOn: 'vm'`.

## Review Focus

1. **A valid wrap replayed into a different chat, epoch or recipient device** (a server moving rows around) → `unwrapChatKey` throws `CryptoFailure`. Task 4 test `wrap moved to another chat, epoch or device is rejected`.
2. **An envelope whose `epoch` or `v` the server changed** → `decryptEnvelope` throws `CryptoFailure`, even when the reader holds a valid key for the new epoch. Task 5 test `changed epoch is rejected`.
3. **Malformed envelope or wrap JSON** (missing field, wrong type, bad base64, ciphertext shorter than the MAC, wrong-length nonce) → `CryptoFailure`, not a crash. Task 5 test `malformed envelope json throws CryptoFailure`, Task 4 test `malformed wrap json throws CryptoFailure`.
4. **An all-zero or low-order X25519 public key** → `sealBox` throws `CryptoFailure` instead of sealing to a key everyone can derive. Task 3 test `low-order recipient key is refused`.
5. **App restart:** device keys saved and restored from storage give the same public keys and still open old wraps. Task 1 test `device keys round-trip through storage`.

---

## File Structure

| File | Responsibility |
|---|---|
| `app/lib/crypto/encoding.dart` | `b64url`, `b64urlDecode`, `ByteWriter`, `CryptoFailure` |
| `app/lib/crypto/keys.dart` | Identity and device key generation, seed storage, chat-key generation |
| `app/lib/crypto/device_cert.dart` | `DeviceCert`, sign and verify |
| `app/lib/crypto/sealed_box.dart` | `sealBox`, `openBox` |
| `app/lib/crypto/wrap.dart` | `ChatKeyWrap`, `wrapChatKey`, `unwrapChatKey` |
| `app/lib/crypto/envelope.dart` | `Envelope`, `encryptEnvelope`, `decryptEnvelope` |
| `app/tool/gen_crypto_vectors.dart` | Writes `app/test/crypto/vectors_v1.dart` from fixed seeds and nonces |
| `app/test/crypto/*_test.dart` | One test file per lib file, plus `vectors_test.dart` |
| Removed | `app/lib/spikes/crypto_spike.dart`, `app/test/crypto_spike_test.dart` (callers move to `lib/crypto/`) |

---

### Task 1: Spec formats, encoding helpers and keys

**Files:**
- Modify: `docs/superpowers/specs/2026-11-15-famchat-design.md` ("Keys", "Messages", "Known limits")
- Create: `app/lib/crypto/encoding.dart`, `app/lib/crypto/keys.dart`
- Test: `app/test/crypto/encoding_test.dart`, `app/test/crypto/keys_test.dart`

**Interfaces:**
- Produces:
  - `class CryptoFailure implements Exception { const CryptoFailure(this.reason); final String reason; }`
  - `String b64url(List<int> bytes)`; `Uint8List b64urlDecode(String s)` — throws `CryptoFailure('bad base64')` on invalid input.
  - `class ByteWriter { ByteWriter(String domain); void str(String s); void u8(int v); void u32(int v); void bytes(List<int> b); Uint8List finish(); }` — `str` throws `ArgumentError` above 65 535 UTF-8 bytes; `u32` throws `ArgumentError` outside 0..2³²−1.
  - `Future<SimpleKeyPair> newIdentityKey({List<int>? seed})` (Ed25519)
  - `class DeviceKeys { final SimpleKeyPair enc /*X25519*/, sign /*Ed25519*/; static Future<DeviceKeys> generate(); Future<Map<String, String>> toStorage() /* {'encSeed','signSeed'} b64url */; static Future<DeviceKeys> fromStorage(Map<String, String> m); Future<Uint8List> encPub(); Future<Uint8List> signPub(); }`
  - `Future<Uint8List> publicKeyOf(SimpleKeyPair k)`; `Future<Uint8List> seedOf(SimpleKeyPair k)`
  - `Uint8List newChatKey()` — 32 bytes from `Random.secure()`.

- [ ] **Step 1: Update the spec.** Under "Keys", after the chat-key bullet, add: each wrap is signed by the wrapping device's sign key over `"famchat-wrap-v1" ‖ str(chatId) ‖ u32(epoch) ‖ str(recipientDeviceId) ‖ str(wrapperDeviceId) ‖ sealed`; a device accepts a wrap only if that signature verifies with the sign key of a device whose certificate chains to a current chat member's identity key. Replace the "Messages" block with:
  ```
  envelope = { v:1, epoch, nonce, ct, sig }
  aad = "famchat-envelope-v1" ‖ u8(v) ‖ str(chatId) ‖ u32(epoch) ‖ str(messageId) ‖ str(senderDeviceId)
  ct  = XChaCha20-Poly1305(chatKey[epoch], nonce, plaintext, aad)      (ct includes the 16-byte MAC)
  sig = Ed25519(deviceSignKey, aad ‖ nonce ‖ ct)
  str(s) = u16be(len) ‖ UTF-8(s); integers big-endian
  ```
  Add to "Known limits": XChaCha20-Poly1305 is not key-committing; a malicious member who wraps different keys for one epoch to different devices could show them different text. Accepted for one family; revisit if membership widens.
- [ ] **Step 2: Write failing tests.** `encoding_test.dart`: `b64url round-trips and drops padding` (`b64url([0xff]) == '_w'`, decode back); `bad base64 throws CryptoFailure` (`b64urlDecode('*')`); `ByteWriter layout` (`(ByteWriter('d')..str('ab')..u32(1)..u8(2)..bytes([9])).finish()` equals `[0x64, 0,2, 0x61,0x62, 0,0,0,1, 2, 9]`); `str length prefix rejects >65535 bytes`. `keys_test.dart`: `device keys round-trip through storage` (generate, `toStorage`, `fromStorage`, same `encPub`/`signPub`; Task 3 extends it to open a box with the restored keys); `seeded identity key is deterministic` (`newIdentityKey(seed: List.filled(32,1))` public key == fixture `identityPub` `iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w`); `newChatKey is 32 random bytes` (two calls differ, length 32).
- [ ] **Step 3: Run, expect FAIL** — `cd app && flutter test test/crypto/` → compile errors (files missing).
- [ ] **Step 4: Implement `encoding.dart` and `keys.dart`.** Seeds via `extractPrivateKeyBytes()`; restore via `newKeyPairFromSeed`.
- [ ] **Step 5: Run, expect PASS** — `flutter test test/crypto/` and `flutter test --platform chrome test/crypto/`.
- [ ] **Step 6: Commit** — `git add docs/superpowers/specs app/lib/crypto app/test/crypto && git commit -m "feat(crypto): encoding helpers, device keys; spec: signed wraps and envelope bytes"`

### Task 2: Device certificates

**Files:**
- Create: `app/lib/crypto/device_cert.dart`
- Modify: `app/tool/gen_cert_fixture.dart` (use `signDeviceCert`)
- Test: `app/test/crypto/device_cert_test.dart`

**Interfaces:**
- Consumes: `ByteWriter` is **not** used here (the cert layout predates it and must stay byte-identical); `DeviceKeys`, `b64url`, `b64urlDecode`, `CryptoFailure`.
- Produces:
  - `class DeviceCert { final Uint8List identityPub, encPub, signPub, certSig; Map<String, String> toJson() /* keys identityPub, encPub, signPub, certSig — same names the server API uses */; factory DeviceCert.fromJson(Map<String, Object?> j) /* CryptoFailure on missing/bad fields or wrong lengths */ }`
  - `Uint8List deviceCertMessage(List<int> encPub, List<int> signPub)`
  - `Future<DeviceCert> signDeviceCert({required SimpleKeyPair identity, required DeviceKeys device})`
  - `Future<bool> verifyDeviceCert(DeviceCert c)` — never throws.

- [ ] **Step 1: Write failing tests:** `cert message layout` (86 bytes, prefix, encPub, signPub — port from `test/crypto_spike_test.dart`); `cert verifies`; `cert from another identity fails`; `swapped enc and sign keys fail`; `wrong-length fields fail fromJson with CryptoFailure`; `cert matches the server fixture` (seeds 1/2/3, compare `toJson()` with `../server/test/fixtures/dart-device-cert.json`; `testOn: 'vm'`).
- [ ] **Step 2: Run, expect FAIL** (missing file).
- [ ] **Step 3: Implement `device_cert.dart`; point `tool/gen_cert_fixture.dart` at `signDeviceCert`.**
- [ ] **Step 4: Run, expect PASS**, then `cd app && dart run tool/gen_cert_fixture.dart && git diff --exit-code ../server/test/fixtures/` → no diff, and `cd server && npx vitest run --maxWorkers=2` → all pass.
- [ ] **Step 5: Commit** — `feat(crypto): device certificates`

### Task 3: Sealed box

**Files:**
- Create: `app/lib/crypto/sealed_box.dart`
- Test: `app/test/crypto/sealed_box_test.dart`; extend `keys_test.dart` round-trip to open a box with restored keys

**Interfaces:**
- Produces:
  - `Future<Uint8List> sealBox(List<int> recipientPub, List<int> plaintext, {@visibleForTesting SimpleKeyPair? ephemeral, @visibleForTesting List<int>? nonce})`
  - `Future<Uint8List> openBox(SimpleKeyPair recipient, List<int> sealed)` — `CryptoFailure` on short input, bad MAC, low-order sender key.

- [ ] **Step 1: Write failing tests:** `seal then open round-trips`; `every flipped byte fails with CryptoFailure` (each byte of a sealed box, `throwsA(isA<CryptoFailure>())`); `wrong recipient fails`; `low-order recipient key is refused` (all-zero 32 bytes and the order-8 point `e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800` → `sealBox` throws `CryptoFailure`); `fixed ephemeral and nonce give fixed output` (two calls with the same injected values are equal); `wrong-length recipient key is refused`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** After X25519, reject an all-zero shared secret with `CryptoFailure('low-order key')` (on seal and open). Wrap `SecretBoxAuthenticationError` in `CryptoFailure`.
- [ ] **Step 4: Run, expect PASS** (VM and `--platform chrome test/crypto/`).
- [ ] **Step 5: Commit** — `feat(crypto): sealed box with low-order key check`

### Task 4: Signed chat-key wraps

**Files:**
- Create: `app/lib/crypto/wrap.dart`
- Test: `app/test/crypto/wrap_test.dart`

**Interfaces:**
- Consumes: `sealBox`, `openBox`, `ByteWriter`, `DeviceKeys`, `CryptoFailure`, `b64url`.
- Produces:
  - `class ChatKeyWrap { final String chatId; final int epoch; final String recipientDeviceId, wrapperDeviceId; final Uint8List sealed, sig; Map<String, Object> toJson() /* sealed, sig as b64url; epoch as int */; factory ChatKeyWrap.fromJson(Map<String, Object?> j) /* CryptoFailure on bad input */ }`
  - `Uint8List wrapSignedBytes(String chatId, int epoch, String recipientDeviceId, String wrapperDeviceId, List<int> sealed)` — `ByteWriter('famchat-wrap-v1')..str(chatId)..u32(epoch)..str(recipientDeviceId)..str(wrapperDeviceId)..bytes(sealed)`.
  - `Future<ChatKeyWrap> wrapChatKey({required List<int> chatKey, required String chatId, required int epoch, required String recipientDeviceId, required List<int> recipientEncPub, required String wrapperDeviceId, required SimpleKeyPair wrapperSignKey})`
  - `Future<Uint8List> unwrapChatKey({required ChatKeyWrap wrap, required String chatId, required int epoch, required String myDeviceId, required DeviceKeys me, required List<int> wrapperSignPub})` — checks `wrap.chatId/epoch/recipientDeviceId` equal the expected values, verifies `sig` with `wrapperSignPub` **before** opening, requires a 32-byte result. Doc comment: the caller must have checked that `wrapperSignPub` comes from a verified cert of a current chat member.

- [ ] **Step 1: Write failing tests:** `wrap then unwrap returns the chat key`; `wrap moved to another chat, epoch or device is rejected` (three cases: rebuild the `ChatKeyWrap` with a changed field and the original `sig`, and also pass matching expected values, so the signature is what fails; plus the case where the wrap is intact but `unwrapChatKey` is called with a different `chatId`); `wrap signed by a different device is rejected` (verify with another device's signPub); `changed sealed bytes are rejected`; `chat key must be 32 bytes` (`wrapChatKey` with 31 bytes throws `ArgumentError`); `malformed wrap json throws CryptoFailure` (missing `sig`, `epoch` as string, bad base64).
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement `wrap.dart`.**
- [ ] **Step 4: Run, expect PASS** (VM and chrome).
- [ ] **Step 5: Commit** — `feat(crypto): signed chat-key wraps`

### Task 5: Envelopes, and the spike code removed

**Files:**
- Create: `app/lib/crypto/envelope.dart`
- Test: `app/test/crypto/envelope_test.dart`
- Modify: `app/integration_test/spikes_test.dart`, `app/lib/screens/spikes_screen.dart` (use `lib/crypto/`)
- Delete: `app/lib/spikes/crypto_spike.dart`, `app/test/crypto_spike_test.dart`

**Interfaces:**
- Consumes: `ByteWriter`, `b64url`, `b64urlDecode`, `CryptoFailure`.
- Produces:
  - `class Envelope { final int v, epoch; final Uint8List nonce, ct, sig; Map<String, Object> toJson(); factory Envelope.fromJson(Map<String, Object?> j) /* CryptoFailure: missing/mistyped field, bad base64, nonce != 24, ct < 16, sig != 64 */ }`
  - `Uint8List envelopeAad({required int v, required String chatId, required int epoch, required String messageId, required String senderDeviceId})`
  - `Future<Envelope> encryptEnvelope({required List<int> chatKey, required int epoch, required String chatId, required String messageId, required String senderDeviceId, required SimpleKeyPair signKey, required List<int> plaintext, @visibleForTesting List<int>? nonce})`
  - `Future<Uint8List> decryptEnvelope({required Envelope envelope, required List<int> chatKey, required String chatId, required String messageId, required String senderDeviceId, required List<int> senderSignPub})` — `v` must be 1; verifies `sig` over `aad ‖ nonce ‖ ct` before decrypting. The caller picks `chatKey` by `envelope.epoch`.

- [ ] **Step 1: Write failing tests:** `encrypt then decrypt round-trips`; `each AAD field is bound` (decrypt with a changed chatId, messageId or senderDeviceId fails); `changed epoch is rejected` (re-serialize with `epoch` + 1 and decrypt with the *same* key: must fail on the signature); `changed v is rejected`; `changed nonce is rejected`; `flipped ct byte is rejected`; `wrong sender key is rejected`; `malformed envelope json throws CryptoFailure` (each case named in Review Focus 3); `two encryptions of the same plaintext differ` (random nonce); `100 envelopes under 2 s` (port the spike's timing test).
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement `envelope.dart`.**
- [ ] **Step 4: Move callers.** Point `integration_test/spikes_test.dart` and `lib/screens/spikes_screen.dart` at `lib/crypto/` (`signDeviceCert`, `sealBox`/`openBox`, `encryptEnvelope`/`decryptEnvelope`), keeping the `SPIKE crypto <platform> <ms>/100` output line; delete the spike file and its test.
- [ ] **Step 5: Run, expect PASS:** `cd app && flutter analyze` → No issues; `flutter test` → All tests passed; `flutter test --platform chrome test/crypto/` → All tests passed; `grep -rn crypto_spike lib test integration_test tool` → no output.
- [ ] **Step 6: Commit** — `feat(crypto): envelopes with signed epoch and version; drop spike crypto`

### Task 6: Fixed test vectors

**Files:**
- Create: `app/tool/gen_crypto_vectors.dart`, `app/test/crypto/vectors_v1.dart` (generated, committed), `app/test/crypto/vectors_test.dart`
- Modify: `.github/workflows/app.yml` (`analyze-test` runs `flutter test --platform chrome test/crypto/` instead of the deleted spike test)

**Interfaces:**
- Consumes: everything above, using the `@visibleForTesting` nonce/ephemeral parameters.
- Produces: `const Map<String, String> vectorsV1` in `vectors_v1.dart` (a Dart file, so the test also runs in Chrome), keyed by name, values lowercase hex or b64url as named.

Fixed inputs: identity seed `01`×32, device enc seed `02`×32, device sign seed `03`×32, second device enc seed `08`×32 and sign seed `09`×32 (the recipient), sealed-box ephemeral seed `04`×32 and nonce `05`×24, chat key `06`×32, envelope nonce `07`×24, chatId `01JCHAT0000000000000000000`, messageId `01JMSG00000000000000000000`, sender device id `01JDEVA0000000000000000000`, recipient device id `01JDEVB0000000000000000000`, epoch 3, plaintext UTF-8 `{"kind":"text","text":"hello famchat"}`.

- [ ] **Step 1: Write `vectors_test.dart` first** with tests that read `vectorsV1`: `cert vector` (rebuilt cert equals vector; equals the server fixture values), `sealed box vector` (rebuilt with fixed ephemeral/nonce equals vector; opening it gives the chat key), `wrap vector` (rebuilt equals vector — sealed and sig; unwrap gives the chat key), `envelope aad vector` (hex of `envelopeAad` equals vector), `envelope vector` (rebuilt with fixed nonce equals vector; decrypt gives the plaintext).
- [ ] **Step 2: Run, expect FAIL** (`vectors_v1.dart` missing).
- [ ] **Step 3: Write `tool/gen_crypto_vectors.dart`** that computes each value from the fixed inputs and writes `test/crypto/vectors_v1.dart` with a header comment saying it is generated and how to rerun it. Run it: `cd app && dart run tool/gen_crypto_vectors.dart`.
- [ ] **Step 4: Check by hand that the generated values are not trivially self-consistent:** `envelope aad vector` must start with hex of `famchat-envelope-v1` then `01` then `001a` (26-char chatId) — compare by eye and record in the ledger.
- [ ] **Step 5: Run, expect PASS:** `flutter test` and `flutter test --platform chrome test/crypto/`. Then mutate one byte in `vectors_v1.dart`, run `flutter test test/crypto/vectors_test.dart` → FAIL, restore.
- [ ] **Step 6: Update `app.yml`, commit** — `test(crypto): fixed v1 test vectors`; push, CI green on all jobs.
