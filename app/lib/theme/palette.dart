// "Porch light": the named colors behind the default preset (presets.dart) and the brand (the mark,
// the launch and signed-out screens). Screens never use these directly; they read the ColorScheme
// or FamTokens app_theme.dart builds from the chosen preset.
import 'dart:ui' show Color;

abstract final class Palette {
  // Dusk: the ink of the day theme and the room of the evening theme.
  static const dusk = Color(0xFF2E2550);
  static const ink = Color(0xFF1F1A2E);
  static const inkMuted = Color(0xFF5B536C);

  // Porch amber: the window in the mark, and the evening theme's buttons.
  static const amber = Color(0xFFFFC75A);
  static const amberEvening = Color(0xFFF2B347);
  static const amberInk = Color(0xFF2B1D00);
  static const amberMeta = Color(0xFF5E4205);
  static const amberDeep = Color(0xFF7A4F00); // amber you can set text in, on light surfaces

  // Porch glow: your own messages, a gradient from brick to plum (day) or violet (evening) in
  // white text, and the unread badge (its start). Clear of the yellow of emoji faces.
  static const glow = Color(0xFFB83A1A);
  static const glowRose = Color(0xFF9E3A8C);
  static const glowEvening = Color(0xFFA63A0E);
  static const glowViolet = Color(0xFF7A3AA8);
  static const glowMeta = Color(0xFFF7EFEA); // times and "edited" on the glow

  // Lilac paper (day).
  static const lilac50 = Color(0xFFFBFAFD);
  static const lilac100 = Color(0xFFF6F4FA);
  static const lilac200 = Color(0xFFEFECF5);
  static const lilac300 = Color(0xFFE8E4F0);
  static const lilac400 = Color(0xFFE1DCEB);
  static const lilac500 = Color(0xFFD8D2E3);
  static const lilacLine = Color(0xFFDCD6E6);

  // Evening rooms (dark).
  static const night50 = Color(0xFF15111E);
  static const night100 = Color(0xFF1B1626);
  static const night200 = Color(0xFF221C2F);
  static const night300 = Color(0xFF282137);
  static const night400 = Color(0xFF2F2740);
  static const night500 = Color(0xFF372E4A);
  static const nightLine = Color(0xFF433957);
  static const moon = Color(0xFFEFEAF7);
  static const moonMuted = Color(0xFFBDB4CC);

  // Hydrangea: links, focus, quiet accents.
  static const hydrangea = Color(0xFF4B44C6);
  static const hydrangeaPale = Color(0xFFE3E1FF);
  static const hydrangeaNight = Color(0xFFB9B3FF);

  static const error = Color(0xFFB3261E);
  static const errorNight = Color(0xFFFFB4AB);
  static const fern = Color(0xFF2E9E5B);
  static const fernNight = Color(0xFF5BD08A);
}
