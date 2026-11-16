# FamChat roadmap

Spec: `docs/superpowers/specs/2026-11-15-famchat-design.md`

The spec covers several subsystems, so it ships as a sequence of plans. Each one produces working,
tested software. A plan is written in detail only when the plan before it is done, so it can use the real
interfaces instead of guesses.

| # | Plan | Delivers | Depends on |
|---|---|---|---|
| 0 | Accounts & toolchain (no code) | Flutter installed, Firebase project `famchat`, bundle id `dev.famchat.app` registered with Apple, APNs key uploaded to Firebase, Play app created | — |
| 1 | **Server foundation & auth** (`2026-11-15-server-foundation-auth.md`) | Worker + D1 on famchat.dev: bootstrap admin, invites, redeem, refresh, device list/revoke | — |
| 2 | **App skeleton & platform spikes** (`2026-11-16-app-skeleton-spikes.md`, done; results in `docs/spikes/2026-11-platform-spikes.md`) | Flutter app on all 6 targets; check AAC `.m4a` record and playback, `cryptography`, drift-on-web and WebSockets on every platform | 0 |
| 3 | Crypto core (Dart) | Keys, device certs, sealed-box wraps, envelopes, test vectors; matches the cert format in plan 1 | 2 |
| 4 | Onboarding & sign-in client | Join from invite link, key generation, token storage and refresh, device list screen | 1, 3 |
| 5 | Chats & real-time | FamilyHub DO, chats/messages API, client sync and outbox, text, reactions, read receipts, typing and presence | 4 |
| 6 | Device pairing & key rotation | QR pairing, history handover, revocation creates new epochs, missing-wrap repair | 5 |
| 7 | Photos & media quota | Encrypted upload and download, thumbnails, 8 GB cap with eviction | 5 |
| 8 | Voice messages | Record, waveform, playback; AAC-LC `.m4a`, record button hidden where the recorder can't do AAC (plan 2) | 7 |
| 9 | Push notifications (`2026-11-16-push-notifications.md`) | Queue + FCM HTTP v1 consumer, client token registration, deep links, desktop notifications; Firebase config via `scripts/setup-firebase.sh` (replaces `flutterfire configure`) | 5, 0 |
| 10 | Admin & recovery | Admin-signed reset, reset banners, second admin, admin recovery code, usage screen | 6 |
| 11 | UI design pass | Visual identity, responsive two-pane layout polish, motion, dark mode | 5–8 |
| 12 | Release pipelines | Web deploy, TestFlight, Play internal, notarized DMG, signed Windows installer, AppImage | 2 |
