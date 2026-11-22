// The per-device "Time format" setting and the one clock-time formatter. Stored locally with
// SharedPreferencesAsync, like the message-previews setting.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum TimeFormat { automatic, h12, h24 }

const timeFormatPrefKey = 'time_format';

/// Automatic unless the user chose a form; an unknown stored value reads as Automatic.
Future<TimeFormat> readTimeFormat([SharedPreferencesAsync? prefs]) async {
  final v = await (prefs ?? SharedPreferencesAsync()).getString(timeFormatPrefKey);
  for (final f in TimeFormat.values) {
    if (f.name == v) return f;
  }
  return TimeFormat.automatic;
}

Future<void> writeTimeFormat(TimeFormat f, [SharedPreferencesAsync? prefs]) =>
    (prefs ?? SharedPreferencesAsync()).setString(timeFormatPrefKey, f.name);

/// Whether to show 24-hour times: Automatic follows the device.
bool use24Hour(TimeFormat f, {required bool device}) => switch (f) {
      TimeFormat.automatic => device,
      TimeFormat.h12 => false,
      TimeFormat.h24 => true,
    };

/// "14:05" (24-hour) or "2:05 PM" (12-hour, no leading zero).
String clockTime(DateTime t, {required bool h24}) {
  final mm = t.minute.toString().padLeft(2, '0');
  if (h24) return '${t.hour.toString().padLeft(2, '0')}:$mm';
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:$mm ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// "Last seen today at 14:05", "… yesterday at …", "… Mon at …" (this week) or "… on 3/14";
/// "Last seen just now" under a minute ago.
String lastSeenLabel(DateTime t, {required bool h24, DateTime? now}) {
  final n = now ?? DateTime.now();
  if (!t.isAfter(n) && n.difference(t) < const Duration(minutes: 1)) return 'Last seen just now';
  final today = DateTime(n.year, n.month, n.day), day = DateTime(t.year, t.month, t.day);
  final at = clockTime(t, h24: h24);
  if (day == today) return 'Last seen today at $at';
  if (day == DateTime(today.year, today.month, today.day - 1)) return 'Last seen yesterday at $at';
  if (day.isAfter(DateTime(today.year, today.month, today.day - 7)) && day.isBefore(today)) {
    return 'Last seen ${const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][t.weekday - 1]} at $at';
  }
  return t.year == n.year ? 'Last seen on ${t.month}/${t.day}' : 'Last seen on ${t.month}/${t.day}/${t.year}';
}

class TimeFormatNotifier extends AsyncNotifier<TimeFormat> {
  @override
  Future<TimeFormat> build() => readTimeFormat();

  Future<void> set(TimeFormat f) async {
    await writeTimeFormat(f);
    state = AsyncData(f);
  }
}

final timeFormatProvider = AsyncNotifierProvider<TimeFormatNotifier, TimeFormat>(
  TimeFormatNotifier.new,
);
