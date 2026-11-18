# Games in direct chats — design

Status: approach A chosen by the user on 2026-11-17 (game card + hidden moves + active-game bar).

## Why

The family wants to play simple board games with each other inside FamChat: tic-tac-toe, checkers
and chess. Play is **mostly asynchronous** (a move in the morning, a reply hours later, a chess game
lasting days) but sometimes live, quick back-and-forth. Games belong to the conversation between two
people, not a separate app.

## Goals

- Tic-tac-toe, checkers and chess, playable in **direct (1:1) chats only**.
- Starting a game puts **one game card** in the timeline. Moves update that card; they never appear
  as their own bubbles.
- While a game is unfinished, a slim **active-game bar** sits at the top of the DM
  (`♟ Chess with Mom · Your turn` / `· Mom's turn`). Tapping it, or the card, opens the full board.
- Each move **notifies the other person** (push + unread), so async play doesn't stall. Live play
  feels instant because moves ride the existing WebSocket.
- Games sync across all of a user's devices and survive reinstall like any history.
- End states: win, loss, draw (stalemate/threefold/50-move/agreed in chess; full board in
  tic-tac-toe; checkers draw by agreement), and **resign**. A finished card offers **Rematch**.

## Non-goals

- Groups (the user said DMs only), spectators, more than two players.
- Playing against the computer, hints, move clocks/timers, ratings or stats.
- Undo/takeback.
- Server-side game logic or validation.

## Anti-goals (a failure even if it "works")

- Moves cluttering the conversation (the reason option B was rejected).
- Game content readable by the server: moves are end-to-end encrypted like every message.
- The two players' devices disagreeing about the board. State must be a pure function of the
  messages both sides have, in server order.
- A long async game being hard to find: it must always be one tap away while unfinished.

## Constraints (from the existing code)

- Every message is an encrypted envelope whose plaintext is JSON with a `kind`
  (`app/lib/chat/plaintext.dart`). The server sees only the envelope, assigns a gap-free per-chat
  `seq`, and fans out. **No server change is needed.**
- Reactions, edits and deletes are "change" messages: they carry a `target` message id, are stored
  with `targetId`, are hidden from the timeline, and are sent `silent` (no push)
  (`message_changes.dart`, `chat_db.dart`, `hub.ts`).
- Unknown kinds are stored as `unknown` with the full body and re-parsed after an update
  (`ChatSync` `unknownKind()`), so a newer kind recovers once the app updates.
- Push previews are made on-device from the envelope (`push/preview.dart`); `mediaLabel` maps kinds
  to labels.

## Approaches considered

- **A. Game card + hidden move messages + active-game bar — chosen.** Chat stays readable; one tap
  to the board; costs one extra bar widget.
- **B. Every move posts a board snapshot message.** Simplest, but a 60-move chess game buries the
  conversation. Wrong fit for mostly-async play.
- **C. A separate Games tab per DM.** Cleanest separation, most new screens, and turns are easy to
  miss; games stop feeling like part of the chat.

## Design

### Wire format (new plaintext kinds)

- `game` — starts a game. `{kind:"game", game:"tictactoe"|"checkers"|"chess", first:<userId>}`.
  `first` is who moves first (X / dark / white). The game's id is this message's id.
