import 'package:material_ui/material_ui.dart';

/// Motion is small and answers what the user did: a message arriving, a page opening, someone typing.
abstract final class Motion {
  static const fast = Duration(milliseconds: 120);
  static const medium = Duration(milliseconds: 220);
  static const slow = Duration(milliseconds: 320);

  static const enter = Curves.easeOutCubic;
  static const exit = Curves.easeInCubic;

  /// True when the platform asks for less motion (or animations are off).
  static bool reduced(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// [d], or zero when motion is reduced.
  static Duration of(BuildContext context, Duration d) => reduced(context) ? Duration.zero : d;
}

/// The platform's page transition, or none at all when motion is reduced.
class ReducedMotionTransitionsBuilder extends PageTransitionsBuilder {
  const ReducedMotionTransitionsBuilder(this.inner);

  final PageTransitionsBuilder inner;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (Motion.reduced(context)) return child;
    return inner.buildTransitions(route, context, animation, secondaryAnimation, child);
  }
}
