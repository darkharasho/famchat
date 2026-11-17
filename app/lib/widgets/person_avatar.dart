import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../profile/avatar.dart';

import '../theme/app_theme.dart';
import '../theme/person_colors.dart';
import '../theme/tokens.dart';

/// "GR" for "Grandma Rose", "M" for "Mom", "?" for nothing.
String initialsOf(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '?';
  String first(String w) => w.characters.first.toUpperCase();
  return words.length == 1 ? first(words.single) : '${first(words.first)}${first(words.last)}';
}

/// A round avatar in the person's (or group's) own hue, with an optional presence dot.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({
    super.key,
    required this.label,
    required this.colorKey,
    this.group = false,
    this.online = false,
    this.radius = 20,
    this.ringColor,
    this.userId,
  });

  /// Whose profile photo to show over the initials, if they have one.
  final String? userId;

  /// The name the initials come from.
  final String label;

  /// What picks the hue: a user id, or a chat id for groups.
  final String colorKey;
  final bool group, online;
  final double radius;

  /// Around the presence dot; defaults to the surface color.
  final Color? ringColor;

  Widget initialsText(Color color, String initials) => Text(
        initials,
        textScaler: TextScaler.noScaling, // the circle doesn't grow, so neither does its label
        style: TextStyle(
          fontFamily: kDisplayFont,
          fontWeight: FontWeight.w700,
          fontSize: radius * (initials.length > 1 ? 0.72 : 0.86),
          height: 1,
          color: color,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final c = personColor(colorKey);
    final scheme = Theme.of(context).colorScheme;
    final d = radius * 2;
    final initials = initialsOf(label);
    return Semantics(
      label: online ? 'Online' : null,
      child: SizedBox.square(
        dimension: d,
        child: Stack(clipBehavior: Clip.none, children: [
          Container(
            key: const Key('avatar-circle'),
            width: d,
            height: d,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: c.bg, shape: BoxShape.circle),
            child: ExcludeSemantics(
              child: userId != null && !group
                  ? Consumer(builder: (context, ref, _) {
                      final photo = ref.watch(userPhotoProvider(userId!));
                      return photo == null ? initialsText(c.fg, initials) : _Photo(bytes: photo, diameter: d);
                    })
                  : group
                  ? Icon(Icons.groups_rounded, color: c.fg, size: radius * 1.1)
                  : initialsText(c.fg, initials),
            ),
          ),
          if (online)
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                key: const Key('presence-dot'),
                width: radius * 0.62,
                height: radius * 0.62,
                decoration: BoxDecoration(
                  color: FamTokens.of(context).presence,
                  shape: BoxShape.circle,
                  border: Border.all(color: ringColor ?? scheme.surface, width: radius < 16 ? 1.5 : 2.5),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

class _Photo extends StatelessWidget {
  const _Photo({required this.bytes, required this.diameter});
  final Uint8List bytes;
  final double diameter;

  @override
  Widget build(BuildContext context) => ClipOval(
        child: Image.memory(
          bytes,
          key: const Key('avatar-photo'),
          width: diameter,
          height: diameter,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          cacheWidth: (diameter * MediaQuery.devicePixelRatioOf(context)).ceil(),
          errorBuilder: (_, _, _) => const SizedBox(),
        ),
      );
}
