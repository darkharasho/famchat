// Small building blocks shared by many screens.
import 'package:material_ui/material_ui.dart';

import '../theme/motion.dart';
import '../theme/tokens.dart';

/// Centers [child] at no more than [max] wide (forms, settings, a wide conversation).
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, this.max = Widths.page, required this.child});

  final double max;
  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: BoxConstraints(maxWidth: max), child: child),
      );
}

/// An empty or waiting screen: a picture, what's going on, and what to do next.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.art, required this.title, this.body, this.action});

  final Widget art;
  final String title;
  final String? body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Space.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            art,
            const SizedBox(height: Space.xl),
            Text(title, textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
            if (body != null) ...[
              const SizedBox(height: Space.sm),
              Text(
                body!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
            if (action != null) ...[const SizedBox(height: Space.xl), action!],
          ]),
        ),
      ),
    );
  }
}

/// A titled group of rows on one card, like a section of a settings page.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, this.title, required this.children});

  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.xs, 0, Space.xs, Space.sm),
            child: Semantics(
              header: true,
              child: Text(title!, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          ),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const Divider(indent: 56),
              children[i],
            ],
          ]),
        ),
      ]),
    );
  }
}

/// A rounded icon tile, the leading art of settings rows.
class TileIcon extends StatelessWidget {
  const TileIcon(this.icon, {super.key, this.color, this.background});

  final IconData icon;
  final Color? color, background;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: background ?? s.primaryContainer,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Icon(icon, size: 20, color: color ?? s.onPrimaryContainer),
    );
  }
}

/// A notice above a list or conversation: an icon, a sentence, and an action or two.
class NoticeCard extends StatelessWidget {
  const NoticeCard({
    super.key,
    required this.icon,
    required this.text,
    this.actions = const [],
    this.tone = NoticeTone.info,
  });

  final IconData icon;
  final String text;
  final List<Widget> actions;
  final NoticeTone tone;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final (bg, fg) = switch (tone) {
      NoticeTone.info => (s.surfaceContainerLowest, s.onSurface),
      NoticeTone.warning => (s.errorContainer, s.onErrorContainer),
      NoticeTone.highlight => (s.secondaryContainer, s.onSecondaryContainer),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.md, 0),
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          side: tone == NoticeTone.info ? BorderSide(color: s.outlineVariant) : BorderSide.none,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.sm, Space.sm),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 20, color: fg)),
              const SizedBox(width: Space.md),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: Space.sm),
                  child: Text(text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: fg)),
                ),
              ),
            ]),
            if (actions.isNotEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(spacing: Space.xs, children: actions),
              ),
          ]),
        ),
      ),
    );
  }
}

enum NoticeTone { info, warning, highlight }

/// Fades and lifts [child] in once, when [animate] (and motion isn't reduced).
class AppearIn extends StatefulWidget {
  const AppearIn({super.key, required this.child, this.animate = true, this.offset = 0.18});

  final Widget child;
  final bool animate;

  /// Starting offset, as a fraction of the child's height.
  final double offset;

  @override
  State<AppearIn> createState() => _AppearInState();
}

class _AppearInState extends State<AppearIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: Motion.medium);
  late final CurvedAnimation _curved = CurvedAnimation(parent: _c, curve: Motion.enter);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (widget.animate && !Motion.reduced(context)) {
      _c.forward();
    } else {
      _c.value = 1;
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = _curved;
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(begin: Offset(0, widget.offset), end: Offset.zero).animate(curved),
        child: widget.child,
      ),
    );
  }
}
