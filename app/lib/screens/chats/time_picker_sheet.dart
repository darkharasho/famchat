// Picking when: a scheduled message goes out, or a reminder comes (docs/protocol.md "Scheduled
// messages", "Reminders"). A few presets and the date and time pickers, always within the server's
// window of a minute to 366 days ahead.
import 'package:material_ui/material_ui.dart';

import '../../chat/chat_sync.dart' show ChatSync;
import '../../settings/time_format.dart' show clockTime;
import '../../theme/tokens.dart';

/// A preset: its label and the time it stands for.
typedef TimePreset = ({String label, DateTime at});

/// The presets offered at [now]: In 1 hour, Tonight 8 PM (until 7 PM), Tomorrow 9 AM and Monday
/// 9 AM (the next Monday after today; left out when that's tomorrow).
List<TimePreset> timePresets(DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final hour = DateTime(now.year, now.month, now.day, now.hour, now.minute).add(const Duration(hours: 1));
  final tomorrow9 = DateTime(today.year, today.month, today.day + 1, 9);
  final toMonday = (DateTime.monday - now.weekday + 7) % 7;
  final monday9 = DateTime(today.year, today.month, today.day + (toMonday == 0 ? 7 : toMonday), 9);
  return [
    (label: 'In 1 hour', at: hour),
    if (now.hour < 19) (label: 'Tonight 8 PM', at: DateTime(today.year, today.month, today.day, 20)),
    (label: 'Tomorrow 9 AM', at: tomorrow9),
    if (monday9 != tomorrow9) (label: 'Monday 9 AM', at: monday9),
  ];
}

/// Whether [at] is in the server's window from [now].
bool inScheduleWindow(DateTime at, DateTime now) {
  final ahead = at.difference(now);
  return ahead >= ChatSync.scheduleMin && ahead <= ChatSync.scheduleMax;
}

/// "Today at 8:00 PM", "Tomorrow at 9:00 AM", "Mon at 9:00 AM" (within a week), "Nov 30 at 9:00 AM",
/// or with the year when it isn't this one.
String whenLabel(DateTime at, {required bool h24, DateTime? now}) {
  final n = now ?? DateTime.now();
  // Calendar days apart, counted in UTC so a daylight-saving change doesn't shift them.
  final days = DateTime.utc(at.year, at.month, at.day).difference(DateTime.utc(n.year, n.month, n.day)).inDays;
  final time = clockTime(at, h24: h24);
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  if (days == 0) return 'Today at $time';
  if (days == 1) return 'Tomorrow at $time';
  if (days > 1 && days < 7) return '${weekdays[at.weekday - 1]} at $time';
  final date = '${months[at.month - 1]} ${at.day}${at.year == n.year ? '' : ', ${at.year}'}';
  return '$date at $time';
}

/// Asks when, with [title] on top; returns a time a minute to 366 days ahead, or null when the
/// person backed out (or picked a time outside that window, which a snack bar explains).
Future<DateTime?> pickTime(BuildContext context, {required String title, DateTime Function()? now}) async {
  final clock = now ?? DateTime.now;
  final picked = await showModalBottomSheet<Object>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _TimePickerSheet(title: title, now: clock()),
  );
  if (picked is DateTime) return picked;
  if (picked != _custom || !context.mounted) return null;
  final start = clock();
  final date = await showDatePicker(
    context: context,
    initialDate: start,
    firstDate: DateTime(start.year, start.month, start.day),
    lastDate: start.add(ChatSync.scheduleMax),
  );
  if (date == null || !context.mounted) return null;
  final suggested = start.add(const Duration(hours: 1));
  final time = await showTimePicker(context: context, initialTime: TimeOfDay(hour: suggested.hour, minute: suggested.minute));
  if (time == null || !context.mounted) return null;
  final at = DateTime(date.year, date.month, date.day, time.hour, time.minute);
  if (!inScheduleWindow(at, clock())) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(at.isBefore(clock()) ? 'That time has passed. Pick a later one.' : 'Pick a time within the next year.'),
    ));
    return null;
  }
  return at;
}

/// The sheet's "Pick date and time" answer.
const _custom = #custom;

class _TimePickerSheet extends StatelessWidget {
  const _TimePickerSheet({required this.title, required this.now});

  final String title;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final h24 = MediaQuery.alwaysUse24HourFormatOf(context);
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.xl, Space.lg, Space.xl, Space.sm),
            child: Text(title, style: theme.textTheme.titleMedium),
          ),
          for (final p in timePresets(now))
            ListTile(
              key: Key('time-${p.label}'),
              leading: const Icon(Icons.schedule_rounded),
              title: Text(p.label),
              subtitle: Text(whenLabel(p.at, h24: h24, now: now)),
              onTap: () => Navigator.pop(context, p.at),
            ),
          ListTile(
            key: const Key('time-custom'),
            leading: const Icon(Icons.edit_calendar_outlined),
            title: const Text('Pick date and time'),
            onTap: () => Navigator.pop(context, _custom),
          ),
          const SizedBox(height: Space.sm),
        ]),
      ),
    );
  }
}
