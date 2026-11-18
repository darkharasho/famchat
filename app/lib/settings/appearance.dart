// The per-device "Appearance" setting: Light, Dark or System, and a colour theme preset. Stored
// locally with SharedPreferencesAsync, like the time format; not synced to the account.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/presets.dart';

const themeModePrefKey = 'theme_mode';
const themePresetPrefKey = 'theme_preset';

@immutable
class Appearance {
  const Appearance({this.mode = ThemeMode.system, this.preset = ThemePreset.fallback});

  final ThemeMode mode;
  final ThemePreset preset;

  Appearance copyWith({ThemeMode? mode, ThemePreset? preset}) =>
      Appearance(mode: mode ?? this.mode, preset: preset ?? this.preset);

  @override
  bool operator ==(Object other) => other is Appearance && other.mode == mode && other.preset.id == preset.id;

  @override
  int get hashCode => Object.hash(mode, preset.id);
}

/// System and Porch light unless the user chose otherwise. An unknown stored mode reads as System
/// and an unknown preset id as the default preset; an unreadable store reads as both defaults.
Future<Appearance> readAppearance([SharedPreferencesAsync? prefs]) async {
  try {
    final p = prefs ?? SharedPreferencesAsync();
    final mode = await p.getString(themeModePrefKey);
    final preset = await p.getString(themePresetPrefKey);
    return Appearance(
      mode: ThemeMode.values.firstWhere((m) => m.name == mode, orElse: () => ThemeMode.system),
      preset: ThemePreset.byId(preset),
    );
  } catch (_) {
    return const Appearance();
  }
}

Future<void> writeAppearance(Appearance a, [SharedPreferencesAsync? prefs]) async {
  final p = prefs ?? SharedPreferencesAsync();
  await p.setString(themeModePrefKey, a.mode.name);
  await p.setString(themePresetPrefKey, a.preset.id);
}

/// What main() read from the device before the first frame, so the app starts in the chosen
/// theme rather than flashing the default.
final initialAppearanceProvider = Provider<Appearance>((ref) => const Appearance());

class AppearanceNotifier extends Notifier<Appearance> {
  @override
  Appearance build() => ref.watch(initialAppearanceProvider);

  Future<void> setMode(ThemeMode mode) => _set(state.copyWith(mode: mode));

  Future<void> setPreset(ThemePreset preset) => _set(state.copyWith(preset: preset));

  // Applies at once; saving is best effort, as a theme that doesn't stick is no reason to fail.
  Future<void> _set(Appearance a) async {
    state = a;
    try {
      await writeAppearance(a);
    } catch (e) {
      debugPrint('appearance not saved: $e');
    }
  }
}

final appearanceProvider = NotifierProvider<AppearanceNotifier, Appearance>(AppearanceNotifier.new);
