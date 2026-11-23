import 'package:material_ui/material_ui.dart';

import 'palette.dart';

/// Spacing scale (logical pixels).
abstract final class Space {
  static const xs = 4.0, sm = 8.0, md = 12.0, lg = 16.0, xl = 24.0, xxl = 32.0, xxxl = 48.0;
}

/// Corner radii. Bubbles use [lg] with [xs] on the sender's side inside a run.
abstract final class Radii {
  static const xs = 6.0, sm = 10.0, md = 16.0, lg = 22.0;
}

/// Layout widths.
abstract final class Widths {
  /// Settings and onboarding columns.
  static const form = 440.0;
  static const page = 640.0;

  /// The message column inside a wide conversation pane.
  static const conversation = 760.0;
}

/// Your own messages' fill: [start] at the top left fading to [end] at the bottom right.
LinearGradient mineBubbleGradient(Color start, Color end) =>
    LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [start, end]);

/// Chat colors that ColorScheme has no slot for.
@immutable
class FamTokens extends ThemeExtension<FamTokens> {
  const FamTokens({
    required this.mineBubble,
    required this.mineBubbleEnd,
    required this.onMineBubble,
    required this.mineMeta,
    required this.theirsBubble,
    required this.onTheirsBubble,
    required this.theirsMeta,
    required this.theirsBorder,
    required this.chatBackdrop,
    required this.presence,
    required this.badge,
    required this.onBadge,
  });

  /// Your own messages are a gradient from [mineBubble] to [mineBubbleEnd]; see [mineGradient].
  final Color mineBubble, mineBubbleEnd, onMineBubble, mineMeta;
  final Color theirsBubble, onTheirsBubble, theirsMeta, theirsBorder;
  final Color chatBackdrop, presence, badge, onBadge;

  static const light = FamTokens(
    mineBubble: Palette.glow,
    mineBubbleEnd: Palette.glowRose,
    onMineBubble: Palette.glowInk,
    mineMeta: Palette.glowMeta,
    theirsBubble: Color(0xFFFFFFFF),
    onTheirsBubble: Palette.ink,
    theirsMeta: Palette.inkMuted,
    theirsBorder: Palette.lilacLine,
    chatBackdrop: Palette.lilac200,
    presence: Palette.fern,
    badge: Palette.glow,
    onBadge: Palette.glowInk,
  );

  static const dark = FamTokens(
    mineBubble: Palette.glowEvening,
    mineBubbleEnd: Palette.glowViolet,
    onMineBubble: Palette.glowInkEvening,
    mineMeta: Palette.glowMetaEvening,
    theirsBubble: Palette.night400,
    onTheirsBubble: Palette.moon,
    theirsMeta: Palette.moonMuted,
    theirsBorder: Palette.night500,
    chatBackdrop: Palette.night100,
    presence: Palette.fernNight,
    badge: Palette.glowEvening,
    onBadge: Palette.glowInkEvening,
  );

  /// The fill of your own messages.
  LinearGradient get mineGradient => mineBubbleGradient(mineBubble, mineBubbleEnd);

  static FamTokens of(BuildContext context) =>
      Theme.of(context).extension<FamTokens>() ??
      (Theme.of(context).brightness == Brightness.dark ? dark : light);

  @override
  FamTokens copyWith({
    Color? mineBubble,
    Color? mineBubbleEnd,
    Color? onMineBubble,
    Color? mineMeta,
    Color? theirsBubble,
    Color? onTheirsBubble,
    Color? theirsMeta,
    Color? theirsBorder,
    Color? chatBackdrop,
    Color? presence,
    Color? badge,
    Color? onBadge,
  }) =>
      FamTokens(
        mineBubble: mineBubble ?? this.mineBubble,
        mineBubbleEnd: mineBubbleEnd ?? this.mineBubbleEnd,
        onMineBubble: onMineBubble ?? this.onMineBubble,
        mineMeta: mineMeta ?? this.mineMeta,
        theirsBubble: theirsBubble ?? this.theirsBubble,
        onTheirsBubble: onTheirsBubble ?? this.onTheirsBubble,
        theirsMeta: theirsMeta ?? this.theirsMeta,
        theirsBorder: theirsBorder ?? this.theirsBorder,
        chatBackdrop: chatBackdrop ?? this.chatBackdrop,
        presence: presence ?? this.presence,
        badge: badge ?? this.badge,
        onBadge: onBadge ?? this.onBadge,
      );

  @override
  FamTokens lerp(FamTokens? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return FamTokens(
      mineBubble: l(mineBubble, other.mineBubble),
      mineBubbleEnd: l(mineBubbleEnd, other.mineBubbleEnd),
      onMineBubble: l(onMineBubble, other.onMineBubble),
      mineMeta: l(mineMeta, other.mineMeta),
      theirsBubble: l(theirsBubble, other.theirsBubble),
      onTheirsBubble: l(onTheirsBubble, other.onTheirsBubble),
      theirsMeta: l(theirsMeta, other.theirsMeta),
      theirsBorder: l(theirsBorder, other.theirsBorder),
      chatBackdrop: l(chatBackdrop, other.chatBackdrop),
      presence: l(presence, other.presence),
      badge: l(badge, other.badge),
      onBadge: l(onBadge, other.onBadge),
    );
  }
}
