// Disappearing messages (docs/protocol.md "Disappearing messages"): the setting's sheet, shared by
// chat info and the chat's menu, and the line the timeline shows where someone changed it.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/chat_sync.dart' show ChatSync;
import '../../chat/db/chat_db.dart';
import '../../chat/providers.dart';
import '../../theme/tokens.dart';
import '../sign_out.dart' show apiErrorMessage;

/// "Off", "24 hours", "7 days" or "90 days".
String disappearLabel(int? secs) => switch (secs) {
      null => 'Off',
      86400 => '24 hours',
      _ when secs % 86400 == 0 => '${secs ~/ 86400} days',
      _ => '${secs ~/ 3600} hours',
    };

/// The timeline line for the chat's latest timer change, or null before any.
String? disappearNoteText(ChatRow chat, String Function(String userId) nameOf) {
  final by = chat.disappearChangedBy;
  if (by == null || chat.disappearChangedSeq == null) return null;
  final secs = chat.disappearSecs;
  return secs == null
      ? '${nameOf(by)} turned off disappearing messages'
      : '${nameOf(by)} turned on disappearing messages: ${disappearLabel(secs)}';
}

/// Asks for [chat]'s timer and sets it for everyone; errors show as a snack bar. Returns whether it
/// changed.
Future<bool> changeDisappearing(BuildContext context, WidgetRef ref, ChatRow chat) async {
  final sync = ref.read(chatSyncProvider);
  if (sync == null) return false;
  final picked = await showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _DisappearingSheet(current: chat.disappearSecs),
  );
  if (picked == null) return false;
  final secs = picked == 0 ? null : picked;
  if (secs == chat.disappearSecs) return false;
  try {
    await sync.setDisappearing(chat.id, secs);
    return true;
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(apiErrorMessage(e))));
    return false;
  }
}

class _DisappearingSheet extends StatelessWidget {
  const _DisappearingSheet({required this.current});

  final int? current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.xl, Space.lg, Space.xl, Space.xs),
            child: Text('Disappearing messages', style: theme.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.xl, 0, Space.xl, Space.sm),
            child: Text(
              'New messages disappear for each person that long after they read them, and your own that '
              'long after you send them. Anyone in the chat can change this. Screenshots and copying '
              "aren't blocked.",
              style: theme.textTheme.bodyMedium?.copyWith(color: s.onSurfaceVariant),
            ),
          ),
          for (final secs in [null, ...ChatSync.disappearOptions])
            ListTile(
              key: Key('disappear-${secs ?? 'off'}'),
              leading: Icon(secs == null ? Icons.timer_off_outlined : Icons.timer_outlined),
              title: Text(disappearLabel(secs)),
              trailing: secs == current ? Icon(Icons.check_rounded, color: s.primary, semanticLabel: 'Current') : null,
              selected: secs == current,
              onTap: () => Navigator.pop(context, secs ?? 0),
            ),
          const SizedBox(height: Space.sm),
        ]),
      ),
    );
  }
}

/// The line in the timeline where someone changed the timer.
class DisappearNoteLine extends StatelessWidget {
  const DisappearNoteLine({super.key, required this.text, required this.on});

  final String text;
  final bool on;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Center(
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: s.surfaceContainerLowest,
            shape: StadiumBorder(side: BorderSide(color: s.outlineVariant)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 5),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(on ? Icons.timer_outlined : Icons.timer_off_outlined, size: 14, color: s.onSurfaceVariant),
              const SizedBox(width: 6),
              Flexible(child: Text(text, textAlign: TextAlign.center, style: theme.textTheme.labelMedium?.copyWith(color: s.onSurfaceVariant))),
            ]),
          ),
        ),
      ),
    );
  }
}
