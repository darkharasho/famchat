# Photo and video captions

## Why
Picking a photo or video sends it at once, so there is no way to say anything with it, and no way to back out of a wrong pick. Every mainstream chat app lets you attach media and type a message with it.

## What
- Picking, pasting or dropping photos/videos **stages** them in a tray above the composer instead of sending. Each thumbnail has ✕; a dashed "+" adds more. A hint line reads "N items · your message goes with them".
- Send sends every staged item, in order, each as its own message (as today). Whatever is in the text field becomes the **caption of the last one**; the field clears.
- The caption shows under the image inside the same bubble. It is searchable, shows in chat-list previews, notifications and reply quotes, and @mentions (including @everyone) in it work.
- Sharing photos from another app opens the chosen chat with them staged in the tray (shared text goes in the field, as today), so the caption is typed there. (Builder's call, replacing a separate caption box on the share screen: one place to caption, same UI.)
- A paste no longer asks "Send this photo?": it stages, which is the same safety.

## Approaches
1. **Caption inside the encrypted photo/video body** (optional `caption` field) — chosen. A real caption; one message. Older apps show the photo without the caption; phones get this by patch within a day.
2. Caption sent as a separate text message right after the media. Works on every version, but it isn't a caption (separate bubble, separate reply/delete).
3. Send immediately, then edit to add a caption. Clunky; no way to back out of a pick.

## Decisions
- `caption`: optional string on `PhotoBody` and `VideoBody`, same limits as text (trimmed, non-empty, ≤ text max). Unknown/invalid caption → ignored, the media still shows.
- Edits: a caption can be edited like text (EditBody already targets a message; for media it replaces the caption).
- Forwarding keeps the caption.
- Replying: the reply goes on the captioned (last) item. Mentions in the caption notify like a text's.
- If the captioned item fails (bad image/too-big video), the caption is sent as a text so it is never lost.
- Desktop: Enter sends the staged items when the tray is not empty, even with an empty field.

## Left to the builder
Tray widget details, animation, how many items before the tray scrolls (horizontal scroll).
