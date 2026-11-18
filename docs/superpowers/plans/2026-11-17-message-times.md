# Message Times Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A per-device 12/24-hour "Time format" setting used by every clock time in the app, and the message sent time moved out of the bubble to a small line under the last bubble of each run.

**Architecture:** One formatter `clockTime(t, h24:)` in a new `lib/settings/time_format.dart`, which also holds the setting (enum + SharedPreferencesAsync + AsyncNotifierProvider, like `lib/push/preview_setting.dart`). The app root overrides `MediaQuery.alwaysUse24HourFormat` from the setting (Automatic leaves the device's value), so widgets read `MediaQuery.alwaysUse24HourFormatOf(context)` and need no Riverpod. Pure helpers (`shortTime`, `muteLabel`) take an `h24` argument from their caller.

**Tech Stack:** Flutter, flutter_riverpod 3, shared_preferences (SharedPreferencesAsync), flutter_test.

**Spec:** `docs/superpowers/specs/2026-11-17-message-times-design.md`

## Global Constraints

- Setting label "Time format", choices "Automatic" (default), "12-hour", "24-hour". Stored per device in SharedPreferences.
- Automatic follows the device (`MediaQuery.alwaysUse24HourFormat`).
- 24-hour "14:05" (two-digit hour, as today); 12-hour "2:05 PM" (no leading zero, space, uppercase AM/PM; 0:xx is "12:xx AM", 12:xx is "12:xx PM").
- No change to runs, day separators, or the chat list's "Mon" / "3/14" for older days.
- "edited" stays inside the bubble.
- Never `dart format` existing files. `export PATH=$HOME/development/flutter/bin:$PATH` before Flutter. Run flutter commands from `app/`.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. Prefs unreadable (plugin missing in widget tests, platform error): the app must still start and use Automatic, not show an error or crash. → Task 2 test.
2. Midnight and noon in 12-hour form ("12:00 AM", "12:30 PM"), not "0:00 AM". → Task 1 test.
3. A pending or failed message in the middle of a run still shows its time (and the pending icon) under it. → Task 3 test.
4. An edited message that is not last in its run keeps "edited" inside the bubble and shows no time. → Task 3 test.
5. Others' messages in a group (avatar space): the time line lines up with the bubble, not the avatar column. → Task 3 checked by eye in the review screenshot; the test asserts left edge ≥ bubble left edge.

---

### Task 1: Time format setting and formatter; every caller uses it

**Files:**
- Create: `app/lib/settings/time_format.dart`
- Modify: `app/lib/screens/chats/chat_list.dart` (remove `clockTime`; `shortTime` gains `h24`; caller at ~133)
- Modify: `app/lib/screens/chats/group_info_screen.dart` (`muteLabel` gains `h24`; caller at ~185)
- Modify: `app/lib/screens/chats/search_screen.dart` (~140), `app/lib/screens/chats/message_bubble.dart` (~368: just pass `h24` for now; layout is Task 3)
- Test: `app/test/settings/time_format_test.dart` (new), `app/test/screens/group_info_test.dart` (update lines 56-57), `app/test/screens/chat_list_test.dart` (add shortTime cases)

**Interfaces:**
- Produces:
  - `enum TimeFormat { automatic, h12, h24 }`
  - `const timeFormatPrefKey = 'time_format'` (stored as the enum's `name`)
  - `Future<TimeFormat> readTimeFormat([SharedPreferencesAsync? prefs])` — unknown/missing value → `automatic`
  - `Future<void> writeTimeFormat(TimeFormat f, [SharedPreferencesAsync? prefs])`
  - `class TimeFormatNotifier extends AsyncNotifier<TimeFormat>` with `Future<void> set(TimeFormat f)`; `final timeFormatProvider = AsyncNotifierProvider<TimeFormatNotifier, TimeFormat>(...)`
  - `String clockTime(DateTime t, {required bool h24})`
  - `bool use24Hour(TimeFormat f, {required bool device})` — automatic → device, h12 → false, h24 → true
  - `String shortTime(DateTime t, {required bool h24, DateTime? now})` (chat_list.dart; `now` becomes named)
  - `String muteLabel(int? until, DateTime now, {required bool h24})`

- [ ] **Step 1: Write the failing tests** (`test/settings/time_format_test.dart`, with `SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty()` in setUp, as in `test/push/preview_setting_test.dart`)

```dart
test('24-hour', () {
  expect(clockTime(DateTime(2026, 1, 1, 14, 5), h24: true), '14:05');
  expect(clockTime(DateTime(2026, 1, 1, 8, 5), h24: true), '08:05');
});
test('12-hour: no leading zero, AM/PM, midnight and noon are 12', () {
  expect(clockTime(DateTime(2026, 1, 1, 14, 5), h24: false), '2:05 PM');
  expect(clockTime(DateTime(2026, 1, 1, 0, 0), h24: false), '12:00 AM');
  expect(clockTime(DateTime(2026, 1, 1, 12, 30), h24: false), '12:30 PM');
  expect(clockTime(DateTime(2026, 1, 1, 9, 7), h24: false), '9:07 AM');
});
test('use24Hour', () {
  expect(use24Hour(TimeFormat.automatic, device: true), isTrue);
  expect(use24Hour(TimeFormat.automatic, device: false), isFalse);
  expect(use24Hour(TimeFormat.h12, device: true), isFalse);
  expect(use24Hour(TimeFormat.h24, device: false), isTrue);
});
test('Automatic by default; a written value is read back; junk reads as Automatic', () async {
  expect(await readTimeFormat(), TimeFormat.automatic);
  await writeTimeFormat(TimeFormat.h12);
  expect(await readTimeFormat(), TimeFormat.h12);
  await SharedPreferencesAsync().setString(timeFormatPrefKey, 'nonsense');
  expect(await readTimeFormat(), TimeFormat.automatic);
});
```

In `group_info_test.dart`: existing expectations get `h24: true`; add `muteLabel(DateTime(2026, 11, 17, 8, 5).millisecondsSinceEpoch, now, h24: false)` → `'Until tomorrow, 8:05 AM'`.
In `chat_list_test.dart` add `shortTime`: today 14:05 → `'2:05 PM'` (h24 false) / `'14:05'` (h24 true); 3 days ago → weekday abbreviation either way; 30 days ago → `'M/D'` either way.

- [ ] **Step 2: Run to verify they fail**

Run: `flutter test test/settings/time_format_test.dart test/screens/group_info_test.dart test/screens/chat_list_test.dart`
Expected: compile errors (`time_format.dart` missing, `h24` not a parameter).

- [ ] **Step 3: Implement** `time_format.dart` (mirror `preview_setting.dart`; notifier `build()` returns `readTimeFormat()`), update `shortTime`/`muteLabel` and all four callers. Widget callers pass `h24: MediaQuery.alwaysUse24HourFormatOf(context)`. Delete the old `clockTime` from chat_list.dart and fix imports.

- [ ] **Step 4: Run to verify they pass**

Run: `flutter test test/settings test/screens && dart analyze lib test`
Expected: all pass; analyze reports no issues.

- [ ] **Step 5: Commit** — `feat(app): one clock-time formatter with 12- and 24-hour forms`

### Task 2: The setting applies app-wide, and Settings shows it

**Files:**
- Modify: `app/lib/main.dart` (`FamChatApp.build`'s `builder:`)
- Create: `app/lib/settings/time_format_tile.dart` (a `DisplaySettingsGroup` ConsumerWidget)
- Modify: `app/lib/screens/settings_screen.dart` (insert `const DisplaySettingsGroup()` after `const NotificationSettingsGroup()`)
- Test: `app/test/settings/time_format_tile_test.dart` (new)

**Interfaces:**
- Consumes: `timeFormatProvider`, `TimeFormat`, `use24Hour`, `clockTime` from Task 1.
- Produces: `class DisplaySettingsGroup extends ConsumerWidget`; tile key `Key('settings-time-format')`; `class TimeFormatScope extends ConsumerWidget { const TimeFormatScope({required this.child}); }` that wraps `child` in a `MediaQuery` whose `alwaysUse24HourFormat` is `use24Hour(format, device: MediaQuery.alwaysUse24HourFormatOf(context))`, with `format = ref.watch(timeFormatProvider).value ?? TimeFormat.automatic` (loading or error → Automatic).

- [ ] **Step 1: Write the failing tests** (ProviderScope with `timeFormatProvider.overrideWith(() => FakeTimeFormat(x))`, a fake notifier recording `set` calls, like `FakePreviews` in `test/push/notification_settings_test.dart`)

```dart
testWidgets('TimeFormatScope: 12-hour overrides a 24-hour device', ...);
  // MediaQuery(data: MediaQueryData(alwaysUse24HourFormat: true)) > TimeFormatScope > Builder
  // reading MediaQuery.alwaysUse24HourFormatOf(context): isFalse with h12, isTrue with automatic.
testWidgets('TimeFormatScope: unreadable setting falls back to the device', ...);
  // fake build() throws → alwaysUse24HourFormatOf == device value, no exception (tester.takeException() is null).
testWidgets('Display group: shows the current choice and changes it', ...);
  // find.text('Time format'); subtitle 'Automatic'; tap Key('settings-time-format') →
  // a dialog/sheet with 'Automatic', '12-hour', '24-hour'; tap '12-hour' → fake.sets == [TimeFormat.h12],
  // subtitle now '12-hour'.
```

- [ ] **Step 2: Run to verify they fail**

Run: `flutter test test/settings/time_format_tile_test.dart`
Expected: compile error (`time_format_tile.dart` missing).

- [ ] **Step 3: Implement.** Group title "Display", `TileIcon(Icons.schedule_rounded)`, title "Time format", subtitle the current choice's label; tapping opens a simple dialog of three radio choices (match the look of other Settings choosers if one exists; otherwise `SimpleDialog` with `RadioListTile`s). In `main.dart` wrap the builder's `WindowFrame(...)` in `TimeFormatScope(child: ...)`.

- [ ] **Step 4: Run to verify they pass, plus the app-level suites that pump `FamChatApp`**

Run: `flutter test test/settings test/screens/settings_screen_test.dart test/screens/text_scale_test.dart test/router_test.dart test/app_test.dart`
Expected: all pass (app tests have no prefs plugin: the scope must fall back silently).

- [ ] **Step 5: Commit** — `feat(app): Time format setting (Automatic, 12-hour, 24-hour)`

### Task 3: The sent time goes under the bubble

**Files:**
- Modify: `app/lib/screens/chats/message_bubble.dart:357-425` (meta row) and `:498-545` (outer column)
- Test: `app/test/screens/message_time_test.dart` (new); keep `conversation_test.dart`, `photo_bubble_test.dart`, `voice_test.dart`, `message_actions_test.dart` passing (they find `pending-icon` and `'edited'`)

**Interfaces:**
- Consumes: `clockTime` from Task 1.
- Produces: the time line widget keyed `Key('time-${message.id}')`; pending icon keeps `Key('pending-icon')`.

Behaviour: `showTime` stays `lastInGroup || pending || failed`. Inside the bubble only "edited" remains (text, photo, video, GIF, voice), shown when `edited && !deleted`. When `showTime`, a row of [time text, pending icon if pending] sits in the outer Column directly under the bubble row (above reactions, the retry button and footer), aligned with the bubble: right edge for mine (small right inset), for theirs indented by `avatarSpace` plus a small inset. Style as today's time: `labelSmall`, `kDisplayFont`, tabular figures, but colour `scheme.onSurfaceVariant` (it's on the chat background now, not the bubble). Take the line's height out of the space between runs (e.g. the last bubble's bottom padding) so a chat doesn't grow much; exact values by eye.

- [ ] **Step 1: Write the failing tests** — pump `MaterialApp(theme: buildTheme(Brightness.light), home: Scaffold(body: MediaQuery(data: MediaQueryData(alwaysUse24HourFormat: false), child: MessageBubble(...))))` with a text message at `DateTime(2026, 1, 1, 14, 5)`.

```dart
testWidgets('last in run: the time is under the bubble, outside it', ...);
  // find.text('2:05 PM') findsOneWidget; it is not a descendant of the bubble's DecoratedBox/Container
  // (find.descendant(of: find.byType(LinkText)...ancestor Container with BoxDecoration, matching: '2:05 PM') findsNothing);
  // tester.getTopLeft(time).dy >= tester.getBottomLeft(bubble).dy.
testWidgets('24-hour device shows 14:05', ...);
testWidgets('not last in run: no time', ...);   // lastInGroup: false → find.byKey(Key('time-<id>')) findsNothing
testWidgets('pending mid-run: time and pending icon under the bubble', ...);
  // state 'pending', lastInGroup: false → time-<id> and pending-icon found, both below the bubble.
testWidgets('edited mid-run: edited inside, no time', ...);
  // edited: true, lastInGroup: false → 'edited' is inside the bubble container; no time-<id>.
testWidgets('theirs with avatar space: time lines up with the bubble', ...);
  // mine: false, avatarSpace: 36 → time left edge >= bubble left edge.
testWidgets('mine: time right-aligned with the bubble', ...);
  // |time right edge - bubble right edge| <= 8.
```

- [ ] **Step 2: Run to verify they fail**

Run: `flutter test test/screens/message_time_test.dart`
Expected: failures (time is inside the bubble today; position asserts fail).

- [ ] **Step 3: Implement** as described above, for all five content variants.

- [ ] **Step 4: Run to verify they pass, plus the full screens suite**

Run: `flutter test test/screens && dart analyze lib test`
Expected: all pass; no issues.

- [ ] **Step 5: Look at it.** Render a short conversation (mine and theirs, a run of three, a photo, a pending message) on a 400×800 phone window and check spacing by eye; take a screenshot for the PR.

- [ ] **Step 6: Commit** — `feat(app): the sent time sits under the bubble`
