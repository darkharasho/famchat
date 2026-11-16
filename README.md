# famchat

FamChat is a private, invite-only messaging app for one family. It supports text, photos and voice messages in a sleek, modern, responsive interface. The backend runs on Cloudflare: Workers for the API, Durable Objects for real-time chat, D1 for data and R2 for media. A single cross-platform client codebase targets iOS, Android, macOS, Windows, Linux and the web.

## Tests

- Server: `cd server && npm test` (vitest, Workers runtime) and `npm run typecheck`.
- App: `cd app && flutter test` (unit and widget tests, no network).
- End to end: `scripts/e2e-pairing.sh` starts `wrangler dev` on a throwaway local D1 and runs
  `app/test_e2e/` against it: two users chat, a new device is paired and reads the history, then it is
  revoked and the chat moves to a new key.
