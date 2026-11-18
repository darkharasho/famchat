# Notification previews, stage 2 (iPhone) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** With "Show message previews" on, an iPhone notification shows what the message says. A Swift Notification Service Extension decrypts the envelope that the server already puts in the push.

**Architecture:**
- The Flutter app mirrors a small **preview keyring** into one keychain item. The item lives in the access group `group.dev.famchat.app`, which the app and the extension share. The keyring holds chat keys, trusted devices, group chat ids and user names.
- A new `NotificationService` extension target reads that item and rebuilds `previewText`/`previewBody` in Swift with CryptoKit. It then replaces the alert body, or leaves the generic alert alone.
- The Swift logic lives in a SwiftPM package, `app/ios/PreviewCore`. It is tested with `swift test` on a macOS runner in PR CI, against the HChaCha20 test vectors and a fixture that Dart generates. The extension target compiles the package's source files directly, the way ShareExtension compiles `Vendor/`.

**Tech Stack:** Flutter (riverpod 3, drift, flutter_secure_storage 11.2.0 / flutter_secure_storage_darwin 0.4.3, cryptography), Swift 5.9 + CryptoKit + UserNotifications, SwiftPM/XCTest, Xcode project (hand-edited pbxproj), GitHub Actions (macos-latest, macos-26 release).

