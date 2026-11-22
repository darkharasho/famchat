# Vendored from receive_sharing_intent 1.9.0

The share extension compiles these files itself instead of linking the plugin's Swift package:
Flutter puts plugin packages under a versioned path (`.packages/receive_sharing_intent-1.9.0`), and
the extension must not link Flutter anyway.

- `RSIComposeView.swift`: unmodified copy.
- `RSIShareViewController.swift`: copy, modified in `redirectToHostApp` to call
  `UIApplication.open` through the Objective-C runtime (extensions must build with
  `APPLICATION_EXTENSION_API_ONLY`, which rejects a direct call). Also modified so other files
  come through as `.file`: an attachment none of the plugin's types takes is loaded as
  `public.data` (a URL, or bytes written to the App Group under the suggested name), a text
  attachment that is a file URL goes as a file, each attachment always completes (an unmatched
  last one used to leave the extension hanging), and file URLs are read inside their security
  scope.
- `SharedTypes.swift`: the constants and `SharedMediaFile`/`SharedMediaType` from the plugin's
  `ReceiveSharingIntentPlugin.swift`, without the Flutter plugin class.

The app's half (the plugin) reads what these write, so `pubspec.yaml` pins the plugin to exactly
1.9.0. When upgrading it, copy these files again from the new version.

Licensed under the Apache License 2.0 (`LICENSE-receive_sharing_intent`), Copyright Kasem Mohamed.
