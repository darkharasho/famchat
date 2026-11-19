# famchat

FamChat is a private, invite-only messaging app for one family. It supports text, photos and voice messages in a sleek, modern, responsive interface. The backend runs on Cloudflare: Workers for the API, Durable Objects for real-time chat, D1 for data and R2 for media. A single cross-platform client codebase targets iOS, Android, macOS, Windows, Linux and the web.

## Tests

- Server: `cd server && npm test` (vitest, Workers runtime) and `npm run typecheck`.
- App: `cd app && flutter test` (unit and widget tests, no network).
- End to end: `scripts/e2e-pairing.sh` starts `wrangler dev` on a throwaway local D1 and runs
  `app/test_e2e/` against it: two users chat, a new device is paired and reads the history, then it is
  revoked and the chat moves to a new key.

## Push notifications

Push (FCM for Android, iOS and the web) is off until Firebase is set up; everything builds and runs
without it. Desktop apps (and a web tab in the background) notify from their socket while running,
and after a reconnect (sleep, network loss) they notify once per chat for unread messages missed meanwhile.
To turn push on, once:

1. `scripts/setup-firebase.sh` (needs Node, Python 3 and a browser for `firebase login`; wrangler
   logged in). It registers the Android, iOS and web apps in the Firebase project `famchat`, writes
   their public config (`app/lib/push/firebase_options.dart`, `app/web/firebase-config.js`), stores a
   new service-account key as the Worker secret `FCM_SERVICE_ACCOUNT` (never printed or saved), and
   opens a PR with the two config files. If the key can't be created automatically it tells you where
   to download one; then `scripts/setup-firebase.sh --key-file <file>`.
2. Merge that PR, deploy (`scripts/deploy.sh`), and release the apps.
3. On a phone, allow notifications, then Settings → Notifications → "Send a test notification".

How it works: `FamilyHub` puts a job on the `famchat-push` Queue for members with no open socket
(sockets silent for 90 s are dropped first); the Worker's `queue()` handler sends one FCM HTTP v1
message per device token with the sender's name and the chat title only, never message content, and
clears tokens FCM reports as gone. See `docs/protocol.md` ("Push").