**Spec:** `docs/superpowers/specs/2026-11-17-notification-previews-design.md`, sections "iPhone (stage 2)" and "The setting". Stage 1 was built from `docs/superpowers/plans/2026-11-17-notification-previews-stage1.md` (PR #43).

## Global Constraints

**Scope**
- Stage 2 covers iPhone only.
  - macOS keeps generic pushes. In fact macOS gets no FCM pushes at all: `isPushPlatform` is android, iOS and web only. Its desktop previews already work while the app runs.
  - Web stays in stage 3.
- Turn on iOS in `previewsSupported()` only in the final task (Task 6), after the extension exists.

**Preview text (identical to stage 1 and checked by the shared fixture)**
- Text is cut to 300 grapheme clusters (`maxPreviewChars = 300`) and, when cut, ends with "…" (U+2026).
- Media labels: photo "📷 Photo", voice "🎤 Voice message", video "🎥 Video", gif "GIF".
- Any other kind, or any failure, gives the generic alert unchanged.
- In a group the body is `<sender name>: <preview>`, or `Someone: <preview>` when the name is unknown. A direct or unknown chat gets the bare preview.
- The title is never changed.

**What decrypts (mirrors `previewText` in `app/lib/push/preview.dart`)**
- The sender device must be in the keyring. Only `certValid && trusted` devices are written there. It must also have `userId == senderUserId` and `revoked == false`.
- The key is `keys[chatId][envelope.epoch]`. The envelope's own `epoch` is used; the push's `epoch` data key is ignored, as in Dart.
- `v` must be 1. `nonce` is 24 bytes, `ct` at least 16 bytes, `sig` 64 bytes and `signPub` 32 bytes. base64url has no padding: reject any char outside `[A-Za-z0-9_-]` and any length where `len % 4 == 1`.
- `aad = utf8("famchat-envelope-v1") ‖ u8(v) ‖ str(chatId) ‖ u32be(epoch) ‖ str(messageId) ‖ str(senderDeviceId)`, where `str` is a u16be byte length followed by UTF-8 bytes (more than 65535 bytes is a failure).
- The signature is Ed25519 over `aad ‖ nonce ‖ ct`, checked **before** decrypting.
- The cipher is XChaCha20-Poly1305 under the 32-byte chat key, with `ct = ciphertext ‖ 16-byte tag`.
  - Subkey: `HChaCha20(key, nonce[0..<16])`.
  - Then CryptoKit `ChaChaPoly` with nonce `00000000 ‖ nonce[16..<24]` and the same aad.
- The plaintext is UTF-8 JSON, an object with a string `kind`. `text` requires `text` to be a non-empty string, `replyTo` to be absent or a non-empty string, and `mentions` to be absent or an array of at most 50 strings.

**Keyring**
- Dart writes it with flutter_secure_storage:
  - `IOSOptions(groupId: 'group.dev.famchat.app', accountName: 'dev.famchat.preview', accessibility: KeychainAccessibility.first_unlock_this_device, synchronizable: false)`;
  - key `preview_keyring`.
  - This becomes a `kSecClassGenericPassword` item with `kSecAttrService = dev.famchat.preview`, `kSecAttrAccount = preview_keyring`, `kSecAttrAccessGroup = group.dev.famchat.app` and `kSecAttrAccessible = AfterFirstUnlockThisDevice`. The value is UTF-8 JSON.
- No method channel is needed. On iOS the app group is a valid keychain access group, so no keychain-sharing capability is added.
- Schema `v: 1` is one JSON item, rewritten whole:
  ```json
  {"v":1,
   "keys":{"<chatId>":{"<epoch>":"<b64url 32-byte key>"}},
   "devices":{"<deviceId>":{"userId":"…","signPub":"<b64url>","revoked":false}},
   "groups":["<chatId of each kind=='group' chat>"],
   "names":{"<userId>":"<name>"}}
  ```
  Every map and list is sorted by key, so the same DB gives byte-identical JSON.
- It exists only while previews are on and the user is signed in. It is wiped on "off" and in `_endSession`.

**Extension**
- Target `NotificationService`, bundle id `dev.famchat.app.NotificationService`, iOS 15.0, app group `group.dev.famchat.app`, `APPLICATION_EXTENSION_API_ONLY = YES`. Its build settings mirror ShareExtension's.
- It calls `contentHandler` exactly once. `serviceExtensionTimeWillExpire` delivers the original content.
- Pushes without `preview == "1"`, and every failure, deliver `request.content` unchanged.
- CryptoKit only; no third-party Swift dependency.

**Privacy**
- No message text, keys or keyring contents in logs (no `print`/`NSLog`/`os_log` of them).

**Process**
- There is no Swift toolchain on the dev machine. Swift is verified by the `ios-preview-core` CI job (`swift test`) and the existing `ios` job, which builds Runner with the extension.
- Run `export PATH=$HOME/development/flutter/bin:$PATH` before Flutter commands.
- Never `dart format` existing files.
- Run one heavy build at a time.
- Hand-edit `project.pbxproj`. New object IDs are unique 24-hex `FA5E000000000000000001xx` (`01`–`3F`), mirroring the ShareExtension (`FA5E…00xx`) entries one for one.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never bypass commit signing.

## Review Focus

1. **Sign-out while a debounced keyring rewrite is pending.** The keyring must stay wiped; a late rewrite must not restore a signed-out user's keys. Test: Task 4 `stop cancels a pending rewrite` and `sign out wipes the preview keyring`.
2. **A preview push after previews were turned off locally, before the server heard.** The keyring is gone, so the alert stays generic. Test: Task 3 `no keyring keeps the generic alert`; Task 4 `turning previews off wipes`.
3. **A text that cuts at 300 graphemes around ZWJ emoji, flags or combining marks.** Dart and Swift must give the same string. Test: Task 3 fixture cases `cut-emoji` and `exactly-300`.
4. **`serviceExtensionTimeWillExpire` racing a finishing decrypt.** The handler runs once, with whichever result came first. Test: Task 5 `finish after expire is ignored` and `concurrent finish delivers once`.
5. **JSON type confusion in the envelope** (`"v": true`, `"epoch": 1.5`, padded base64). Expected: generic, as in Dart. Test: Task 3 fixture cases `v-bool`, `padded-b64` and `epoch-float`.

---

### Task 1: PreviewCore package — XChaCha20-Poly1305 and envelope opening

**Files:**
- Create: `app/ios/PreviewCore/Package.swift`
- Create: `app/ios/PreviewCore/Sources/PreviewCore/XChaCha.swift`
- Create: `app/ios/PreviewCore/Sources/PreviewCore/Envelope.swift`
- Create: `app/ios/PreviewCore/Tests/PreviewCoreTests/XChaChaTests.swift`
- Create: `app/ios/PreviewCore/Tests/PreviewCoreTests/EnvelopeTests.swift`
- Modify: `.github/workflows/app.yml` (new job `ios-preview-core`)

**Interfaces:**
- Produces:
  - Package `PreviewCore`, swift-tools-version 5.9, platforms `.iOS(.v15), .macOS(.v12)`, library target `PreviewCore`, and test target `PreviewCoreTests` with `exclude: ["Fixtures"]`.
  - `enum PreviewError: Error { case malformed, badSignature, decrypt }`
  - `enum XChaCha { static func hChaCha20(key: [UInt8], nonce16: [UInt8]) -> [UInt8]; static func open(key: Data, nonce: Data, sealed: Data, aad: Data) throws -> Data }`. `sealed` is ciphertext followed by the tag.
  - `func b64urlDecode(_ s: String) -> Data?`, using the same rules as Dart's `b64urlDecode`.
  - `struct Envelope { let v: Int; let epoch: UInt32; let nonce: Data; let ct: Data; let sig: Data; init(json: Data) throws }`. It is parsed with `JSONDecoder` into `Int`/`UInt32`/`String` fields, so `true` and `1.5` are rejected.
  - `static func Envelope.aad(v: Int, chatId: String, epoch: UInt32, messageId: String, senderDeviceId: String) throws -> Data`
  - `func Envelope.open(chatKey: Data, chatId: String, messageId: String, senderDeviceId: String, senderSignPub: Data) throws -> Data` verifies the signature, then decrypts.
  - All declarations are `public`.
  - CI job `ios-preview-core`: `runs-on: macos-latest`, `timeout-minutes: 10`, `actions/checkout@v7`, then `swift test` with `working-directory: app/ios/PreviewCore`.

- [ ] **Step 1: Write the failing tests.**
  - `XChaChaTests`:
    - `testHChaCha20DraftVector`: key `000102…1f`, nonce `000000090000004a0000000031415927` gives `82413b4227b27bfed30e42508a877d73a0f9e4d58a74a853c12ec41326d3ecdc`. This is draft-irtf-cfrg-xchacha-03 §2.2.1; check it against the draft text when copying.
    - `testXChaChaPolyDraftVector`: open the AEAD vector of §A.3.1 ("Ladies and Gentlemen of the class of '99…"). Copy key, nonce, aad, ciphertext and tag verbatim from https://datatracker.ietf.org/doc/html/draft-irtf-cfrg-xchacha-03#appendix-A.3.1.
    - `testTamperedTagThrows`: the same vector with the last tag byte flipped throws `PreviewError.decrypt`.
  - `EnvelopeTests`:
    - `testAadBytes`: `aad(v:1, chatId:"C", epoch:258, messageId:"M", senderDeviceId:"D")` equals `utf8("famchat-envelope-v1") + [1, 0,1,0x43, 0,0,1,2, 0,1,0x4d, 0,1,0x44]`.
    - `testRejectsShortNonce`, `testRejectsPaddedBase64` (`"AAAA="`), `testRejectsBoolV` (`{"v":true,…}`) and `testRejectsVersion2`: each throws `PreviewError.malformed` from init, or from `open` for v2.
    - `testB64urlLenMod4Is1`: `b64urlDecode("A") == nil`.
- [ ] **Step 2: Write `Package.swift`, add the CI job, push the branch and watch it.** Run: `gh run watch` on the `app` workflow. Expected: `ios-preview-core` FAILS with missing symbols.
- [ ] **Step 3: Implement `XChaCha.swift` and `Envelope.swift`.**
  - HChaCha20 has no CryptoKit equivalent, so write it:
    - The state is the constants `0x61707865 0x3320646e 0x79622d32 0x6b206574`, then the 8 key words (little-endian), then the 4 nonce words (little-endian).
    - Run 10 double rounds (column then diagonal quarter-rounds) with **no** final addition.
    - The output is words 0–3 and 12–15, little-endian.
  - `open` passes the subkey to `ChaChaPoly.open(ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: [0,0,0,0] + nonce[16..<24]), ciphertext:, tag:), using: SymmetricKey(data: subkey), authenticating: aad)`.
  - The signature is checked with `Curve25519.Signing.PublicKey(rawRepresentation:).isValidSignature(_:for:)`.
- [ ] **Step 4: Push and check CI.** Expected: `ios-preview-core` PASS; every other `app` job unchanged.
- [ ] **Step 5: Commit** `feat(ios): XChaCha20-Poly1305 and envelope opening for notification previews`.

### Task 2: App — the preview keyring builder and store

**Files:**
- Create: `app/lib/push/preview_keyring.dart`
- Test: `app/test/push/preview_keyring_test.dart`

**Interfaces:**
- Consumes: `ChatDb.allKeys()`, `allUsers()`, `chatById`, and the `localDevices` and `localChats` tables (add `Future<List<DeviceRow>> allDevices()` and `Future<List<ChatRow>> allChats()` to `ChatDb` only if no equivalent exists).
- Produces:
  - `const previewKeyringGroup = 'group.dev.famchat.app', previewKeyringService = 'dev.famchat.preview', previewKeyringKey = 'preview_keyring';`
  - `Future<String> buildPreviewKeyring(ChatDb db)` returns canonical JSON in the Global Constraints schema. Only `certValid && trusted` devices are included, and `revoked` is kept as a field.
  - `abstract interface class PreviewKeyringStore { Future<void> write(String json); Future<void> wipe(); }`
  - `class SecurePreviewKeyringStore implements PreviewKeyringStore`, with the `IOSOptions` from Global Constraints. `wipe` deletes `previewKeyringKey`.
  - `class MemoryPreviewKeyringStore implements PreviewKeyringStore { String? value; int writes; }` for tests.
  - Put the schema in the file's header comment.

- [ ] **Step 1: Write the failing tests** in `preview_keyring_test.dart`, with the in-memory `ChatDb` setup from `test/push/preview_test.dart`:
  - `holds every epoch of every chat`: keys `(C1,1)` and `(C1,2)`, `(G1,1)` → `keys == {C1:{"1":b64,"2":b64}, G1:{"1":b64}}`.
  - `only trusted devices with valid certs`: one device with `trusted:false` and one with `certValid:false` are absent, and a trusted one is present.
  - `revoked device kept with revoked true`.
  - `groups lists group chats only`: a `kind:'direct'` chat is absent.
  - `names maps user ids to names`.
  - `is byte-identical for the same data inserted in another order`.
  - `empty db gives the empty keyring`: `{"v":1,"keys":{},"devices":{},"groups":[],"names":{}}`.
  - `SecurePreviewKeyringStore uses the shared access group`: build it with an injected `FlutterSecureStorage`, mocked via `FlutterSecureStorage.setMockInitialValues`. Then assert `store.iOptions.groupId == 'group.dev.famchat.app'`, `accountName == 'dev.famchat.preview'` and `accessibility == KeychainAccessibility.first_unlock_this_device` (expose the options as a `static const iosOptions`).
- [ ] **Step 2: Run** `cd app && flutter test test/push/preview_keyring_test.dart`. Expected: FAIL (file missing).
- [ ] **Step 3: Implement `preview_keyring.dart`.** Build sorted maps (`SplayTreeMap`, or sort before inserting) and encode them with `jsonEncode`.
- [ ] **Step 4: Run** the test and `flutter analyze`. Expected: PASS, no issues.
- [ ] **Step 5: Commit** `feat(app): build the iPhone preview keyring`.

### Task 3: Swift preview logic, checked against a Dart-generated fixture

**Files:**
- Create: `app/test/push/ios_preview_fixture_test.dart` (generator and checker)
- Create: `app/ios/PreviewCore/Tests/PreviewCoreTests/Fixtures/preview_fixture.json` (generated, committed)
- Create: `app/ios/PreviewCore/Sources/PreviewCore/Keyring.swift`
- Create: `app/ios/PreviewCore/Sources/PreviewCore/Preview.swift`
- Create: `app/ios/PreviewCore/Tests/PreviewCoreTests/CrossImplementationTests.swift`
- Create: `app/ios/PreviewCore/Tests/PreviewCoreTests/PreviewTests.swift`

**Interfaces:**
- Consumes: `buildPreviewKeyring` (Task 2), `previewText`/`previewBody` (stage 1), `encryptEnvelope(…, nonce:)`, `Envelope` and `XChaCha` (Task 1).
- Produces:
  - Fixture JSON: `{"keyring": "<exact buildPreviewKeyring output>", "cases": [{"name": String, "userInfo": {String: String}, "expected": String|null}]}`.
    - `userInfo` holds the FCM data keys: `chatId`, `messageId`, `senderUserId`, `senderDeviceId`, `epoch`, `env`, `title`, `body` and `preview`.
    - `expected` is the body Dart computes, or null for "keep the generic alert".
  - Swift:
    - `struct KeyringDevice: Decodable { let userId: String; let signPub: String; let revoked: Bool }`
    - `struct Keyring: Decodable { let v: Int; let keys: [String: [String: String]]; let devices: [String: KeyringDevice]; let groups: [String]; let names: [String: String]; static func parse(_ data: Data) -> Keyring?; func key(chatId: String, epoch: UInt32) -> Data? }`. `parse` returns nil unless `v == 1`.
    - `enum Preview`:
      - `static let maxPreviewChars = 300`
      - `static func mediaLabel(_ kind: String) -> String?`
      - `static func previewText(chatId: String, messageId: String, senderUserId: String, senderDeviceId: String, envelope: Data, keyring: Keyring) -> String?`
      - `static func previewBody(chatId: String, senderUserId: String, preview: String, keyring: Keyring) -> String`
      - `static func notificationBody(userInfo: [AnyHashable: Any], keyring: Keyring?) -> String?`: nil means deliver the original content. It returns nil unless `userInfo["preview"] as? String == "1"` and all five string fields are present.
    - All declarations are `public`.

- [ ] **Step 1: Write the Dart generator and checker** `ios_preview_fixture_test.dart`.
  - Everything is deterministic:
    - sender keys from `Ed25519().newKeyPairFromSeed(List.filled(32, 7))`, and a second signer from seed `8`;
    - chat key `List.generate(32, (i) => i)`;
    - each case's nonce `List.generate(24, (i) => i + caseIndex)`.
  - DB contents:
    - users `bob` "Bob", plus `carol`, who has no user row;
    - chats `D1` (direct) and `G1` (group);
    - devices `bob-d` (trusted), `bob-u` (`trusted:false`), `bob-r` (revoked), `carol-d` (trusted) and `eve-d` (trusted, user `eve`);
    - keys `(D1,1)` and `(G1,1)`.
  - Cases, where `expected` is computed by stage 1's `previewText` → `previewBody` over the same DB, plus a few hand-written assertions:
    - `text-direct` → `'hello there'`;
    - `text-group` → `'Bob: hi all'`;
    - `group-unknown-name` → `'Someone: hey'`;
    - `exactly-300` (300 × `'a'`) → unchanged;
    - `cut-emoji`: 299 × `'a'`, then `'👨‍👩‍👧'`, then `'🇸🇪'` and `'é'` (as `e` + U+0301), giving `'${'a'*299}👨‍👩‍👧…'`;
    - `photo`, `voice`, `video` and `gif` → their labels;
    - `reaction` → null;
    - `untrusted-device`, `revoked-device` and `wrong-user` (claims `bob` with `eve-d`) → null;
    - `missing-epoch` (epoch 2) → null;
    - `bad-signature` (signed with seed 8) → null;
    - `tampered-ct-resigned` (a flipped ct byte with a valid signature over it, so only the AEAD fails) → null;
    - `v-bool`, `epoch-float` and `padded-b64` → null;
    - `env-not-json` → null;
    - `no-preview-flag` (`preview` absent) → null;
    - `data-epoch-ignored` (data `epoch:"9"`, envelope epoch 1) → the text.
  - Behaviour: with `UPDATE_PREVIEW_FIXTURE=1` it writes `../ios/PreviewCore/Tests/PreviewCoreTests/Fixtures/preview_fixture.json` (pretty, 2-space). Otherwise test `committed fixture matches the Dart implementation` asserts the file equals the regenerated string.
- [ ] **Step 2: Generate and check the fixture.** Run `cd app && UPDATE_PREVIEW_FIXTURE=1 flutter test test/push/ios_preview_fixture_test.dart`, then the same command without the variable. Expected: PASS both times, and `git status` shows the new fixture.
- [ ] **Step 3: Write the failing Swift tests.**
  - `CrossImplementationTests.testEveryFixtureCase`: load the fixture via `URL(fileURLWithPath: #filePath)` → `Fixtures/preview_fixture.json`, parse `keyring` with `Keyring.parse`, and assert `Preview.notificationBody(userInfo: case.userInfo, keyring:) == case.expected` for each case, with the case name in the failure message. Also assert the case count is at least 22, so an empty fixture can't pass. Avoid an `epoch: 1.0` case: Dart rejects it but `JSONDecoder` may accept it, and both paths reject `1.5`.
  - `PreviewTests`:
    - `testNoKeyringKeepsGenericAlert`: the fixture's `text-direct` userInfo with `keyring: nil` gives nil.
    - `testKeyringWrongVersionIsNil`: `{"v":2,…}` gives nil.
    - `testMediaLabels`, covering the four labels and nil for `"text"`.
- [ ] **Step 4: Push and check CI.** Expected: `ios-preview-core` FAILS (no `Preview`/`Keyring`).
- [ ] **Step 5: Implement `Keyring.swift` and `Preview.swift`, mirroring `previewText`.**
  - Device checks first, then key lookup by `envelope.epoch`, then `Envelope.open`.
  - Decode the plaintext with `JSONSerialization`; non-UTF-8 is a failure.
  - Text gets the field checks from Global Constraints. When `count > 300` it becomes `String(text.prefix(300)) + "…"`; Swift `Character` is a grapheme cluster.
  - Media kinds get `mediaLabel` from `kind` alone.
  - Everything else, and any thrown error, gives nil.
- [ ] **Step 6: Push and check CI.** Expected: `ios-preview-core` PASS, and the `analyze-test` job passes the Dart fixture test.
- [ ] **Step 7: Commit** `feat(ios): notification preview logic, checked against a Dart fixture`.

### Task 4: App — keyring lifecycle (on/off, chat keys, directory, sign-out)

**Files:**
- Modify: `app/lib/push/preview_keyring.dart` (add `PreviewKeyringSync` and providers)
- Modify: `app/lib/push/providers.dart` (`notificationsProvider` watches `previewKeyringSyncProvider`)
- Modify: `app/lib/session/session_controller.dart` (`_endSession` wipes the keyring)
- Test: `app/test/push/preview_keyring_test.dart`, `app/test/session/session_controller_test.dart`

**Interfaces:**
- Consumes: Task 2, `previewsOnProvider`, `chatDbProvider`, and `ChatDb.tableUpdates`.
- Produces:
  - `class PreviewKeyringSync { PreviewKeyringSync({required ChatDb db, required PreviewKeyringStore store, Duration debounce = const Duration(milliseconds: 300)}); Future<void> setOn(bool on); Future<void> dispose(); }`.
    - `setOn(true)` writes now, then listens to `db.tableUpdates(TableUpdateQuery.onAllTables([db.localKeys, db.localDevices, db.localChats, db.localUsers]))` and rewrites after `debounce`.
    - `setOn(false)` cancels the listener and any pending timer, then wipes.
    - Writes are serialised. A generation counter drops any rebuild that finishes after `setOn(false)` or `dispose`.
    - Store errors are caught; a simulator without the entitlement must not crash.
  - `final previewKeyringStoreProvider = Provider<PreviewKeyringStore?>((ref) => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS ? SecurePreviewKeyringStore() : null);`
  - `final previewKeyringSyncProvider = Provider<void>(...)`. It is a no-op when the store is null. Otherwise it creates a sync for the signed-in `chatDbProvider`, calls `setOn(ref.watch(previewsOnProvider).value ?? false)` on each change, and disposes the sync in `onDispose`.
  - `_endSession`: `await ref.read(previewKeyringStoreProvider)?.wipe().timeout(_timeout)` in a try/catch, beside `writePreviewsOn(false)`.

- [ ] **Step 1: Write the failing tests.**
  - In `preview_keyring_test.dart` (use `debounce: Duration.zero` and pump with `await Future<void>.delayed(Duration.zero)`):
    - `setOn true writes the keyring now`;
    - `a new chat key rewrites`: `putKey` → `store.value` contains the new epoch;
    - `a device revoked rewrites`: `putDevice(revoked:true)` → `"revoked":true`;
    - `a renamed user rewrites`;
    - `turning previews off wipes`: `value == null`, and a later `putKey` writes nothing (`writes` unchanged);
    - `stop cancels a pending rewrite`: with `debounce: 50ms`, `putKey` then `setOn(false)` immediately, wait 100ms → `value == null`;
    - `a throwing store does not throw out of setOn`.
  - In `session_controller_test.dart`: `sign out wipes the preview keyring`. Override `previewKeyringStoreProvider` with a `MemoryPreviewKeyringStore` holding `'x'`; after `signOut()`, `value == null`.
- [ ] **Step 2: Run** `flutter test test/push/preview_keyring_test.dart test/session/session_controller_test.dart`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement** as the Interfaces describe. Watch `previewKeyringSyncProvider` from `notificationsProvider`.
- [ ] **Step 4: Run** `flutter test test/push test/session` and `flutter analyze`. Expected: PASS, clean.
- [ ] **Step 5: Commit** `feat(app): keep the iPhone preview keyring in step with keys and devices`.

### Task 5: The NotificationService extension target

**Files:**
- Create: `app/ios/PreviewCore/Sources/PreviewCore/PreviewDelivery.swift`
- Create: `app/ios/PreviewCore/Tests/PreviewCoreTests/PreviewDeliveryTests.swift`
- Create: `app/ios/NotificationService/NotificationService.swift`
- Create: `app/ios/NotificationService/KeychainKeyring.swift`
- Create: `app/ios/NotificationService/Info.plist`
- Create: `app/ios/NotificationService/NotificationService.entitlements`
- Modify: `app/ios/Runner.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `Preview.notificationBody` and `Keyring.parse` (Task 3); the keychain item from Task 2's constants.
- Produces:
  - `public final class PreviewDelivery { public init(deliver: @escaping (String?) -> Void); public func finish(_ body: String?); public func expire() }`. The first call wins and later calls are ignored (guarded by an `NSLock`); `expire()` is `finish(nil)`.
  - `enum KeychainKeyring { static func load() -> Keyring? }` runs `SecItemCopyMatching` with `kSecClassGenericPassword`, service `dev.famchat.preview`, account `preview_keyring`, access group `group.dev.famchat.app`, `kSecReturnData` and `kSecMatchLimitOne`. Any status other than success gives nil.
  - `class NotificationService: UNNotificationServiceExtension`:
    - `didReceive` makes a `PreviewDelivery` whose `deliver` sets `body` on a mutable copy of the content (title untouched), or passes `request.content` for nil. It then calls `finish(Preview.notificationBody(userInfo: request.content.userInfo, keyring: KeychainKeyring.load()))` on a background queue.
    - `serviceExtensionTimeWillExpire` calls `expire()`.
    - It compiles the PreviewCore sources directly, so there is no `import PreviewCore`.
  - `Info.plist`: `NSExtensionPointIdentifier = com.apple.usernotifications.service`, `NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).NotificationService`, `CFBundleDisplayName = FamChat`.
  - The entitlements contain only `com.apple.security.application-groups = [group.dev.famchat.app]`, with a comment saying the keyring item is shared through it.
- pbxproj: mirror every ShareExtension object with new IDs `FA5E00000000000000000101`…:
  - build files for `NotificationService.swift`, `KeychainKeyring.swift` and the six PreviewCore sources (`XChaCha`, `Envelope`, `Keyring`, `Preview`, `PreviewDelivery`, plus any added);
  - `NotificationService.appex in Embed App Extensions` (`RemoveHeadersOnCopy`), added to the existing `FA5E0000000000000000000C` phase;
  - a container proxy and a target dependency added to Runner's `dependencies`;
  - file refs; group `NotificationService` with a `PreviewCore` subgroup whose `path = ../PreviewCore/Sources/PreviewCore`; the appex in `Products`;
  - Sources, Frameworks and Resources phases; a native target (`com.apple.product-type.app-extension`); `TargetAttributes` (`CreatedOnToolsVersion = 16.0`); an entry in the project `targets`;
  - three `XCBuildConfiguration`s plus a configuration list, the same as ShareExtension's except: `CODE_SIGN_ENTITLEMENTS = NotificationService/NotificationService.entitlements`, `INFOPLIST_FILE = NotificationService/Info.plist`, `PRODUCT_BUNDLE_IDENTIFIER = dev.famchat.app.NotificationService`, and no `CUSTOM_GROUP_ID`.

- [ ] **Step 1: Write the failing tests** in `PreviewDeliveryTests`:
  - `testFinishDeliversOnce`: `finish("a")` then `finish("b")` → deliveries `["a"]`.
  - `testFinishAfterExpireIsIgnored`: `expire()` then `finish("a")` → `[nil]`.
  - `testConcurrentFinishDeliversOnce`: `DispatchQueue.concurrentPerform(iterations: 100)` alternating `finish`/`expire` → exactly 1 delivery.
- [ ] **Step 2: Push and check CI.** Expected: `ios-preview-core` FAILS (no `PreviewDelivery`).
- [ ] **Step 3: Implement** `PreviewDelivery.swift`, the extension files and the pbxproj edits. Before committing:
  - check that no new ID collides: `grep -o 'FA5E0000000000000000[0-9A-F]\{4\}' app/ios/Runner.xcodeproj/project.pbxproj | sort | uniq -c`, where each new ID's count matches its ShareExtension twin's;
  - check that braces balance: `python3 -c` counting `{`/`}` in the pbxproj.
- [ ] **Step 4: Push and check CI.** Expected: `ios-preview-core` PASS. The `ios` job (simulator build of Runner, now embedding `NotificationService.appex`) PASSES. If the `ios` job fails on the project file, read the `xcodebuild` error, fix the pbxproj and push again.
- [ ] **Step 5: Commit** `feat(ios): notification service extension shows message previews`.

### Task 6: Release signing, the iOS switch and docs

**Files:**
- Modify: `.github/workflows/release.yml` (ios job: "Attach the entitlements to the archive" and "Sign and export")
- Modify: `app/lib/push/preview_setting.dart` (`previewsSupported` includes iOS)
- Modify: `app/test/push/preview_setting_test.dart`, `app/test/push/notification_settings_test.dart`
- Modify: `docs/protocol.md` (push preview section: the iPhone extension and keyring, one paragraph)

**Interfaces:**
- Consumes: Tasks 4 and 5.
- `previewsSupported` returns true for android, iOS, macOS, windows and linux; false for fuchsia and web.

- [ ] **Step 1: Flip the tests.**
  - `preview_setting_test.dart` becomes `supported on android, iOS and desktop, not web`, with iOS `isTrue`.
  - In `notification_settings_test.dart`, the iOS case now expects `settings-previews` to be present.
- [ ] **Step 2: Run** `flutter test test/push/preview_setting_test.dart test/push/notification_settings_test.dart`. Expected: FAIL on the iOS assertions.
- [ ] **Step 3: Implement.** Add `TargetPlatform.iOS` to the true branch, and update the doc comment ("Android, iOS and desktop. Not the web").
- [ ] **Step 4: Fix the release signing for the extensions.** The shipped 1.0.7 IPA's `ShareExtension.appex` carries **no** `application-groups` entitlement, although its profile has the group: the archive step ad-hoc signs only `Runner.app`. Change the workflow as follows:
  - **Sign the extensions.** In "Attach the entitlements to the archive", before signing the app, sign each `"$app"/PlugIns/*.appex` with `codesign --force --sign - --entitlements "ios/$(basename "$appex" .appex)/$(basename "$appex" .appex).entitlements" "$appex"`. Fail the step if that entitlements file is missing.
  - **Check the IPA.** In "Sign and export", after the aps-environment check, fail with `::error::` unless both `Payload/Runner.app/PlugIns/NotificationService.appex` and `ShareExtension.appex` exist and their `codesign -d --entitlements :-` output contains `group.dev.famchat.app`.
- [ ] **Step 5: Run** `flutter test` and `flutter analyze`. Expected: all pass. Then lint the workflow with `actionlint` if it's installed (otherwise `python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' .github/workflows/release.yml`). Expected: no errors.
- [ ] **Step 6: Release dry run.** Run `gh workflow run release.yml -f platforms=ios -f store_upload=false --ref <branch>`, then `gh run watch`. Expected: the ios job PASSES, and the uploaded `ios-ipa` artifact contains `NotificationService.appex`.
  - **MANUAL STEP (user, Apple Developer portal, only if export fails).** If the export fails with no profile for `dev.famchat.app.NotificationService`, or the new entitlement check fails for it:
    1. Open Certificates, Identifiers & Profiles → Identifiers.
    2. Register App ID `dev.famchat.app.NotificationService` (explicit), with the **App Groups** capability.
    3. Under App Groups, assign `group.dev.famchat.app`.
    4. Re-run the workflow.
  - No keychain-sharing capability is needed.
- [ ] **Step 7: Device check (user, after a TestFlight build).**
  1. Turn "Show message previews" on, then lock the phone.
  2. A text from another device shows the text; a photo shows "📷 Photo".
  3. Turn the switch off; the next push is generic.
  4. Set iOS Settings → FamChat → Show Previews to "Never": the lock screen hides the text, as for any app.
- [ ] **Step 8: Commit** `feat(ios): turn on message previews on iPhone`.

---

## Self-review

- **Spec coverage:**

  | Spec item | Where |
  |---|---|
  | Extension target in the app group | Task 5 |
  | Keyring in a shared access group, AfterFirstUnlock, wiped on off and on sign-out | Tasks 2 and 4 |
  | Keyring rewritten on key and directory changes | Task 4 |
  | Every epoch of every chat | Task 2 |
  | CryptoKit only, HChaCha20 checked against the draft vectors | Task 1 |
  | `isValidSignature` | Task 1 |
  | Fallback to the original content | Tasks 3 and 5 |
  | Labels, cut and group prefix | Task 3 fixture |
  | Setting shown only once the stage ships | Task 6 |
  | "Turning it on sends PUT, then builds the keyring" | Stage 1's `_setPreviews` sends the PUT; Task 4's provider builds the keyring when `previewsOnProvider` changes |
  | iOS "Show Previews" | Needs no code; Task 6 step 7 checks it |

  Accepted limit: no background refresh. Out of scope: macOS over APNs, because macOS has no push today.
- **Step scan:**
  - Every code step names its file, signatures and pinned values.
  - The only body given is HChaCha20's round structure, which the signature doesn't determine.
  - The AEAD vector is fetched from the draft rather than transcribed here, so it can't be miscopied.
- **Type consistency:**
  - `Preview.notificationBody(userInfo:keyring:)`, `Keyring.parse`, `KeychainKeyring.load()` and `PreviewDelivery.finish/expire` are used with the same names in Tasks 3 and 5.
  - Dart `buildPreviewKeyring`, `PreviewKeyringStore.write/wipe`, `MemoryPreviewKeyringStore.value/writes` and `previewKeyringStoreProvider` are consistent across Tasks 2, 4 and 6.
- **Review Focus:** each of the 5 lines has a named test in its owning task.
- **Proportion:** about the length of the stage 1 plan, with no function bodies beyond HChaCha20's outline.
