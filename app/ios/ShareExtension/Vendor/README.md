# Vendored from receive_sharing_intent 1.9.0

The share extension compiles these files itself instead of linking the plugin's Swift package:
Flutter puts plugin packages under a versioned path (`.packages/receive_sharing_intent-1.9.0`), and
the extension must not link Flutter anyway.

- `RSIShareViewController.swift`, `RSIComposeView.swift`: unmodified copies.
- `SharedTypes.swift`: the constants and `SharedMediaFile`/`SharedMediaType` from the plugin's
  `ReceiveSharingIntentPlugin.swift`, without the Flutter plugin class.

The app's half (the plugin) reads what these write, so `pubspec.yaml` pins the plugin to exactly
1.9.0. When upgrading it, copy these files again from the new version.

Licensed under the Apache License 2.0 (`LICENSE-receive_sharing_intent`), Copyright Kasem Mohamed.
