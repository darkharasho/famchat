# Split Game Banner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** With a long and a quick game going in a direct chat, show one banner split in two instead of two stacked bars.

**Architecture:** `GameBar` becomes the card and takes the chat's active games (`List<GameState>`, long first, from `activeGames`). The per-game content and poke logic (today's `_GameBarState`) moves into a `GameBarSegment` with a `compact` flag. One game: one full segment, unchanged. Two games: a `Row` of two `Expanded` compact segments with a 1px divider between them.

**Tech Stack:** Flutter, Riverpod; widget tests via `chatTestWidgets` (test/screens/conversation_test.dart, test/games/game_ui_test.dart).

**Spec:** docs/superpowers/specs/2026-11-19-split-game-banner-design.md

## Global Constraints

- A single game looks and behaves exactly as today: `<glyph> <Title> with <Name> · <status>`, text Poke button (`👉 Poke` / `Poked · Nm`), chevron.
- A compact half reads `<glyph> <Title> · <status>`, one line, ellipsized, with no opponent name and no chevron.
- The status is tertiary w600 when it's my move, as today.
- The compact poke is an `IconButton` keyed `poke` with tooltip `Poke`, or `Poked · Nm` while cooling down (disabled). It shows under the same conditions as today's button.
- The card keeps `Key('game-bar')`; each segment is keyed `Key('game-bar-${game.id}')`.

## Review Focus

1. A 380px-wide window with two games and a poke showing: no overflow (RenderFlex) errors.
2. Tapping each half opens *its* game, not the other.
3. When one game finishes, the banner goes back to the single full layout.
4. Only the half whose opponent is to move shows a poke; a read-only chat shows none.
5. Long game (Landlord) is always the left half.

---

### Task 1: Split card with compact segments

**Files:**
- Modify: `app/lib/games/widgets/game_bar.dart` (GameBar → card; new `GameBarSegment`)
- Modify: `app/lib/screens/chats/conversation_view.dart:1201` (one `GameBar` for all active games)
- Test: `app/test/screens/conversation_test.dart` (replace "a long and a quick game show two bars, long first")
- Test: `app/test/games/game_ui_test.dart` (existing single-game tests must still pass untouched)

**Interfaces:**
- Produces: `GameBar({Key? key, required String chatId, required List<GameState> games})`, asserting `games.isNotEmpty`.
- Produces: `GameBarSegment({Key? key, required String chatId, required GameState game, required bool compact})`, a `ConsumerStatefulWidget` holding today's poke timer and sending state.

- [ ] **Step 1: Write the failing tests** in `conversation_test.dart`, next to the test being replaced. Use its setup: tictactoe `g1` by alice, landlord `g2` by bob.

```dart
chatTestWidgets('a long and a quick game share one split bar, long first', (tester) async {
  await open(tester, messages: [
    plain('g1', 1, alice.userId, GameBody(GameType.tictactoe, alice.userId)),
    plain('g2', 2, bob.userId, GameBody(GameType.landlord, bob.userId, seed: 1)),
  ]);
  expect(find.byKey(const Key('game-bar')), findsOneWidget);
  final left = find.byKey(const Key('game-bar-g2')), right = find.byKey(const Key('game-bar-g1'));
  expect(tester.getCenter(left).dx, lessThan(tester.getCenter(right).dx));
  expect(find.descendant(of: left, matching: find.textContaining('Landlord · ')), findsOneWidget);
  expect(find.descendant(of: right, matching: find.textContaining('Tic-tac-toe · ')), findsOneWidget);
  expect(find.textContaining(' with Bob'), findsNothing);
  // Bob is to move in tic-tac-toe (alice started): its half has the icon poke, Landlord's doesn't.
  expect(find.descendant(of: right, matching: find.byKey(const Key('poke'))), findsOneWidget);
  expect(find.descendant(of: left, matching: find.byKey(const Key('poke'))), findsNothing);
  expect(find.descendant(of: right, matching: find.byType(IconButton)), findsOneWidget);
});

chatTestWidgets('each half of the split bar opens its own game', (tester) async {
  // same two games; tap the Landlord half, expect GameScreen for g2 (GameScreen.gameId == 'g2'),
  // go back, tap the tic-tac-toe half, expect g1.
});

chatTestWidgets('the split bar fits a 380px window', (tester) async {
  // tester.view.physicalSize = const Size(380, 800); devicePixelRatio = 1; reset in addTearDown.
  // same two games; expect(tester.takeException(), isNull).
});
```

Check `GameScreen`'s field name for the game id before writing the second test. Confirm who is to move in Landlord after `GameBody(GameType.landlord, bob.userId, seed: 1)` from an existing Landlord test, and adjust the poke assertions if alice is the viewer and bob is to move there.

- [ ] **Step 2: Run them to verify they fail**

Run: `cd app && flutter test test/screens/conversation_test.dart --plain-name "split bar"`
Expected: FAIL (two `game-bar` widgets; no `game-bar-g2` key).

- [ ] **Step 3: Implement** in `game_bar.dart`. Move `_GameBarState`'s logic into `GameBarSegment`.
   - `compact: false` renders today's row: same padding, text, text poke, chevron.
   - `compact: true` renders the shorter text. The poke becomes `IconButton(key: Key('poke'), icon: Text('👉'), tooltip: minutesLeft > 0 ? 'Poked · ${minutesLeft}m' : 'Poke', visualDensity: compact, onPressed: null while cooling or sending)`, with no chevron and padding `fromLTRB(Space.md, Space.sm, Space.xs, Space.sm)`.
   - Each segment wraps its content in its own `InkWell` → `openGame(context, chatId, game.id)`, keyed `game-bar-${game.id}`.
   - `GameBar` builds the existing `Padding` → `Material` (`Key('game-bar')`, same color, shape and clip).
     - One game: `GameBarSegment(compact: false)`.
     - Two games: `IntrinsicHeight(Row([Expanded(seg0), VerticalDivider(width: 1, thickness: 1, color: s.outlineVariant), Expanded(seg1)]))`.
   - Update the class doc comment to describe the split.
   - In `conversation_view.dart` replace `for (final g in active) GameBar(...)` with `if (active.isNotEmpty) GameBar(chatId: chatId, games: active)`.

- [ ] **Step 4: Run the new and existing game tests**

Run: `cd app && flutter test test/screens/conversation_test.dart test/games/game_ui_test.dart`
Expected: all pass, including the unchanged single-game poke tests (`Poked · 10m` text).

- [ ] **Step 5: Analyze and commit**

Run: `cd app && flutter analyze lib/games lib/screens/chats test/screens test/games`, expecting "No issues found!"

```bash
git add app/lib/games/widgets/game_bar.dart app/lib/screens/chats/conversation_view.dart app/test/screens/conversation_test.dart
git commit -m "Games: a long and a quick game share one split banner"
```

### Task 2: Back to one bar when a game ends

**Files:**
- Test: `app/test/screens/conversation_test.dart`

- [ ] **Step 1: Write the test.** Use `g1` tic-tac-toe plus `g2` Landlord, with tic-tac-toe played to a win: reuse `tttPlays` from game_ui_test, or copy that helper's moves `[0, 3, 1, 4, 2]`. Expect `find.byKey(Key('game-bar'))` once, `find.textContaining('Landlord with Bob')` once, and `find.byKey(Key('game-bar-g1'))` nothing.
- [ ] **Step 2: Run it.** Expected: PASS already, since `activeGames` drops finished games. If it fails, fix in `GameBar`.
- [ ] **Step 3: Commit** with `test: a finished game leaves the full single bar`.
