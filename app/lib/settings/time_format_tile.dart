// The Settings page's "Display" group (the time format chooser) and the app-wide scope that
// applies the setting to every clock time.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../widgets/common.dart';
import 'time_format.dart';

const _labels = {
  TimeFormat.automatic: 'Automatic',
  TimeFormat.h12: '12-hour',
  TimeFormat.h24: '24-hour',
};

/// Overrides `MediaQuery.alwaysUse24HourFormat` below it from the Time format setting, so every
/// widget that reads it follows the setting. Loading or unreadable counts as Automatic.
class TimeFormatScope extends ConsumerWidget {
  const TimeFormatScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final format = ref.watch(timeFormatProvider).value ?? TimeFormat.automatic;
    final h24 = use24Hour(format, device: MediaQuery.alwaysUse24HourFormatOf(context));
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: h24),
      child: child,
    );
  }
}

class DisplaySettingsGroup extends ConsumerWidget {
  const DisplaySettingsGroup({super.key});

  Future<void> _choose(BuildContext context, WidgetRef ref, TimeFormat current) async {
    final picked = await showDialog<TimeFormat>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Time format'),
        children: [
          RadioGroup<TimeFormat>(
            groupValue: current,
            onChanged: (f) => Navigator.of(context).pop(f),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final f in TimeFormat.values)
                RadioListTile<TimeFormat>(key: Key('time-format-${f.name}'), value: f, title: Text(_labels[f]!)),
            ]),
          ),
        ],
      ),
    );
    if (picked != null) await ref.read(timeFormatProvider.notifier).set(picked);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(timeFormatProvider).value ?? TimeFormat.automatic;
    return SettingsGroup(title: 'Display', children: [
      ListTile(
        key: const Key('settings-time-format'),
        leading: const TileIcon(Icons.schedule_rounded),
        title: const Text('Time format'),
        subtitle: Text(_labels[current]!),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => _choose(context, ref, current),
      ),
    ]);
  }
}
