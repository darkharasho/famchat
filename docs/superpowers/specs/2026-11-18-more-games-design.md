# More games in direct chats — design

Status: approved by the user on 2026-11-18 ("yeah go with those rules").
Builds on `2026-11-17-dm-games-design.md` (games in direct chats). Everything there still holds:
wire format, replay in `seq` order, one unfinished game per DM, the card, bar, board screen,
notifications and older-client behaviour.

## Why

The family liked having games in DMs and asked for three more two-player, turn-based games
where both players see the whole board: **Four in a Row**, **Reversi** and **Dots and Boxes**.

## Goals / non-goals

- Add the three games behind the existing `Board` interface. Each new game is its own rules file
  and board view, plus one entry in the game picker, the bar glyphs and the board dispatcher. There
  are no changes to messages, state derivation, the card, the bar or the server.
- Non-goals: draw offers for these games (they're short; resign is enough), AI opponents, board-size
  options, and trademarked names ("Connect 4", "Othello").

## Approaches

There is one sensible way to do this: plug each game into the existing `Board` interface. Other
options, such as a generic grid-game engine or reworking the dispatchers into a registry, would
add abstraction for three small games without making any of them simpler.

## Rules (permanent wire format)

Wire names: `fourinarow`, `reversi`, `dotsandboxes`. Titles: `Four in a Row`, `Reversi`,
`Dots and Boxes`. For all three, `drawOffers` is false; resign works as for the other games, and so
does Rematch.

### Four in a Row
- 7 columns × 6 rows, with gravity: a disc lands on the lowest empty cell of its column. The first
  player is red, the second yellow.
- Move: `{"col": 0..6}`. A full column, an out-of-range value or a non-int is illegal.
- Four in a line wins (horizontal, vertical or either diagonal); the winning four are highlighted.
  A full board with no line is a draw (`full`). Win reason `line`.
- Both players see the board the same way up (gravity points down for everyone).

### Reversi
- 8×8 board, cells `0..63` row-major (row 0 at the top as displayed; no flip per player).
- Start position (standard): d4/e5 = second (light), d5/e4 = first (dark), with a1 = cell 56 at the
  bottom left. In cell numbers: 28 (e5) and 35 (d4) are light; 27 (d5) and 36 (e4) are dark. Dark
  (first) moves first.
- Move: `{"cell": 0..63}`. Legal only if it flips at least one opposing disc along any of the 8
  directions; all bracketed lines flip.
- **Automatic pass:** if the side to move has no legal move but the opponent does, the turn passes
  to the opponent with no message (`toMove` is derived from the position). The game ends when
  neither side can move. More discs wins (reason `discs`), equal counts are a draw (reason `discs`).
- The UI shows legal-move dots on my turn and both disc counts.

### Dots and Boxes
- 4×4 boxes (5×5 dots), 40 lines. Line index: horizontal lines `0..19` = `row * 4 + col` (rows 0–4
  of dots, top to bottom, cols 0–3); vertical lines `20..39` = `20 + row * 5 + col` (box rows 0–3,
  dot cols 0–4).
- Move: `{"line": 0..39}`; an already drawn line is illegal.
- Completing one or two boxes claims them for the mover, and **the mover goes again**. Otherwise the
  turn passes.
- Ends when all 40 lines are drawn. Most boxes wins (reason `boxes`); 8–8 is a draw (reason
  `boxes`).
- Claimed boxes are filled with the owner's colour and initial (first player red-ish, second blue-ish
  from the theme); the last line drawn is highlighted.

## Notifications

The existing labels already apply. One change for extra turns: a push for a play after which it is
still the sender's turn says `♟ Moved in {Title}`, not `♟ Your turn in {Title}`. Accepted: a long
chain of boxes sends one push per line, like a burst of chat messages.

## Older versions

Older versions show the new games as "Unsupported message", and they recover after updating
(unknown game names decode as unknown and are re-parsed). This is the same as for the first three
games.

## Left to the builder

Exact colours within the theme, bar glyphs for the new games (they must not render as emoji; use
the bundled Noto Sans Symbols 2 font where it has a glyph, or an icon otherwise), and animations.
