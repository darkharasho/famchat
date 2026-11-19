# Split game banner (short design)

**Intent.** A direct chat can have a long game (Landlord) and a quick game going at once. Today each
gets its own full-width `GameBar`, stacked above the messages. Show them as one banner split in two,
so two games cost one row.

**Goals.** One card, two halves side by side, a thin divider between. Each half opens its own game,
shows its own turn status (tertiary and bold when it's my move) and its own poke.

**Non-goals.** No change with a single game: the banner stays as it is today (opponent name, text
Poke button with its cooldown label). No change to group chats (no games there).

**Anti-goals.** Halves so cramped they're unreadable on the 380px-wide minimum window.

**Approaches.**
- *Split card (picked).* One `Material` card with two tappable halves. Fits the request.
- Two smaller stacked bars: still two rows, so it misses the point.
- A combined summary line ("2 games · your turn in Landlord"): hides the second game's state and
  needs an extra tap to choose.

**Decided with the user.**
- Halves drop "with <name>": games only live in direct chats, so the opponent is obvious. Each half
  reads `<glyph> <Title> · <status>`, one line, ellipsized.
- Poke becomes a compact icon button in the half whose opponent is to move; the cooldown moves to
  its tooltip ("Poke in 3m"), and the button is disabled while cooling down.

**Left to the builder.** Widget structure (likely a `compact` mode on the existing bar's content plus
a wrapper laying out two halves in one card), keys for tests, the poke icon choice.
