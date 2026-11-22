# Vendored from receive_sharing_intent 1.9.0

The share extension compiles these files itself instead of linking the plugin's Swift package:
Flutter puts plugin packages under a versioned path (`.packages/receive_sharing_intent-1.9.0`), and
the extension must not link Flutter anyway.

- `RSIComposeView.swift`: unmodified copy.
- `RSIShareViewController.swift`: copy, modified in `redirectToHostApp` to call
  `UIApplication.open` through the Objective-C runtime (extensions must build with
  `APPLICATION_EXTENSION_API_ONLY`, which rejects a direct call). Also modified in how attachments
  load (`viewDidAppear` and the `handleMedia` functions):
  - other files come through as `.file`: an attachment none of the plugin's types takes is loaded as
    `public.data`, and a text attachment that is a file URL goes as a file;
  - an item handed over as `Data` (any type) is written to a folder of its own in the App Group
    under its suggested name; images handed over as `UIImage` get a fresh name each (they all used
    to overwrite `TempImage.png`);
  - every attachment enters a `DispatchGroup` and leaves it exactly once, whatever it turns out to
    be or when loading fails (then it's skipped), and the share completes in `group.notify` once
    all have (it used to complete when the last-index attachment did, dropping slower ones, and
    some branches never completed);
  - results are recorded on a serial queue (item providers call back on arbitrary threads) and
    put in attachment order;
  - file URLs are read inside their security scope.
- `SharedTypes.swift`: the constants and `SharedMediaFile`/`SharedMediaType` from the plugin's
  `ReceiveSharingIntentPlugin.swift`, without the Flutter plugin class.

The app's half (the plugin) reads what these write, so `pubspec.yaml` pins the plugin to exactly
1.9.0. When upgrading it, copy these files again from the new version.

Licensed under the Apache License 2.0 (`LICENSE-receive_sharing_intent`), Copyright Kasem Mohamed.
