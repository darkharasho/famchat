import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether developer tools (the platform spikes) are offered in the UI: debug builds, or a build
/// made with `--dart-define=FAMCHAT_DEV_TOOLS=true`. The /spikes route itself stays reachable.
final developerToolsProvider = Provider<bool>((ref) => kDebugMode || const bool.fromEnvironment('FAMCHAT_DEV_TOOLS'));
