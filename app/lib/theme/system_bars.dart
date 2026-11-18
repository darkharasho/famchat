// The phone's own status and navigation bars, coloured from the theme. App bars and the onboarding
// hero set their own style over this; this covers everything else, like the navigation bar.
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// The status and navigation bar style for [scheme]: transparent status bar, the navigation bar
/// in the page colour, and icons that read on both.
SystemUiOverlayStyle systemBarsStyleFor(ColorScheme scheme) {
  final dark = scheme.brightness == Brightness.dark;
  final icons = dark ? Brightness.light : Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: const Color(0x00000000),
    statusBarIconBrightness: icons,
    statusBarBrightness: scheme.brightness, // iOS: the brightness of what's behind the bar
    systemNavigationBarColor: scheme.surface,
    systemNavigationBarDividerColor: scheme.surface,
    systemNavigationBarIconBrightness: icons,
    systemNavigationBarContrastEnforced: false,
  );
}

class SystemBarsStyle extends StatelessWidget {
  const SystemBarsStyle({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      AnnotatedRegion<SystemUiOverlayStyle>(value: systemBarsStyleFor(Theme.of(context).colorScheme), child: child);
}
