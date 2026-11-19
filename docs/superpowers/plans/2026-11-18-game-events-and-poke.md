# Game moves and pokes in the timeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Plays and pokes show as centred event lines in the chat timeline, pokes can be sent from `GameBar`, and both notify.

**Architecture:** `game_state.dart` gains a replay that records, per `play` row, the game state after it (or nothing when the rules ignored it). `labels.dart` turns rows plus those results into timeline events (`gameEventsOf`), collapsing play runs. `conversation_view.dart` renders them through `GameEventLine` (new `suffix` and `poke` options). `GameBar` becomes stateful and gets the Poke button.

**Tech Stack:** Flutter, Riverpod, drift; `flutter test --concurrency=2`.

**Spec:** `docs/superpowers/specs/2026-11-18-game-events-and-poke-design.md`

## Global Constraints

- Play line: `♟ {who} moved in {Game}`; end: `🏆 {who} won {Game}` / `🤝 Draw in {Game}`; suffix ` · Your turn` bold, tertiary.
- Poke wire: `move`, action `{'type': 'poke'}`, target game id, ply = current ply, non-silent.
- Poke lines: sender `👉 You poked {Name} · {Game}`; recipient `👉 {Name} poked you · Your turn in {Game}`; tertiaryContainer fill, onTertiaryContainer text.
- Push `👉 Poked you · your turn in {Game}`; list `👉 Poked in {Game}`.
- Button `👉 Poke`; cooldown 10 minutes from my newest poke (by `createdAt`) in that game, label `Poked · {m}m` (rounded up), refreshed each minute; snackbar `Poked {first name}`.
- `flutter test --concurrency=2` only; don't touch pubspec.lock.

## Review Focus

- Winner of a game ended by the loser's final play (Reversi, Dots and Boxes): the win line names the winner, not the sender. Test in Task 2.
- A read-only chat (other person left the family): no Poke button. Test in Task 4.
- A pending (not yet sent) play still gets a line, and a failed one does not. Covered by the replay skipping `failed` rows like `deriveGames`.
- A run of plays split across days still collapses to the newest one (day separators are derived from the remaining rows). Test in Task 2.
- A poke must not count as a play for `gamePushLabel` replay nor change `GameState`. Test in Task 1.

---

### Task 1: Replay results per play, and poke ignored by state

**Files:** Modify `app/lib/games/game_state.dart`; Test `app/test/games/game_state_test.dart`

**Interfaces:** Produces `Map<String, GameState> playResults(List<MessageRow> rows, List<String> memberIds, {bool direct = true})` — move row id → frozen state right after that play, only for `play` rows the rules applied (ply grew). Same walk as `deriveGames` (share it).

- [ ] Test: `playResults` has entries for legal plays with correct ply/outcome; no entry for stale-ply or illegal play; a poke row leaves `deriveGames` state equal to without it.
- [ ] Run, see fail; implement; run, pass; commit.

### Task 2: Timeline events in labels.dart

**Files:** Modify `app/lib/games/labels.dart`; Test `app/test/games/labels_test.dart`

**Interfaces:** Produces
`typedef GameEvent = ({String gameId, String text, String? suffix, bool poke});`
`Map<String, GameEvent> gameEventsOf(List<MessageRow> messages, Map<String, GameState> plays, List<GameState> games, String? me, String Function(String userId) nameOf, bool Function(MessageRow) shownOtherwise)` — `nameOf` gives "You"/first name; `shownOtherwise` says whether a non-event row is visible (used to break runs). Collapse: a play line is dropped when the next visible row (event or otherwise) is a play line of the same game. Suffix ` · Your turn` on the newest surviving play line of a game that is unfinished, not inert and has `toMoveUserId == me`. Existing `gameEventOf` keeps resign/draw texts and gains poke.

- [ ] Tests: play/won/draw texts; Reversi loser-final-move names winner; run collapses; text between keeps both; ignored play no line; Your turn suffix only on newest; poke texts for sender and recipient; poke breaks a run; `gameListLabel` and `gamePushLabel` poke texts.
- [ ] Run, fail; implement; pass; commit.

### Task 3: Render in the conversation

**Files:** Modify `app/lib/games/widgets/game_event_line.dart` (`suffix`, `poke`), `app/lib/screens/chats/conversation_view.dart`, add `gamePlaysProvider` in `app/lib/games/providers.dart`; Test `app/test/games/game_ui_test.dart`

- [ ] Update the "plays do not" widget test: a play shows `♟ You moved in Chess`; run of plays shows one line; tapping opens the game.
- [ ] Run, fail; implement; pass; commit.

### Task 4: Poke button on GameBar

**Files:** Modify `app/lib/games/widgets/game_bar.dart`, `app/lib/chat/plaintext.dart` doc comment, `docs/protocol.md` Games section; Test `app/test/games/game_ui_test.dart`

**Interfaces:** `int? lastPokeAt(List<MessageRow> rows, String gameId, String me)` in labels.dart.

- [ ] Tests: button hidden on my turn, shown on Bob's turn, hidden when over and in read-only chat; within cooldown disabled with `Poked · 10m`; tap sends `{'type':'poke'}` with current ply and shows `Poked Bob`.
- [ ] Run, fail; implement; pass; commit.

### Task 5: Verify and PR

- [ ] `flutter analyze` → "No issues found!"; `flutter test --concurrency=2` all pass; push; `gh pr create`.
