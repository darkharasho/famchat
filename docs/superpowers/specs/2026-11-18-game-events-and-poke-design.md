# Game moves and pokes in the timeline

## Why

Owner request 2026-11-18: "a way to poke the person whose turn it is on a shared game", and "the poke
and when a player makes a move should be its own in line message and notification too". Today a play
only redraws the game card; only resigns and draw offers get a timeline line
(`gameEventOf`, `lib/games/labels.dart`). Plays already push "♟ Your turn in X" (`gamePushLabel`,
used by both phone push previews and desktop socket notifications via `lib/push/preview.dart`).

## Approaches

1. **Slim centred event lines (owner picked "A" from the mockups).** Plays and pokes reuse
   `GameEventLine`, the stadium pill resigns already use.
2. Game-card bubbles per move with a mini board (mockup "B"). Rejected by the owner.

## Design

### Plays as event lines

- Every `play` move gets a line: `♟ {who} moved in {Game}`; `{who}` is "You" or the sender's first
  name, as `gameEventOf` does for resigns.
- A play that ends the game reads `🏆 {who} won {Game}` or `🤝 Draw in {Game}` (replay the game the
  way `gamePushLabel` does: state before and after the move).
- The **latest** line of an unfinished game whose next mover is the viewer gets a bold
  ` · Your turn` suffix (tertiary colour, like `GameBar`'s "Your turn").
- **Collapse:** a run of play lines for the same game with no other visible timeline entry between
  them shows only its newest line. A back-and-forth game therefore leaves one line, not dozens.
- Ignored plays (wrong ply or illegal, which `GameState.apply` drops) get no line.
- Tapping a line opens the game, as today.

### Poke

- Wire: a `move` message whose action is `{'type': 'poke'}`, `target` the game id and `ply` the
  game's current ply. It's sent non-silent like other moves, so it pushes and counts as unread.
  `GameState.apply` already ignores unknown action types; no rule changes.
- **Who can poke:** a player of an unfinished, non-inert game while it is the *other* player's
  turn.
- **Cooldown:** 10 minutes from the viewer's own last poke in that game. Read it from the message
  rows (the newest poke by this user in that game, by `createdAt`), so it holds across the
  viewer's devices.
- **Button:** on `GameBar`, right of the status text and before the chevron, a compact
  "👉 Poke" text button shown while poking is allowed. During the cooldown it is disabled and reads
  "Poked · {m}m" (minutes left, rounded up), updating each minute. On tap it sends the poke and a
  snackbar says "Poked {first name}".
- **Line:** a purple-tinted `GameEventLine` variant (tertiaryContainer fill, onTertiaryContainer
  text): sender sees `👉 You poked {Name} · {Game}`, the recipient sees
  `👉 {Name} poked you · Your turn in {Game}`. Pokes never collapse and break a play run.
- **Notification:** `gamePushLabel` returns `👉 Poked you · your turn in {Game}`;
  `gameListLabel` returns `👉 Poked in {Game}` for the chat list.

### Older app versions

They show a poke as "Unsupported message" in the chat list and generic text in a notification, and
don't draw a line. Acceptable for one family that updates together.

## Tests

- **`gameEventOf` / timeline:**
  - The play, win, draw and "Your turn" texts.
  - A run of plays collapses to the newest line.
  - A text message between two plays keeps both lines.
  - Ignored plays produce no line.
- **Poke:**
  - The button is visible only on the opponent's turn and hidden when the game is over.
  - During the cooldown the button is disabled and shows the minutes left.
  - Tapping it sends a `move` with action type `poke`.
  - A poke doesn't change `GameState`.
- **Labels:** `gamePushLabel` and `gameListLabel` produce the poke text.

## Left to the builder

- Exact padding and colour of the poke pill (follow `GameEventLine`).
- Where the collapse is computed: `conversation_view.dart` or `timeline.dart`.
