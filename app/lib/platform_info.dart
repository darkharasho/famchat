import 'package:flutter/foundation.dart';

/// The `platform` value the server accepts: ios, android, macos, windows, linux or web.
String serverPlatform() {
  if (kIsWeb) return 'web';
  return switch (defaultTargetPlatform) {
    TargetPlatform.iOS => 'ios',
    TargetPlatform.android => 'android',
    TargetPlatform.macOS => 'macos',
    TargetPlatform.windows => 'windows',
    TargetPlatform.linux || TargetPlatform.fuchsia => 'linux',
  };
}

/// A starting device name the user can edit on the join screen.
String defaultDeviceName() => switch (serverPlatform()) {
      'ios' => 'iPhone',
      'android' => 'Android phone',
      'macos' => 'Mac',
      'windows' => 'Windows PC',
      'web' => 'Web browser',
      _ => 'Linux PC',
    };
