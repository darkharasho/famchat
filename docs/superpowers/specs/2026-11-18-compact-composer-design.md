# Compact message bar

## Why

In a narrow desktop window the bar shows attach, GIF and game buttons, which squeeze the text
field (owner screenshot 2026-11-18). Fewer buttons give the text more room.

## Approaches

1. **One "+" button and GIFs inside the emoji picker (owner's call, picked).** Same bar on every
   platform and width.
2. Hide buttons only below a width breakpoint. The bar would change shape as the window resizes,
   and on wide windows the clutter stays.
3. A long-press or overflow "…" menu. Harder to discover than a "+".

## Design

- **Bar:** `[+]  [text field with emoji button]  [mic/send]`. The separate GIF and game buttons
  (`conversation_view.dart` `_composer`) go away.
- **"+" (tooltip "Attach")** opens one menu everywhere: "Photos and videos", then "Take a photo"
  and "Record a video" where a camera exists, then "Game" where `_canStartGame`. Phones keep
  today's bottom sheet; desktop and web show it as a popup menu anchored to the "+". Hidden
  while editing, the same as GIF and Game are today.
- **Emoji picker gets two tabs, "Emoji" and "GIFs":** the phone panel (`EmojiPanel`) and the
  desktop popover. The GIFs tab embeds the existing GIF search grid (`lib/gifs/gif_picker.dart`,
  refactored into a widget that the sheet/dialog and the tab share). Picking a GIF sends it as
  `_pickGif` does today and closes the picker. The tab exists only when `gifClientProvider`
  has a client and nothing is being edited.
- Keyboard: Escape still closes the popover; the last-used tab is remembered for the session.
- Tests: update the widget tests that find `Key('start-game')` / the GIF tooltip, and add tests
  for the "+" menu items (with and without camera, with and without game) and the GIFs tab
  sending a GIF.

## Left to the builder

Tab styling (follow the picker's existing look); whether `showGifPicker` stays as a wrapper.
