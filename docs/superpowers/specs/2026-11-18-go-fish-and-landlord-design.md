# Go Fish and Landlord (a property-trading game) — design

Status: approved by the user on 2026-11-18 ("your gut is good"). The user chose approach A
("yes, go with A"), asked for full property-game rules for long family games ("full rules, it's
for longer games with my family"), and picked a long game running alongside one quick game.
Builds on `2026-11-17-dm-games-design.md` and `2026-11-18-more-games-design.md`. Everything in
those still holds unless this doc says otherwise: the wire format, replay in `seq` order, two
players in direct chats only, the card, bar, board screen, pokes,
notifications and older-client behaviour.

## Why

The family plays the six current games and wants deeper ones. The user asked for **Go Fish** and a
**generic Monopoly**, with full rules, for long games played over days.

## Goals

- **Go Fish**: the two-player card game with hidden hands and a shuffled deck.
- **Landlord**: a full-rules property-trading game. It has dice, two card decks, buying, auctions,
  rent, colour sets, houses and hotels, mortgages, jail, trading between players and bankruptcy.
- Both games are built on the existing `Board` interface and replay, so pokes, "Your turn" lines,
  the bar, pushes, resign and rematch work unchanged.
- Shipped as two PRs: Go Fish first (it introduces the shared seed), then Landlord (with the
  long-game slot).

## Non-goals

- More than two players, and games in group chats. These are unchanged from the earlier designs;
  the user saw this limit before choosing approach A.
- Computer opponents, house-rule toggles and a timed or shortened mode. The user asked for full
  rules.
- Secrecy from a determined player. Hands are hidden by the UI only (see "Luck and secrets").
- Trademarked names, art or board text: no "Monopoly", Mr. Monopoly, Chance or Community Chest,
  Boardwalk, Park Place, and so on.

## Anti-goals

- The two phones disagreeing about a roll, a shuffle or a balance. Everything must be a pure
  function of the messages, identical on the VM (iOS, Android, desktop) and on the web.
- Landlord being unreadable when you come back after a day. You must be able to see what happened
  since your last turn without scrolling the chat.
- Moves cluttering the chat. Plays stay hidden; the timeline keeps collapsing runs of play lines.

## Approaches

- **A. Both games behind the existing `Board` interface (chosen).** `Board.toMove` becomes
  "whoever must act now". It may switch mid-turn, to the opponent for an auction bid, a trade
  answer or a debt they owe. Every Landlord action is a `play` move by that side. All the
  existing plumbing carries over.
- **B. Landlord as a separate system** with its own message kind and screens. It would have more
  room for back-and-forth, but it would duplicate pokes, labels, the bar and resign, and behave
  unlike the other games. Rejected.
- **C. The mover's phone rolls and sends the result.** Simpler, but a modified app could choose
  its rolls, and it gains nothing over a shared seed. Rejected.

## One long game alongside one quick game (the user's choice)

The earlier designs allow one unfinished game per DM. A Landlord game can last a week, so the
user chose to give long games their own slot:

- Each `GameType` is either **long** (Landlord only) or **quick** (the other seven, Go Fish
  included). A DM can have one unfinished game of each kind at once.
- The inert rule becomes per kind: a `game` message is inert if an unfinished, non-inert game of
  the **same kind** was running when it landed (lower `seq`). A quick game never makes a long one
  inert, or the other way round. This is the only change to `deriveGames` and `GameCache` beyond
  the seed.
- `activeGame` gains a kind; callers that meant "the" game now ask for the right kind. The start
  sheet lists every game; a game whose kind is busy shows "Finish your current game first" with
  **Open** for that row's kind only. Rematch checks the same kind.
- The active-game bar shows up to two rows, long game first, each tappable as today.
- Older versions don't know Landlord's wire name, so they never count it as a game; they're
  unaffected.

## Luck and secrets (both games)

### Wire change: `seed`

`game` messages gain an optional `seed`, an integer in `0..4294967295` (an unsigned 32-bit value,
exact as a JSON number):

```json
{"kind":"game","game":"gofish","first":"<userId>","seed":3735928559}
```

- The sender's phone picks it with `Random.secure()` when starting a game or a rematch.
- `GameBody` gains `int? seed`. It is decoded with `wireInt` and must be in range. A `gofish` or
  `landlord` body without a valid seed is malformed: it decodes to `GameBody` with `seed == null`,
  and replay treats that game as inert. Older game types ignore the seed and don't send one.
- `initialBoard(type)` becomes `initialBoard(type, seed)`. `_Game` and `GameCache` pass the seed
  through. The cache already re-derives when the body changes.
- `docs/protocol.md` "Games" documents `seed`, `gofish` and `landlord`.

### The shared random generator

This is a permanent part of the wire format: changing it would change every past game.

- **xorshift32**, state = the seed, or `0x9E3779B9` if the seed is 0. Each step:
  `x ^= (x << 13) & 0xFFFFFFFF; x ^= x >> 17; x ^= (x << 5) & 0xFFFFFFFF`. Return `x`, an unsigned
  32-bit value.
- It uses only shifts, xor and masks, never multiplication, so web (32-bit bitwise) and VM
  (64-bit int) agree. A test pins the first 10 outputs for 3 seeds as golden values. That test
  also runs with `flutter test --platform chrome`, or if that isn't practical, with an equivalent
  dart2js check.
- `randInt(n)` = `next() % n`. The small modulo bias is accepted.
- **Shuffle** = Fisher–Yates from the end: for `i` from `len-1` down to 1, swap `i` with
  `randInt(i + 1)`.
- The generator state lives in the board, so a board is still an immutable value.

### Hidden information

Both phones hold the full state, including the opponent's hand and the deck order. The UI never
shows the opponent's hidden cards or upcoming cards, and push and timeline text never reveals
them. Getting at them would take a debugger; that's accepted for a family app.

## Go Fish

Wire name `gofish`, title `Go Fish`. `drawOffers` false. Resign and rematch work as usual.

### Setup

- Standard 52-card deck. Cards are `0..51`: rank = `card ~/ 4 + 1` (1 = ace … 11 = J, 12 = Q,
  13 = K), suit = `card % 4` (♠ ♥ ♦ ♣).
- The deck starts in order `0..51` and is shuffled with the seed. Deal 7 cards each, alternating,
  starting with `first`, from the top (index 0). The rest is the stock, drawn from the top.
- Any four of a kind dealt is laid down as a book at once.

### A turn

- Move: `{"rank": 1..13}`. It is illegal unless the mover holds at least one card of that rank.
- If the opponent holds that rank, they hand over all of them and **the mover goes again**.
- Otherwise it's "Go fish": the mover draws the top stock card. If it is the asked rank, the mover
  goes again; otherwise the turn passes. If the stock is empty, the turn just passes.
- After every play, any four of a kind in either hand becomes a book for its holder.
- **Empty hands:** after a play, a player whose hand is empty draws one card from the stock, if
  there is one. If the player to move has no cards and the stock is empty, the turn passes to the
  other player. This is derived from the position, like Reversi's automatic pass.
- The game ends when all 13 books are made. Whoever has more books wins (reason `books`). With 13
  books there can't be a tie.

### What's shown

- My hand, fanned and grouped by rank. Tapping a rank asks for it. Only ranks I hold are tappable,
  and only on my turn.
- The opponent's card count (card backs), the stock count, and both players' books.
- A short log of the last few asks, all public information: "Mom asked for 7s — you gave 2",
  "You asked for Kings — Go fish", "You drew a King and go again". A card drawn on "Go fish"
  is never named to the opponent unless it matched.
- The board keeps an event list for the log, as Landlord does (see Landlord, "Event log").

## Landlord

Wire name `landlord`, title `Landlord` (after *The Landlord's Game*, the public-domain 1904
ancestor of this genre). `drawOffers` **true**: an agreed end is a draw. Resign and rematch work
as usual. The first player in the `game` message goes first.

### The board (permanent wire format)

There are 40 spaces, `0..39`, clockwise from Start. The layout, prices and rents follow the
classic structure, because numbers and mechanics aren't protected. **All names are our own.** The
builder picks the final names and colours; the table below fixes everything else.

| # | Space | Price | Rent: base, 1–4 houses, hotel | House cost |
|---|---|---|---|---|
| 0 | Start (collect 200 when passing or landing) | | | |
| 1 | Brown A | 60 | 2, 10, 30, 90, 160, 250 | 50 |
| 2 | Family Fund card | | | |
| 3 | Brown B | 60 | 4, 20, 60, 180, 320, 450 | 50 |
| 4 | Income Tax: pay 200 | | | |
| 5 | Station 1 | 200 | 25 / 50 / 100 / 200 for 1–4 stations owned | |
| 6 | Light Blue A | 100 | 6, 30, 90, 270, 400, 550 | 50 |
| 7 | Luck card | | | |
| 8 | Light Blue B | 100 | 6, 30, 90, 270, 400, 550 | 50 |
| 9 | Light Blue C | 120 | 8, 40, 100, 300, 450, 600 | 50 |
| 10 | Jail / Just Visiting | | | |
| 11 | Pink A | 140 | 10, 50, 150, 450, 625, 750 | 100 |
| 12 | Utility 1 | 150 | 4× the dice, or 10× if both utilities are owned | |
| 13 | Pink B | 140 | 10, 50, 150, 450, 625, 750 | 100 |
| 14 | Pink C | 160 | 12, 60, 180, 500, 700, 900 | 100 |
| 15 | Station 2 | 200 | as stations | |
| 16 | Orange A | 180 | 14, 70, 200, 550, 750, 950 | 100 |
| 17 | Family Fund card | | | |
| 18 | Orange B | 180 | 14, 70, 200, 550, 750, 950 | 100 |
| 19 | Orange C | 200 | 16, 80, 220, 600, 800, 1000 | 100 |
| 20 | Free Parking (nothing happens) | | | |
| 21 | Red A | 220 | 18, 90, 250, 700, 875, 1050 | 150 |
| 22 | Luck card | | | |
| 23 | Red B | 220 | 18, 90, 250, 700, 875, 1050 | 150 |
| 24 | Red C | 240 | 20, 100, 300, 750, 925, 1100 | 150 |
| 25 | Station 3 | 200 | as stations | |
| 26 | Yellow A | 260 | 22, 110, 330, 800, 975, 1150 | 150 |
| 27 | Yellow B | 260 | 22, 110, 330, 800, 975, 1150 | 150 |
| 28 | Utility 2 | 150 | as utilities | |
| 29 | Yellow C | 280 | 24, 120, 360, 850, 1025, 1200 | 150 |
| 30 | Go to Jail | | | |
| 31 | Green A | 300 | 26, 130, 390, 900, 1100, 1275 | 200 |
| 32 | Green B | 300 | 26, 130, 390, 900, 1100, 1275 | 200 |
| 33 | Family Fund card | | | |
| 34 | Green C | 320 | 28, 150, 450, 1000, 1200, 1400 | 200 |
| 35 | Station 4 | 200 | as stations | |
| 36 | Luck card | | | |
| 37 | Dark Blue A | 350 | 35, 175, 500, 1100, 1300, 1500 | 200 |
| 38 | Luxury Tax: pay 100 | | | |
| 39 | Dark Blue B | 400 | 50, 200, 600, 1400, 1700, 2000 | 200 |

Every property mortgages for half its price. Unmortgaging costs the mortgage value plus 10%,
rounded up to a whole dollar.

### Building and mortgaging rules (classic; builder's call, settled from the review)

- You may build only on a complete colour set that you own with nothing in it mortgaged. Build
  evenly: a property may not get its next house while another in the set has fewer. A hotel
  replaces 4 houses and needs 4 on every property in the set.
  Stations and utilities can't be built on.
- A house sells back for half its cost; so does a hotel. Sell evenly: the reverse of building.
  Selling a hotel leaves 4 houses on the property.
- A property can be mortgaged only when no property in its colour set has buildings.
- Rent with mortgages: unimproved properties in a fully owned set still charge double rent even if
  another property in the set is mortgaged. Mortgaged stations and utilities still count toward
  the "how many owned" rent. A mortgaged property charges no rent.
- Raising cash: `sell` and `mortgage` are allowed for whoever is acting in every phase except
  `trade`: the turn player in `roll`, `buy` and `end`, the bidder whose turn it is in `auction`,
  and the debtor in `debt`. That lets a player mortgage to afford a buy or a bid. `build`,
  `unmortgage` and `offer` stay limited to the turn player in `roll` and `end`.
- Automatic bankruptcy counts everything sellable under these rules.

### Cards (permanent wire format)

There are two 16-card decks, **Luck** and **Family Fund**. Each is shuffled with the seed at setup
(Luck first, then Family Fund, after the generator has been created). Cards are drawn from the
top and go back to the bottom. A "Get out of jail free" card leaves the deck while a player holds
it, and goes to the bottom when used. The builder writes the card wording; the effects are fixed.

**Luck:** advance to Start · advance to Red C (#24) · advance to Pink A (#11) · advance to the
nearest utility (if it's owned, pay 10× a fresh roll of the dice) · advance to the nearest station
(if it's owned, pay double rent) ×2 · collect 50 · get out of jail free · go back 3 spaces · go to
jail · pay 25 per house and 100 per hotel · pay 15 · advance to Station 1 (#5) · advance to Dark
Blue B (#39) · pay the other player 50 · collect 150.

**Family Fund:** advance to Start · collect 200 · pay 50 · collect 50 · get out of jail free · go
to jail · collect 100 · collect 20 · collect 10 from the other player · collect 100 · pay 100 ·
pay 50 · collect 25 · pay 40 per house and 115 per hotel · collect 10 · collect 100.

"Advance to" moves clockwise and collects 200 when passing Start. "Go to jail" never passes
Start. The deck order above is the order before shuffling.

### Money and the bank

- Each player starts with 1500. All amounts are whole dollars. The bank never runs out of money.
- The bank never runs out of houses or hotels (since rules 4; it had 32 and 12 before).
- Free Parking does nothing. Taxes go to the bank.

### Turn flow and who acts

The board has a phase. `toMove` follows from it, in this order:

1. If a player owes a debt they can't pay yet, the **debtor** acts (phase `debt`).
2. During an auction, the **bidder whose turn it is to bid** acts (phase `auction`).
3. During a trade offer, the **player receiving the offer** acts (phase `trade`).
4. Otherwise the **turn player** acts (phases `roll`, `buy` and `end`).

Every action is `{"type":"play","a":"<action>", ...}`. An action not allowed in the current phase,
or for that side, is illegal (`play` returns null), like any other illegal move.

**Turn player, phase `roll`** (before rolling):
- `roll`: roll two dice from the generator and resolve (below).
- In jail only: `pay_bail` (pay 50, leave jail, stay in `roll`) or `use_card` (spend a get out of
  jail free card, then the same).
- Management, allowed in `roll` and `end`: `build {space}`, `sell {space}` (sell one house, or
  break down a hotel; see "Building and mortgaging rules"), `mortgage {space}`,
  `unmortgage {space}`, and `offer {...}` (see Trading). `sell` and `mortgage` are also allowed
  in other phases, as listed there.

**Resolving a roll:**
- **In jail:** doubles leave jail and move by the roll, with no extra roll. Otherwise the player
  stays, and on the third failed attempt they pay 50 (as a debt if needed) and move by the roll.
- **Not in jail:** a third doubles in a row goes straight to jail. Otherwise move, collecting 200
  on passing or landing on Start, then apply the space:
  - **Unowned property:** phase `buy`.
  - **Owned by the other player, not mortgaged:** pay rent. Rent is the base rent ×2 on an
    unimproved full colour set; stations and utilities follow the table. Rent is automatic: the
    owner doesn't have to ask.
  - **Tax:** pay. **Card:** draw and apply it; a move from a card resolves the new space too.
    **Go to Jail:** jail; the turn ends after this.
- Then: doubles (and not jailed) → back to `roll`; otherwise → `end`.

**Phase `buy`:** `buy` (only with enough cash; the property is the player's) or `decline` (starts
an auction). Either one then continues as above (to `roll` on doubles, otherwise `end`).

**Phase `end`:** management actions, then `end_turn`. The other player becomes the turn player in
`roll`.

### Auctions

- When a property is declined, an auction starts. The decliner bids first; the bidders alternate.
- `bid {amount}`: must be more than the current high bid and no more than the bidder's cash.
  `pass`: drop out. Once one player passes while a bid stands, the other player wins at their bid.
  If the first bidder passes with no bid, the other player may bid or pass; two passes with no bid
  leaves the property with the bank.
- Afterwards the turn player continues where they were (to `roll` on doubles, otherwise `end`).

### Trading

- `offer {give: {cash, spaces[], cards}, get: {cash, spaces[], cards}}` (the turn player only, in
  `roll` or `end`). Here `cards` is a count of get out of jail free cards. The offer must be
  possible right now: each side owns what it gives and has the cash. No property in a colour set
  with buildings may be traded. At least one side must give something.
- Phase `trade`: the receiver plays `accept` or `reject`. On accept the exchange happens. A
  mortgaged property that changes hands costs its new owner 10% of the mortgage value at once,
  rounded up, as a debt if needed. The property stays mortgaged. Either way, the turn player is
  back in the phase they offered from.
- There are no counter-offers in one step: rejecting and making your own offer on your turn does
  the same job.

### Debt and bankruptcy

- When a payment is due (rent, tax, a card, bail, mortgage interest), it is paid at once if the
  payer has the cash. Otherwise the payer enters `debt`, owing the amount to the bank or to the
  other player.
- In `debt`, the debtor may `sell`, `mortgage` or `bankrupt`. As soon as their cash covers the
  debt it is paid automatically, and play resumes where it was. That may be in the middle of the
  *other* player's turn: a birthday-style card can make the non-turn player owe money.
- If the debtor has nothing left to sell or mortgage and still can't pay, they go bankrupt
  automatically. The other player wins (reason `bankrupt`).
- Bankruptcy always ends the game in a two-player game, so there's no handing over assets.

### Ending

- Bankruptcy (reason `bankrupt`), resign, or an agreed draw. `Outcome` reasons gain `books`
  (Go Fish) and `bankrupt` (Landlord).

### Event log

The board keeps a list of recent events from each play, all public: "Mom rolled 4+3 → Orange B,
paid you 14", "You bought Red A for 220", "Auction: Mom won Pink B for 90", "Trade accepted",
"Mom drew Luck: go back 3 spaces". The game screen shows the events since my last action at the
top ("While you were away"), and the full recent log on demand. To keep memory bounded, the board
keeps the last 200 events; old ones drop off.

### Screen

This is a guide; the builder makes the final layout calls.

- A square board of 40 spaces around the edge, using colour bands, owner markers, house and hotel
  pips, mortgaged spaces dimmed and both tokens. The centre shows the dice, both balances, and the
  current phase's action buttons (Roll, Buy for 220 / Auction, Bid, End turn, Accept / Reject).
- Tapping a space opens its card: price, rent table, owner, houses, and Build / Sell / Mortgage /
  Unmortgage when they're legal for me now.
- A "My properties" sheet and a trade composer (pick spaces, cash and cards on each side).
- It has to work on a phone in portrait: the board fills the width, and the details live in
  sheets. On desktop the log can sit beside the board.
- Prices show as `$`. The colours come from the theme where they can; the colour groups can use
  fixed colours.

## Notifications and timeline

- Existing labels apply unchanged. A play after which it's still the sender's turn says
  `♟ Moved in {Title}`; otherwise it says `♟ Your turn in {Title}`. A game end is labelled by the
  winner.
- Accepted: a Landlord turn can send several pushes (roll, buy, end turn, and each auction bid),
  like a burst of chat messages. The timeline already collapses runs of play lines into one.
- Push and timeline text never contains hidden information (Go Fish hands or draws).

## Older versions

Older versions show the new games as "Unsupported message" and recover after updating, as with
earlier games. An older version opening a chat with a `seed` on an old game type is unaffected,
because new phones never send one there.

## Testing

- Golden values for the generator and the shuffle, on the VM and on the web.
- Go Fish: dealing, asks with and without a match, a lucky draw, books, empty hands, an empty
  stock, and the end.
- Landlord: each phase and action, legal and illegal. That covers rent (sets, stations, utilities
  and houses), every card effect, jail (all three ways out and the third failed roll), triple
  doubles, even building and selling, the house and hotel limits, mortgage interest on trades,
  auctions (every pass pattern), debts in and out of turn, and automatic bankruptcy. Add a long
  replay test: a few hundred random legal actions from a fixed seed must produce identical state
  through `deriveGames` and `GameCache`.
- Widget tests that the opponent's hand is never rendered.

## Left to the builder

Space and card names (our own; nothing from the trademarked game), colours, token style, glyphs
for the game picker and bar (not emoji; Noto Sans Symbols 2 or an icon), animations (dice, card
flips), and the exact layout of the screens and sheets within the guidance above.
