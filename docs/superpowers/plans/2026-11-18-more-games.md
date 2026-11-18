# More Games Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Four in a Row, Reversi and Dots and Boxes to the games in direct chats.

**Architecture:** Each game is a pure-Dart `Board` (rules) plus a board view, registered in `GameType`, `initialBoard`, the `BoardView` dispatcher and the bar/picker glyph. Messages, state derivation, card, bar, screen and server are unchanged.

**Tech Stack:** Flutter, Riverpod 3; existing `app/lib/games/` framework.

**Spec:** `docs/superpowers/specs/2026-11-18-more-games-design.md` (builds on `docs/superpowers/specs/2026-11-17-dm-games-design.md`)

## Global Constraints

- Wire names `fourinarow`, `reversi`, `dotsandboxes`; titles `Four in a Row`, `Reversi`, `Dots and Boxes`. Append each new `GameType` after `chess` (existing order unchanged).
- Move encodings and numbering exactly as in the spec (permanent wire format); document each in `docs/protocol.md` next to the existing game encodings.
- `drawOffers` is false for all three. `play` returns a new board or null and never mutates or throws on malformed input (non-int, missing key, out of range).
- `toMove` is derived from the position (Reversi automatic pass, Dots and Boxes extra turn), so `deriveGames` needs no change.
- Outcome reasons: Four in a Row `line` / `full`; Reversi `discs`; Dots and Boxes `boxes`.
- Board views follow the existing ones (`app/lib/games/widgets/tictactoe_view.dart`, `board_parts.dart`): theme colours in light and dark, keys `Key('sq-<index>')` (Four in a Row: `Key('col-<n>')` tap targets; Dots and Boxes: `Key('line-<n>')`), thumbnail = no interaction or labels, `onPlay` only with moves `board.play()` accepts, last move highlighted. Glyphs never render as emoji.
- Tests: `cd app && flutter test <path>`; full suite `flutter test -j 2`; `flutter analyze` clean; `dart format` only changed code.

## Review Focus

1. **Reversi pass and end of game:** a position where the side to move has no legal move but the opponent does passes the turn. When neither side can move, the game ends even with empty squares. (Task 2 tests `side with no move passes automatically` and `game ends when neither side can move`.)
2. **Dots and Boxes extra turn:** a line completing two boxes at once claims both and still gives exactly one extra turn. (Task 3 test `double box gives both boxes and one extra turn`.)
3. **Extra-turn push:** after a play that leaves the sender to move, the push says `♟ Moved in Dots and Boxes`, not `Your turn`. (Task 3 test in `labels_test.dart`.)
4. **Four in a Row full column:** playing a full column is illegal, and the view doesn't offer it. (Task 1 tests `full column is illegal` and `tapping a full column does nothing`.)
5. **Older stored games keep working:** adding enum values doesn't change `fromWire` for the old names. (Task 1 test `fromWire still maps tictactoe, checkers, chess`.)

---

### Task 1: Four in a Row

**Files:**
- Create: `app/lib/games/four_in_a_row.dart`, `app/lib/games/widgets/four_in_a_row_view.dart`
- Modify: `app/lib/games/rules.dart` (enum + `initialBoard`), `app/lib/games/widgets/board_view.dart` (dispatch), `app/lib/games/widgets/game_bar.dart` (`gameGlyph`), `app/lib/games/widgets/start_game_sheet.dart` (only if its font choice needs it), `docs/protocol.md`
- Test: `app/test/games/four_in_a_row_test.dart`, `app/test/games/board_view_test.dart` (add cases)

**Interfaces:**
- Produces: `class FourInARowBoard implements Board { static const columns = 7, rows = 6; Side? at(int col, int row); /* row 0 = bottom */ List<(int,int)>? get winningLine; int? get lastCol; }`. Move `{"col": 0..6}`.

- [ ] **Step 1: Write failing tests**: `first player moves first`; `disc falls to the lowest empty cell`; `full column is illegal`; `bad col (7, -1, '3', missing) returns null`; `horizontal, vertical and both diagonal fours win with reason line and winningLine`; `full board with no four is a draw (full)`; `no play after outcome`; `fromWire still maps tictactoe, checkers, chess` and maps `fourinarow`. View tests: `tapping a column sends {col: n}`; `tapping a full column does nothing`; `disabled board ignores taps`.
- [ ] **Step 2: Run** `cd app && flutter test test/games/four_in_a_row_test.dart test/games/board_view_test.dart` → FAIL.
- [ ] **Step 3: Implement** the engine, the view (drawn discs, red for first and yellow for second; tap anywhere in a column; winning four highlighted), and the registrations; add the Four in a Row encoding to `docs/protocol.md`.
- [ ] **Step 4: Run** → PASS; `flutter analyze` clean.
- [ ] **Step 5: Commit** `feat(app): Four in a Row`

