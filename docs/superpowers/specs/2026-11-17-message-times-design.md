# Message times: 12/24-hour and the time under the bubble

**Status:** short design (small change). Mockups were shown in the session; the user picked A.

## Why

The sent time sits inside the last bubble of a run, next to the text, and looks cramped there.
Every time in the app is also hard-coded 24-hour ("14:05"); the user wants 12-hour ("2:05 PM").

## Goals

- The sent time moves out of the bubble, to a small dim line just below the last bubble of each
  run (aligned with the bubble: right for mine, left for theirs).
- Times show in 12- or 24-hour form everywhere the app shows a clock time: under messages, the
  chat list ("2:05 PM" today), search results, and "Muted until …".
- A per-device setting chooses the form.

## Non-goals

- No change to runs (same sender, same day, at most 5 minutes apart), day separators, or the
  chat list's "Mon" / "3/14" for older days.
- No tap-to-reveal times, no times in the day separator (mockup C, not picked).

## Approaches (time placement)

- **A. Under the bubble — picked.** Fixes the cramped look with the least change; how a chat
  reads stays the same.
- B. Beside the bubble: fights long messages for width on a phone.
- C. Times in the day separator, tap a bubble for its time: cleanest, but loses the time at a
  glance and is more to build.

## Design

- **Setting:** "Time format" in Settings, with Automatic (default), 12-hour and 24-hour.
  Automatic follows the device (`MediaQuery.alwaysUse24HourFormat`). Stored per device in
  SharedPreferences, like the message-previews switch. *(My call: Automatic as the default, so
  a 12-hour phone shows 12-hour with no setup; the user can force 12-hour.)*
- **Formatting:** one helper replaces `clockTime` and the clock part of `shortTime`
  (chat_list.dart): 24-hour "14:05", 12-hour "2:05 PM" (no leading zero). Every caller uses it.
- **Bubble meta:** the time leaves the bubble and goes under it, outside, for the last bubble of
  a run (and pending/failed messages, as today). The pending clock icon goes with it. "edited"
  stays inside the bubble. Same for photo, video, GIF and voice bubbles, which today put the
  time under the media inside the bubble.
- **Spacing:** the line under the bubble replaces part of the gap between runs, so a chat
  doesn't grow much taller. *(My call; exact spacing left to the builder, checked by eye.)*

## Left to the builder

- Exact text style and spacing of the time line (dim, label-small, tabular figures as today).
- Where "Time format" sits in Settings (a new "Display" group, or under "You").
