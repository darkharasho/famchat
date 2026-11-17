# App links for invites (short design)

Approved in conversation on 2026-11-17.

## Intent
Tapping an invite link (`https://famchat.dev/join#<token>`) on a phone with FamChat installed
should open the app on Join with the invite filled in. Today it opens the mobile browser, and the
person has to copy the code into the app by hand. Email invites (the multi-family project) will
rely on this too.

## Goals
- iOS Universal Links and Android App Links for `famchat.dev/join`.
- The app reads the invite from the link's fragment (`#…`), whether the link launches the app or
  arrives while it's running, and opens Join with it filled in.
- Without the app, the link still opens the web app. On a phone browser, Join offers "Get the
  app" (TestFlight on iPhone, Play on Android) and the choice to continue on the web.

## Non-goals
- Links for anything other than `/join`. Pairing is by QR code on the same screen, so it needs no link.
- Joining a family with an existing account (part of the multi-family project). For now a signed-in
  person who taps an invite gets a note that they're already signed in.

## Approaches
1. **The platform link mechanisms with a small Dart listener (chosen).** famchat.dev serves
   `/.well-known/apple-app-site-association` and `/.well-known/assetlinks.json`. iOS declares
   `applinks:famchat.dev`; Android has a verified intent filter for `https://famchat.dev/join`.
   The app_links package hands the full URL, fragment included, to the app.
2. Flutter's built-in deep linking straight into go_router: it routes by path and drops the
   fragment, which holds the token, so it can't carry an invite. It's turned off instead.
3. A custom scheme (`famchat://join/…`): needs a separate link, isn't verified, and still opens
   the browser when the app isn't installed. Rejected.

## Decisions
- The Worker serves both `.well-known` files from `/.well-known/*` (`run_worker_first`), with
  the right content type. The Apple team ID and the Android SHA-256 certificate fingerprints come
  from Worker vars (`APPLE_APP_ID`, `ANDROID_CERT_SHA256`, comma-separated), not hard-coded.
- Android fingerprints: Play's app-signing key (store builds) and the upload key (sideloaded
  builds). The upload key's fingerprint comes from the keystore; the app-signing one comes from
  Play Console.
- The iOS entitlement goes in `Runner.entitlements`. Automatic cloud signing must add the
  Associated Domains capability, so this is checked with a manual iOS release run before release.
- A tapped invite while signed out goes to `/join` with the token, through the same
  `initialInviteTokenProvider` path the web uses, made updatable for links that arrive while the
  app is running.

## Left to the builder
The wording of the "Get the app" banner, and test layout.
