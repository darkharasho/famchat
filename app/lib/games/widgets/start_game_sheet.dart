import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/providers.dart';
import '../../theme/tokens.dart';
import '../game_state.dart';
import '../providers.dart';
import '../rules.dart';
import 'game_bar.dart' show gameGlyph;
import 'game_screen.dart';

/// Asks which game to start in direct chat [chatId], starts it with me first
/// and opens the board. With a game unfinished it offers to open that one.
Future<void> showStartGameSheet(BuildContext context, String chatId) async {
  final choice = await showModalBottomSheet<Object>(
    context: context,
    builder: (context) => StartGameSheet(chatId: chatId),
  );
  if (choice == null || !context.mounted) return;
  if (choice is String) {
    unawaited(openGame(context, chatId, choice));
    return;
  }
  final container = ProviderScope.containerOf(context, listen: false);
  final sync = container.read(chatSyncProvider);
  final me = container.read(myUserIdProvider);
  if (sync == null || me == null || choice is! GameType) return;
  final id = await sync.startGame(chatId, choice, first: me);
  if (context.mounted) unawaited(openGame(context, chatId, id));
}

/// The sheet's body. Pops with a [GameType] to start, or the id of the
/// unfinished game to open.
class StartGameSheet extends ConsumerWidget {
  const StartGameSheet({super.key, required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final active = activeGame(ref.watch(gamesProvider(chatId)));
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.xl,
              Space.lg,
              Space.xl,
              Space.sm,
            ),
            child: Text('Play a game', style: theme.textTheme.titleMedium),
          ),
          if (active != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.xl,
                0,
                Space.xl,
                Space.lg,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Finish your current game first',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, active.id),
                    child: const Text('Open'),
                  ),
                ],
              ),
            )
          else
            for (final t in GameType.values)
              ListTile(
                leading: SizedBox.square(
                  dimension: 24,
                  child: Center(
                    child: Text(
                      gameGlyph(t),
                      style: TextStyle(
                        fontSize: 20,
                        height: 1,
                        fontFamily: t == GameType.tictactoe
                            ? null
                            : 'NotoSansSymbols2',
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                title: Text(t.title),
                onTap: () => Navigator.pop(context, t),
              ),
          const SizedBox(height: Space.sm),
        ],
      ),
    );
  }
}
