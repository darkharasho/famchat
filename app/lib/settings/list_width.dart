// The chat list's width beside an open chat on wide windows, dragged by the divider between them.
// Stored per device with SharedPreferencesAsync, like the time format.
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const listWidthPrefKey = 'chat_list_width';

const defaultListWidth = 360.0;
const minListWidth = 280.0;
const maxListWidth = 560.0;

/// The conversation keeps at least this much room, however wide the list is asked to be.
const minConversationWidth = 360.0;

/// [want] kept between [minListWidth] and [maxListWidth], and narrow enough to leave the
/// conversation [minConversationWidth] of a [total]-wide window. The minimum wins in a tight window.
double clampListWidth(double want, double total) =>
    want.clamp(minListWidth, math.max(minListWidth, math.min(maxListWidth, total - minConversationWidth)));

/// The width asked for: the default until the stored one loads, then what the divider sets.
class ListWidthNotifier extends Notifier<double> {
  bool _touched = false;

  @override
  double build() {
    _load();
    return defaultListWidth;
  }

  // The width is cosmetic: a store that can't be read or written (no platform store in some tests)
  // leaves the default and the width of this run.
  Future<void> _load() async {
    try {
      final stored = await SharedPreferencesAsync().getDouble(listWidthPrefKey);
      if (stored != null && !_touched) state = stored.clamp(minListWidth, maxListWidth);
    } catch (_) {}
  }

  Future<void> _store(Future<void> Function(SharedPreferencesAsync p) op) async {
    try {
      await op(SharedPreferencesAsync());
    } catch (_) {}
  }

  /// Follows the drag; nothing is stored until [save].
  void drag(double width) {
    _touched = true;
    state = width.clamp(minListWidth, maxListWidth);
  }

  Future<void> save() => _store((p) => p.setDouble(listWidthPrefKey, state));

  Future<void> reset() {
    _touched = true;
    state = defaultListWidth;
    return _store((p) => p.remove(listWidthPrefKey));
  }
}

final listWidthProvider = NotifierProvider<ListWidthNotifier, double>(ListWidthNotifier.new);
