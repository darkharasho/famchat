// The signed-out screens: the mark and a headline on dusk (the same dusk as the launch screen),
// and the form on a sheet below it, or beside it on wide windows.
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/palette.dart';
import '../theme/tokens.dart';
import 'brand_mark.dart';

class OnboardingFrame extends StatelessWidget {
  const OnboardingFrame({super.key, required this.title, this.subtitle, required this.child, this.onBack});

  final String title;
  final String? subtitle;
  final Widget child;

  /// Shows a back button in the hero.
  final VoidCallback? onBack;

  static const wideWidth = 720.0;

  Widget _hero(BuildContext context, {required bool wide}) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: wide ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        BrandMark(size: wide ? 88 : 64),
        SizedBox(height: wide ? Space.xxl : Space.xl),
        Semantics(
          header: true,
          child: Text(
            title,
            textAlign: wide ? TextAlign.start : TextAlign.center,
            style: (wide ? text.displaySmall : text.headlineMedium)?.copyWith(color: Palette.moon),
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: Space.md),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Text(
              subtitle!,
              textAlign: wide ? TextAlign.start : TextAlign.center,
              style: text.bodyLarge?.copyWith(color: Palette.moonMuted),
            ),
          ),
        ],
      ],
    );
  }

  Widget _back() => onBack == null
      ? const SizedBox(height: 48)
      : Align(alignment: Alignment.centerLeft, child: BackButton(color: Palette.moon, onPressed: onBack));

  Widget _form() => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: Widths.form),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light, // light status bar icons over dusk
      child: Scaffold(
        backgroundColor: Palette.dusk,
        body: LayoutBuilder(builder: (context, c) {
          if (c.maxWidth >= wideWidth) {
            return Row(children: [
              Expanded(
                flex: 5,
                child: SafeArea(
                  right: false,
                  child: Padding(
                    padding: const EdgeInsets.all(Space.xl),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      _back(),
                      Expanded(
                        child: Center(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.symmetric(horizontal: Space.xxl),
                            child: _hero(context, wide: true),
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
              Expanded(
                flex: 6,
                child: ColoredBox(
                  color: surface,
                  child: SafeArea(
                    left: false,
                    child: Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(Space.xxl),
                        child: _form(),
                      ),
                    ),
                  ),
                ),
              ),
            ]);
          }
          return CustomScrollView(slivers: [
            SliverToBoxAdapter(
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Space.sm, Space.sm, Space.sm, Space.xxl),
                  child: Column(children: [
                    _back(),
                    Padding(padding: const EdgeInsets.symmetric(horizontal: Space.lg), child: _hero(context, wide: false)),
                  ]),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Container(
                decoration: BoxDecoration(
                  color: surface,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(Space.xl, Space.xxl, Space.xl, Space.xl),
                    child: Align(alignment: Alignment.topCenter, child: _form()),
                  ),
                ),
              ),
            ),
            // The sheet's color runs to the bottom of a short page.
            SliverFillRemaining(hasScrollBody: false, child: ColoredBox(color: surface)),
          ]);
        }),
      ),
    );
  }
}

/// "or", between two ways in.
class OrDivider extends StatelessWidget {
  const OrDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.lg),
      child: Row(children: [
        const Expanded(child: Divider()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.md),
          child: Text('or', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
        const Expanded(child: Divider()),
      ]),
    );
  }
}
