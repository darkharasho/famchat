# Batch 3: polls and files

Approved from a mockup on 2026-11-22. Part of the messaging feature batches (batch 2 shipped in v1.0.33). Location was dropped from this batch ("skip location for now").

## Why
Feature parity with mainstream chat apps without weakening end-to-end encryption. Families plan things together ("which days work for Thanksgiving?") and pass around documents (flight confirmations, budgets, recipe cards) that today have to go by email.

## Polls
- **Make one:** "+" menu → **Poll**, in any chat (direct or group). A sheet: question (1–300 characters), 2–10 options (1–100 characters each, blanks dropped, duplicates refused), and a switch **"Allow more than one answer"** (off by default). The creator picks single or multiple choice per poll (user's decision).
- **Bubble:** question, "Pick one" / "Pick one or more" with the vote count, then each option with a bar, the faces of who picked it and a count. Single choice shows round marks, multiple choice checkboxes. Tapping votes at once: single choice moves your vote, multiple choice toggles. Tapping your only single-choice pick again takes the vote back. Results are always visible (it's family).
- **See votes:** a sheet listing, per option, who picked it, then "Hasn't voted:" with the current members who haven't.
- **End poll:** only the creator sees it. Ending freezes the results: votes after it don't count, the bubble shows **ENDED**, marks disappear and the winning option(s) get 🏆 and bold. Ending can't be undone.
- **Chat list / notifications:** "📊 Poll: <question>". Votes and the end are silent: no notification, not unread, don't move the chat up.
- Polls can be replied to, pinned, starred and deleted (by the creator) like other messages. They can't be forwarded or edited.

### Wire (no server change)
- `{"kind":"poll","question":"…","options":["…","…"],"multi":true|false}`, a normal message. Its message id is the poll's id; option ids are indexes.
- `{"kind":"vote","target":"<pollId>","choices":[0,2]}`, silent. `[]` takes the vote back. For each voter the latest vote (by seq, own pending last) wins. Indexes out of range are dropped; on a single-choice poll only the first choice counts.
- `{"kind":"poll_end","target":"<pollId>"}`, silent. Counts only from the poll's sender. Votes after the first counting end don't count.
- Every device folds the same rows in the same order, so everyone sees the same totals. Votes on a deleted poll don't matter.
- Older apps show "needs a newer version" for these until they update; with the keep-unknown-fields change they then show properly. Polls are Dart-only, so phones get them by patch the same day.

## Files
- **Send:** "+" menu → **File** picks any files; on desktop and web, dropping files that aren't photos or videos sends them as files; sharing files from another app into FamChat (Android and iOS) sends them too. Up to **64 MB** each (a bigger one gets "Files can be up to 64 MB"). Each file is its own message; it can reply to a message.
- **Bubble:** a colored type icon with the extension (PDF, XLS, ZIP, …), the file name, "size · TYPE"; while sending "1.2 of 1.9 MB · Sending" with a progress bar; received files have a download button. When the server expired it: dimmed, "No longer available".
- **Open:** tap downloads (with progress) and opens it with the system's app. Long-press adds **Save** (a save dialog: Files on iOS, a folder on Android and desktop, a download on the web). Files that run code (exe, msi, bat, cmd, com, scr, ps1, vbs, js, jar, sh, app, dmg, pkg, apk, deb, rpm) are never opened from the app, only saved (my call: one tap shouldn't run a program someone sent).
- **Chat list:** "📎 <name>". Files can be replied to, forwarded, pinned, starred and deleted.
- Expiry and storage: they count toward the family's 8 GB cap and expire oldest first, like videos.

### Wire
- `{"kind":"file","mediaKey":"<ULID>","key":"<b64url 32>","sha256":"<b64url 32>","name":"Flight confirmation.pdf","bytes":290816,"mime":"application/pdf","replyTo"?: "<id>"}`: one encrypted blob (purpose `file`), the same media scheme as photos.
- `name`: 1–255 characters after the receiver strips path separators and control characters; it is shown and used as the default save name, never as a path.
- **Server:** a new media kind `file` with a 64 MiB limit (the Workers 100 MB body limit), like `video`. Nothing else changes.

## Approaches considered
- **Polls as encrypted messages plus vote events** (chosen) vs server-side poll state. Server-side would be simpler but tells the server the question, options and who voted for what. The event approach reuses the games/pins machinery and the server learns nothing.
- **One vote event that carries the full choice set** (chosen) vs add/remove events per option. Full sets make "latest wins" trivially consistent across devices.
- **Files over the existing media upload** (chosen) vs chunked uploads for bigger files. Chunking would lift the 64 MB limit but needs new server and crypto work; 64 MB covers documents and most archives.
- **Ship order:** polls first as their own PR (Dart-only, patched to phones at once), then files in a second PR. Files need a native plugin to pick and open any file type, so they go out as a full release and reach App Store phones after Apple's review; polls shouldn't wait for that.

## Non-goals
Anonymous polls, adding options after sending, poll deadlines, a Files tab in chat info, file previews (thumbnails of PDFs), files over 64 MB, location (deferred).

## Left to the builder
Exact icon colors per type, sheet layouts, animations, empty states, the plugin choices for picking/opening/saving (keep them few and maintained).
