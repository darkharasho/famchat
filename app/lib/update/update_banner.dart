import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../widgets/common.dart';
import 'update_controller.dart';

/// The home screen's "new version" notice: restart to apply a downloaded update, or download one.
class UpdateBanner extends ConsumerWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateProvider);
    final updates = ref.read(updateProvider.notifier);
    if (!updates.showBanner) return const SizedBox.shrink();
    final fg = Theme.of(context).colorScheme.onSecondaryContainer;
    final notNow = TextButton(
      onPressed: updates.dismiss,
      style: TextButton.styleFrom(foregroundColor: fg),
      child: const Text('Not now'),
    );
    return switch (state) {
      UpdateReady(:final release) => NoticeCard(
          key: const Key('update-ready'),
          tone: NoticeTone.highlight,
          icon: Icons.system_update_alt_rounded,
          text: 'FamChat ${release.version} is ready. Restart to update.',
          actions: [
            notNow,
            TextButton(onPressed: updates.restart, style: TextButton.styleFrom(foregroundColor: fg), child: const Text('Restart')),
          ],
        ),
      UpdateAvailable(:final release) => NoticeCard(
          key: const Key('update-available'),
          tone: NoticeTone.highlight,
          icon: Icons.system_update_alt_rounded,
          text: 'FamChat ${release.version} is available.',
          actions: [
            notNow,
            TextButton(
              onPressed: updates.openDownload,
              style: TextButton.styleFrom(foregroundColor: fg),
              child: const Text('Download'),
            ),
          ],
        ),
      _ => const SizedBox.shrink(),
    };
  }
}

/// Settings: this app's version and the update check, on desktop builds that update themselves.
class AppVersionGroup extends ConsumerWidget {
  const AppVersionGroup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(updateConfigProvider) == null) return const SizedBox.shrink();
    final state = ref.watch(updateProvider);
    final updates = ref.read(updateProvider.notifier);
    final (String subtitle, Widget? action) = switch (state) {
      UpdateIdle(checked: true) => ("You're up to date.", null),
      UpdateIdle(:final error?) => (error, null),
      UpdateIdle() => ('Checks for updates automatically.', null),
      UpdateDownloading(:final release, :final progress) =>
        ('Downloading ${release.version}… ${(progress * 100).round()}%', null),
      UpdateReady(:final release) =>
        ('${release.version} is ready to install.', FilledButton.tonal(onPressed: updates.restart, child: const Text('Restart'))),
      UpdateAvailable(:final release) =>
        ('${release.version} is available.', FilledButton.tonal(onPressed: updates.openDownload, child: const Text('Download'))),
    };
    final idle = state is UpdateIdle;
    return SettingsGroup(title: 'App', children: [
      ListTile(
        key: const Key('settings-version'),
        leading: const TileIcon(Icons.info_outline_rounded),
        title: const Text('FamChat $appReleaseVersion'),
        subtitle: Text(subtitle),
        trailing: action ??
            (idle ? TextButton(onPressed: updates.check, child: const Text('Check now')) : null),
      ),
    ]);
  }
}
