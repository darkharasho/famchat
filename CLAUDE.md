## Project Context

FamChat is a private, invite-only messaging app for one family. It supports text, photos and voice messages in a sleek, modern, responsive interface. The backend runs on Cloudflare: Workers for the API, Durable Objects for real-time chat, D1 for data and R2 for media. A single cross-platform client codebase targets iOS, Android, macOS, Windows, Linux and the web.

## Goals

- Private, invite-only messaging for family members only
- Real-time 1:1 and group chats over WebSockets
- Send and view text messages and photos
- Record, send and play back voice messages
- Sleek, modern, responsive UI that works on phone, tablet and desktop
- One codebase shipping to iOS, Android, macOS, Windows, Linux and the web
- Message history synced across all of a user's devices

## Out of scope

- Voice or video calls in v1
- Public sign-up or use beyond the family
- Federation or interoperability with other chat apps

## Suggested stack

- **Cloudflare Workers** — Serverless API layer at the edge with a generous free tier and no servers to manage
- **Cloudflare Durable Objects** — One object per chat room handles WebSocket fan-out, message ordering and presence
- **Cloudflare D1** — SQLite-based storage for users, chats and message history
- **Cloudflare R2** — Cheap object storage for photos and voice clips, with no egress fees
- **Flutter (tentative)** — One codebase for mobile, desktop and the web, with strong custom-UI capability for a polished look
