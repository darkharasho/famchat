// Settings → Appearance: Light, Dark or System, and the colour theme. Both apply at once, app-wide,
// and are kept on this device only.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/presets.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import 'appearance.dart';

const modeLabels = {ThemeMode.system: 'System', ThemeMode.light: 'Light', ThemeMode.dark: 'Dark'};

class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appearanceProvider);
    final notifier = ref.read(appearanceProvider.notifier);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(Space.xs, 0, Space.xs, Space.sm),
      child: Semantics(
        header: true,
        child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ),
    );
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go('/settings')),
        title: const Text('Appearance'),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.xxl + MediaQuery.paddingOf(context).bottom),
        children: [
          ContentWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                heading('Mode'),
                SegmentedButton<ThemeMode>(
                  key: const Key('appearance-mode'),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.system,
                      icon: Icon(Icons.brightness_auto_rounded),
                      label: Text('System', key: Key('appearance-mode-system')),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      icon: Icon(Icons.light_mode_rounded),
                      label: Text('Light', key: Key('appearance-mode-light')),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      icon: Icon(Icons.dark_mode_rounded),
                      label: Text('Dark', key: Key('appearance-mode-dark')),
                    ),
                  ],
                  selected: {appearance.mode},
                  onSelectionChanged: (s) => notifier.setMode(s.single),
                ),
                const SizedBox(height: Space.sm),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.xs),
                  child: Text(
                    appearance.mode == ThemeMode.system
                        ? 'Follows this device: light by day, dark when the device is.'
                        : 'Always ${modeLabels[appearance.mode]!.toLowerCase()} on this device.',
                    style: muted,
                  ),
                ),
                const SizedBox(height: Space.xl),
                heading('Colours'),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.maxWidth >= 520 ? 3 : 2;
                    final width = (constraints.maxWidth - Space.md * (columns - 1)) / columns;
                    return Wrap(
                      spacing: Space.md,
                      runSpacing: Space.md,
                      children: [
                        for (final p in ThemePreset.all)
                          SizedBox(
                            width: width,
                            child: PresetCard(
                              preset: p,
                              selected: p.id == appearance.preset.id,
                              onTap: () => notifier.setPreset(p),
                            ),
                          ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: Space.md),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.xs),
                  child: Text('Only on this device. Everyone else sees their own choice.', style: muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One colour theme to pick: a small chat in its colours (in the current brightness), its name,
/// and a check when it's the one in use.
class PresetCard extends StatelessWidget {
  const PresetCard({super.key, required this.preset, required this.selected, required this.onTap});

  final ThemePreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final c = preset.colors(dark: theme.brightness == Brightness.dark);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Radii.lg),
      side: BorderSide(color: selected ? s.tertiary : s.outlineVariant, width: selected ? 2 : 1),
    );
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: '${preset.name} colours. ${preset.description}',
      excludeSemantics: true,
      child: Material(
        key: Key('appearance-preset-${preset.id}'),
        color: theme.cardTheme.color,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Preview(colors: c),
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.sm, Space.md),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(preset.name, style: theme.textTheme.titleSmall),
                          const SizedBox(height: 2),
                          Text(preset.description, style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                    if (selected) Icon(Icons.check_circle_rounded, size: 22, color: s.tertiary),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A conversation in miniature: the room, a message from someone else, one of yours, and the
/// accent (links and focus) as a dot.
class _Preview extends StatelessWidget {
  const _Preview({required this.colors});

  final PresetColors colors;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    Widget bubble({
      required Color fill,
      Color? fillEnd,
      required Color ink,
      Color? border,
      required double width,
      required bool mine,
    }) => Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        width: width,
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: fillEnd == null ? fill : null,
          gradient: fillEnd == null ? null : mineBubbleGradient(fill, fillEnd),
          border: border == null ? null : Border.all(color: border),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(11),
            topRight: const Radius.circular(11),
            bottomLeft: Radius.circular(mine ? 11 : 3),
            bottomRight: Radius.circular(mine ? 3 : 11),
          ),
        ),
        child: FractionallySizedBox(
          widthFactor: 0.7,
          child: Container(
            height: 5,
            decoration: BoxDecoration(color: ink, borderRadius: BorderRadius.circular(3)),
          ),
        ),
      ),
    );
    return Container(
      height: 92,
      color: c.chatBackdrop,
      padding: const EdgeInsets.all(Space.md),
      child: Stack(
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              bubble(fill: c.theirsBubble, ink: c.onSurfaceVariant, border: c.theirsBorder, width: 72, mine: false),
              const SizedBox(height: 6),
              bubble(fill: c.mineBubble, fillEnd: c.mineBubbleEnd, ink: c.onMineBubble, width: 84, mine: true),
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(color: c.tertiary, shape: BoxShape.circle),
            ),
          ),
          Positioned(
            top: 0,
            left: 18,
            child: Container(
              width: 28,
              height: 12,
              decoration: BoxDecoration(color: c.primary, borderRadius: BorderRadius.circular(6)),
            ),
          ),
        ],
      ),
    );
  }
}