### Task 2: Reversi

**Files:**
- Create: `app/lib/games/reversi.dart`, `app/lib/games/widgets/reversi_view.dart`
- Modify: `rules.dart`, `board_view.dart`, `game_bar.dart`, `docs/protocol.md`
- Test: `app/test/games/reversi_test.dart`, `app/test/games/board_view_test.dart` (add cases)

**Interfaces:**
- Produces: `class ReversiBoard implements Board { Side? at(int cell); List<int> legalCells(); /* for toMove */ (int, int) get counts; /* (first, second) */ int? get lastCell; }` plus `@visibleForTesting ReversiBoard.custom(Map<int, Side> discs, Side toMove)`. Move `{"cell": 0..63}`.

- [ ] **Step 1: Write failing tests**: `start position: 28 and 35 second, 27 and 36 first; first to move with 4 legal cells`; `a move flips every bracketed line`; `a cell that flips nothing is illegal`; `occupied or out-of-range cell returns null`; `side with no move passes automatically` (`toMove` stays with the side that has moves); `game ends when neither side can move` (custom position with empty squares left); `more discs wins with reason discs`; `equal discs is a draw`. View tests: `tapping a legal cell sends {cell: n}`; `tapping an illegal cell does nothing`.
- [ ] **Step 2: Run** `flutter test test/games/reversi_test.dart test/games/board_view_test.dart` → FAIL.
- [ ] **Step 3: Implement** the engine (`toMove` after a play = the opponent if they have a legal move, else the mover if they have one, else the game is over) and the view (flat board in theme colours; dark and light discs; legal-move dots on my turn; last placed disc marked; counts shown above the board when not a thumbnail). Register the game and document the encoding.
- [ ] **Step 4: Run** → PASS; `flutter analyze` clean.
- [ ] **Step 5: Commit** `feat(app): Reversi`

### Task 3: Dots and Boxes, plus the extra-turn push label

**Files:**
- Create: `app/lib/games/dots_and_boxes.dart`, `app/lib/games/widgets/dots_and_boxes_view.dart`
- Modify: `rules.dart`, `board_view.dart` (dispatch + new optional `initials` param), `game_bar.dart`, `app/lib/games/widgets/game_screen.dart` (pass initials), `app/lib/games/labels.dart` (`gamePushLabel`), `docs/protocol.md`
- Test: `app/test/games/dots_and_boxes_test.dart`, `app/test/games/board_view_test.dart`, `app/test/games/labels_test.dart` (add cases)

**Interfaces:**
- Produces: `class DotsAndBoxesBoard implements Board { static const size = 4; bool drawn(int line); Side? owner(int box); /* box = row*4+col */ (int, int) get scores; int? get lastLine; }` plus `@visibleForTesting DotsAndBoxesBoard.custom(Set<int> lines, Map<int, Side> owners, Side toMove)`. Move `{"line": 0..39}`.
- Produces: `BoardView` gains optional `final (String, String)? initials;` (first player's, second player's initial). The board screen passes them from the players' display names; the card thumbnail doesn't.
- Consumes: `GameState.toMoveUserId` (Task 5 of the previous plan) in `gamePushLabel`.

- [ ] **Step 1: Write failing tests**: `line numbering: 0 is the top-left horizontal, 19 the bottom-right horizontal, 20 the top-left vertical, 39 the bottom-right vertical` (via the box-to-lines mapping); `drawing a line passes the turn`; `completing a box claims it and the mover goes again`; `double box gives both boxes and one extra turn`; `drawn or out-of-range line returns null`; `all 40 lines drawn ends the game; most boxes wins (boxes); 8-8 is a draw`. View test: `tapping a line sends {line: n}`; `a drawn line can't be tapped`. Labels test: `a play that keeps the sender's turn says ♟ Moved in Dots and Boxes`.
- [ ] **Step 2: Run** `flutter test test/games/dots_and_boxes_test.dart test/games/board_view_test.dart test/games/labels_test.dart` → FAIL.
- [ ] **Step 3: Implement** the engine and the view (dots, drawn lines in the drawer's colour, generous invisible tap targets on undrawn lines, claimed boxes filled with the owner's colour and initial, last line highlighted). Register the game and document the encoding. In `gamePushLabel`, when `after.outcome == null` and `after.toMoveUserId == m.senderId`, return `♟ Moved in $title`.
- [ ] **Step 4: Run** → PASS. Then the whole suite: `cd app && flutter analyze && flutter test -j 2` → no issues, all pass.
- [ ] **Step 5: Commit** `feat(app): Dots and Boxes`