- `move` — one action in a game. `{kind:"move", target:<game message id>, game:<same game name>, ply:<int>, action:...}`
  (`game` is repeated so labels and previews don't need to look up the game message.)
  - `ply` is the 0-based index of this move in the game; it lets clients drop stale/duplicate moves.
  - `action` is one of:
    - `{"type":"play", ...game-specific move}`:
      - tic-tac-toe: `{"cell":0..8}`
      - checkers: `{"path":[sq, sq, ...]}` (start square then each landing square; a multi-jump is
        one move)
      - chess: `{"uci":"e2e4"}` (promotion as `e7e8q`)
    - `{"type":"resign"}`
    - `{"type":"draw_offer"}`, `{"type":"draw_accept"}`, `{"type":"draw_decline"}` (chess and
      checkers). Draw offers/answers don't consume a ply for board purposes but are ordered by `seq`;
      a pending offer is cleared by the offerer's opponent making a play.
- Rematch is simply a new `game` message with `first` set to the other player.

### Deriving state (the core rule)

Game state = replay of the game's `move` messages **in `seq` order**, applying each only if:
the sender is a member of the DM, it's the sender's turn (or a resign/draw action they're allowed),
`ply` equals the next expected ply, the game isn't over, and the move is legal. Anything else is
ignored (not shown, not an error). Because both devices see the same messages in the same order and
apply the same pure rules, they always agree. This also resolves two of my own devices racing: the
first move the server stored wins; the second has a stale `ply` and is ignored.

Pending (unacked) local moves show optimistically; if, after ack and sync, it turns out to be
ignored, the board snaps back to derived state (rare: only the multi-device race).

### Rules engines

A small pure-Dart `GameRules` interface per game (initial state, legal moves, apply, outcome).
- Tic-tac-toe and **American checkers** (8×8, men move forward diagonally, **captures are
  mandatory**, multi-jumps must be completed, a man reaching the far row is crowned and the move
  ends, kings move one square any diagonal direction; win when the opponent has no legal move)
  are written in-house.
- Chess uses the pub.dev `chess` package, **pinned at exactly 0.8.1** (MIT, a port of chess.js;
  resolves under Dart 3). `dartchess` was ruled out: it is GPL-3, which doesn't fit store-distributed
  apps. It provides legality, check/mate/stalemate, castling, en passant, promotion,
  threefold repetition and the 50-move rule.
- Engines are thoroughly unit-tested; they're the part that must never disagree between devices.

### UI

- **Starting:** a "Game" entry in the DM composer's attach/plus menu (hidden in groups) opens a
  sheet with the three games. Starter moves first. Only **one unfinished game per DM**: if one
  exists, the sheet says so and offers to open it.
- **Game card** in the timeline (where the `game` message landed): small live board thumbnail, game
  name, status line (`Your turn`, `Mom's turn`, `You won`, `Draw`), and Rematch when finished.
  Tap → board.
- **Active-game bar** pinned under the DM header while a game is unfinished; tap → board.
- **Board screen** (full-screen route on phones, a sheet/dialog on wide screens): the board from the
  viewer's side (my pieces at the bottom), tap-to-select then tap-to-move with legal targets
  highlighted (drag optional, builder's call), last move highlighted, whose turn, resign and
  draw-offer actions behind a menu with confirmation, promotion picker for chess. Board updates live
  as the other person moves.
- Visual style follows the app's existing theme (light/dark), with clean flat boards and pieces;
  chess pieces drawn as the Unicode chess glyphs from a bundled **Noto Sans Symbols 2** font (OFL,
  license file alongside the other fonts), so they look identical on every platform.

### Notifications, unread, chat list

- `game` and `move` (play, resign, draw actions) are **sent non-silent**, so they push and count as
  unread like a message. (They do not stay "change" kinds for unread counting.)
- Notification preview labels (with previews on), worked out on the device from the stored game:
  `game` → `🎲 Started a game of Chess`; a play → `♟ Your turn in Chess`, or when it ends the game
  `♟ You lost at Chess` / `🤝 Draw in Chess`; resign → `🏳 Resigned at Chess` (you win); draw offer →
  `🤝 Offered a draw in Chess`; accept → `🤝 Draw in Chess`; decline → `Declined a draw in Chess`.
  If the game message isn't stored on the device yet, a play falls back to `♟ Moved in Chess`. With
  previews off, the generic text, as today.
- The chat list's "last message" line uses short labels that don't depend on game state:
  `🎲 Started a game of Chess`, `♟ Moved in Chess`, `🏳 Resigned at Chess`, `🤝 Offered a draw in Chess`,
  `🤝 Accepted a draw in Chess`, `Declined a draw in Chess` (prefixed `You: ` for your own, as today).
- Opening the board marks the chat read.

### Older app versions

An older client shows a `game` and each `move` as an unsupported message until it updates; after
updating, the stored bodies re-parse and the game appears correctly. Accepted: the family's apps
auto-update. No version gate.

### Testing

- Unit tests per rules engine (including checkers forced/multi-jump and chess special moves via the
  package), and for state derivation: out-of-order/duplicate/stale-ply/illegal/wrong-sender moves
  are ignored, resign and draw flows, one-unfinished-game rule.
- Widget tests for the card, bar and board interaction.
- Plaintext encode/decode round trips for the new kinds; preview labels.

### Edge cases (settled during review — my calls)

- **Two games started at once:** the `game` message with the lower `seq` is the active one; any other
  `game` sent while one was unfinished renders as an inert "Game not started" card and its moves are
  ignored.
- **`ply` on resign/draw actions:** they carry the current next ply (and don't advance it); a
  `draw_accept`/`draw_decline` only counts if an offer from the opponent is pending.
- **Checkers squares:** numbered 0–31 over the dark squares, row by row from the side of the player
  who moves first. This is permanent wire format; document it, and the other move encodings, in
  `docs/protocol.md`.
- **Automatic chess draws** (threefold, 50-move, insufficient material, stalemate) end the game; the
  chess package version is pinned so every device applies identical rules.
- **Game cards can't be edited or deleted**; a `move` whose target is missing or isn't a `game` is
  ignored.
- **Hiding moves:** `move` joins the timeline's hidden kinds (alongside reaction/edit/delete) but,
  unlike them, still counts as unread and is sent non-silent.
- Games are offered only in direct chats that still have another member.

## Left to the builder

- Exact board/piece visuals within the app's theme, animations, drag vs tap-only.
- Where derived game state is cached (recompute from messages vs. a memoized provider); recompute is
  fine at these sizes.
- Wording of labels beyond the examples above.
