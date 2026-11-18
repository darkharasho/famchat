// The Settings page's "Window" group on the desktop apps: the Close to tray switch. Nothing on
// phones, the web, or a Linux desktop without a tray.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../widgets/common.dart';
import '../window/desktop_window.dart';
import 'close_to_tray.dart';

class WindowSettingsGroup extends ConsumerWidget {
  const WindowSettingsGroup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final platform = ref.watch(desktopPlatformProvider);
    if (platform == null || !ref.watch(closeToTrayOfferedProvider)) return const SizedBox.shrink();
    final mac = platform == TargetPlatform.macOS;
    return SettingsGroup(title: 'Window', children: [
      SwitchListTile(
        key: const Key('settings-close-to-tray'),
        secondary: const TileIcon(Icons.close_fullscreen_rounded),
        title: Text(closeToTrayTitle(platform)),
        subtitle: Text(mac
            ? 'Closing the window keeps FamChat in the menu bar, so messages still notify you'
            : 'Closing the window keeps FamChat in the tray, so messages still notify you'),
        value: ref.watch(closeToTrayProvider).value ?? false,
        onChanged: (on) => ref.read(closeToTrayProvider.notifier).set(on),
      ),
    ]);
  }
}
