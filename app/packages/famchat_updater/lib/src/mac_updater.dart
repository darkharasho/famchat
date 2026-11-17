import 'package:flutter/services.dart';

/// Talks to Sparkle in the Mac app. Sparkle checks on its own schedule and shows its own window.
class MacUpdater {
  const MacUpdater([this._channel = const MethodChannel('famchat/updater')]);

  final MethodChannel _channel;

  /// Whether Sparkle runs in this build (release builds carry its feed; local builds don't).
  Future<bool> available() async {
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Checks now, showing Sparkle's window with the result.
  Future<void> checkForUpdates() => _channel.invokeMethod<void>('checkForUpdates');
}
