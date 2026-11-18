# Colour themes: presets, Light / Dark / System

**Status:** short design. The user picked preset colour schemes with a light and a dark version
each, plus a mode switch, saved per device.

## Goals

- A handful of colour themes to choose from, each with a day (light) and an evening (dark) version.
- A mode switch: System (default), Light or Dark.
- Both apply at once, app-wide, with a short cross-fade (none when motion is reduced).
- Saved on this device only; nothing is synced to the account.
- The current look stays the default and renders exactly as before.

## Non-goals

- Custom colour pickers or user-made themes.
- Theming the app icon, the launch screen, or the signed-out screens (the dusk hero matches the
  launch screen and stays the brand).
- Per-chat themes.

## Presets

A preset is data (`app/lib/theme/presets.dart`): an id, a name, a one-line description and two
`PresetColors` (light and dark). `PresetColors` holds the role colours `app_theme.dart` needs: the
ColorScheme slots (brand ink, the own-message accent and its text-safe version, the link/focus
accent, the surfaces from lowest to highest, body and muted ink, lines, inverse) and the chat
tokens (own bubble and its ink and meta, other people's bubble and border, the chat backdrop).
`schemeFor`, `tokensFor` and `buildTheme` take a preset (Porch light by default). Error and
presence colours are shared by every preset. Person colours are unchanged: they sit on avatars
with their own computed ink, so they read on any preset.

| Preset | Id | Character |
|---|---|---|
| Porch light (default) | `porch-light` | Dusk violet with a warm amber glow: the original look |
| Ocean | `ocean` | Deep navy ink, sea-glass own messages, blue links |
| Forest | `forest` | Pine green on warm cream; leaf-green own messages |
| Rose | `rose` | Berry ink and blush own messages, plum links |
| Sunset | `sunset` | Plum ink with coral own messages and a magenta accent |
| Slate | `slate` | Neutral greys with one clear blue for own messages and links |

Ids are stored on devices and must never be renamed. An unknown or removed id reads as Porch light.

## Mode and storage

`app/lib/settings/appearance.dart` keeps an `Appearance` (a `ThemeMode` and a preset) in
`SharedPreferencesAsync` under `theme_mode` and `theme_preset`, like the time format. `main()`
reads it before the first frame, so the app opens in the chosen theme rather than flashing the
default. An unknown stored mode reads as System; an unreadable store reads as the defaults.
`MaterialApp` gets the preset's light and dark themes and the mode; its theme animation is the
cross-fade (`Motion.medium`, or none when the platform asks for less motion).

## UI

Settings → Display → Appearance (`/settings/appearance`): the mode as a segmented control, and the
presets as a grid of cards. Each card shows a small chat in that preset's colours for the current
brightness (the backdrop, a bubble from someone else, one of yours, the accent as a dot), the name
and description, and a check on the one in use. Each card is one button for screen readers,
labelled "<name> colours. <description>" and marked selected. The Settings row's subtitle names
the choice ("Ocean, always dark").

The desktop title bar already reads the theme. On phones a root `AnnotatedRegion` colours the
navigation bar from the page surface and sets status and navigation bar icon brightness; app bars
and the signed-out hero still set their own.

## Readability rule

`test/theme/contrast_test.dart` checks every preset in both brightnesses: body text, muted text,
links (also the focus ring) and error text on every surface and the chat backdrop; the text on
each filled colour (primary, secondary, tertiary, their containers, inverse surface and its
action); own and other people's message text and meta on their bubbles; and the unread badge's
text on its fill. Every pair must reach WCAG AA, 4.5:1. A new preset that fails does not ship.

`test/theme/presets_test.dart` freezes the pre-preset Porch light ColorSchemes and tokens and
checks the default preset still produces them exactly.
