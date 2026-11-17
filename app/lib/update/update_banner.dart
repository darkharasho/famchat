import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:famchat_updater/famchat_updater.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import 'update_controller.dart';

/// The "new version" popup, floating in the corner over every screen (mounted in main.dart's
/// builder): restart into a downloaded update, or download one. Stays until acted on or put off.
class UpdatePrompt extends ConsumerWidget {
  const UpdatePrompt({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateProvider);
    final updates = ref.read(updateProvider.notifier);
    final card = !updates.showBanner
        ? null
        : switch (state) {
            UpdateReady(:final release) => _PromptCard(
                key: const Key('update-ready'),
                text: 'FamChat ${release.version} is ready. Restart to update.',
                action: 'Restart now',
                onAction: updates.restart,
                onLater: updates.dismiss,
              ),
            UpdateAvailable(:final release) => _PromptCard(
                key: const Key('update-available'),
                text: 'FamChat ${release.version} is available.',
                action: 'Download',
                onAction: updates.openDownload,
                onLater: updates.dismiss,
              ),
            _ => null,
          };
    final narrow = MediaQuery.sizeOf(context).width < 360 + Space.lg * 2;
    // Above a conversation's composer, so it never covers the send button.
    return Positioned(
      right: Space.lg,
      left: narrow ? Space.lg : null,
      bottom: 88 + MediaQuery.paddingOf(context).bottom,
      child: AnimatedSwitcher(
        duration: Motion.of(context, Motion.medium),
        switchInCurve: Motion.enter,
        switchOutCurve: Motion.exit,
        transitionBuilder: (child, a) => FadeTransition(
          opacity: a,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(a),
            child: child,
          ),
        ),
        child: card ?? const SizedBox.shrink(),
      ),
    );
  }
}

class _PromptCard extends StatelessWidget {
  const _PromptCard({super.key, required this.text, required this.action, required this.onAction, required this.onLater});

  final String text;
  final String action;
  final VoidCallback onAction;
  final VoidCallback onLater;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Material(
        color: s.surfaceContainerHigh,
        elevation: 6,
        shadowColor: Colors.black54,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          side: BorderSide(color: s.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.sm, Space.sm),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(Icons.system_update_alt_rounded, size: 20, color: s.primary),
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: Space.sm),
                  child: Text(text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: s.onSurface)),
                ),
              ),
            ]),
            const SizedBox(height: Space.xs),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: onLater, child: const Text('Later')),
              const SizedBox(width: Space.xs),
              FilledButton.tonal(onPressed: onAction, child: Text(action)),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// Settings: this app's version and the update check, on desktop builds that update themselves.
/// On the web, opens a page in a new tab (the web app links to the installable apps). Null in the
/// installed apps.
final appDownloadsProvider = Provider<Future<bool> Function(Uri)?>(
  (ref) => kIsWeb ? (u) => launchUrl(u, webOnlyWindowName: '_blank') : null,
);

/// The Mac app updates through Sparkle, which has its own schedule and window. Null elsewhere and
/// in local builds.
final macUpdaterProvider = Provider<MacUpdater?>(
  (ref) => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS && appReleaseVersion.isNotEmpty
      ? const MacUpdater()
      : null,
);

class AppVersionGroup extends ConsumerWidget {
  const AppVersionGroup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mac = ref.watch(macUpdaterProvider);
    if (mac != null) {
      return SettingsGroup(title: 'App', children: [
        ListTile(
          key: const Key('settings-version'),
          leading: const TileIcon(Icons.info_outline_rounded),
          title: Text('FamChat $appReleaseVersion'),
          subtitle: const Text('Checks for updates automatically.'),
          trailing: TextButton(onPressed: mac.checkForUpdates, child: const Text('Check now')),
        ),
      ]);
    }
    if (ref.watch(updateConfigProvider) == null) {
      final open = ref.watch(appDownloadsProvider);
      if (open == null) return const SizedBox.shrink();
      return SettingsGroup(title: 'App', children: [
        ListTile(
          key: const Key('settings-get-apps'),
          leading: const TileIcon(Icons.download_rounded),
          title: const Text('Get the apps'),
          subtitle: const Text('FamChat for Windows, Mac, Linux, iPhone and Android.'),
          onTap: () => open(Uri.base.resolve('/download.html')),
        ),
      ]);
    }
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
