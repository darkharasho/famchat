import 'package:famchat/platform_info.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const table = {
    TargetPlatform.iOS: ('ios', 'iPhone'),
    TargetPlatform.android: ('android', 'Android phone'),
    TargetPlatform.macOS: ('macos', 'Mac'),
    TargetPlatform.windows: ('windows', 'Windows PC'),
    TargetPlatform.linux: ('linux', 'Linux PC'),
    TargetPlatform.fuchsia: ('linux', 'Linux PC'),
  };

  test('platform name and default device name follow the target platform', () {
    for (final MapEntry(key: p, value: (server, name)) in table.entries) {
      debugDefaultTargetPlatformOverride = p;
      expect(serverPlatform(), server, reason: '$p');
      expect(defaultDeviceName(), name, reason: '$p');
    }
    debugDefaultTargetPlatformOverride = null;
  }, testOn: 'vm');
}
