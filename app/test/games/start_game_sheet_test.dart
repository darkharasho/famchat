import 'package:famchat/games/providers.dart';
import 'package:famchat/games/rules.dart';
import 'package:famchat/games/widgets/start_game_sheet.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Future<Object?> pick(WidgetTester tester, Future<void> Function() act) async {
    Object? result;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [gamesProvider('c').overrideWithValue(const [])],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async =>
                    result = await showModalBottomSheet<Object>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => const StartGameSheet(chatId: 'c'),
                    ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await act();
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('checkers starts with mandatory jumps by default', (
    tester,
  ) async {
    final r = await pick(tester, () async {
      expect(find.text('If you can jump, you have to'), findsOneWidget);
      await tester.tap(find.text('Checkers'));
    });
    expect(r, isA<StartChoice>());
    expect((r! as StartChoice).type, GameType.checkers);
    expect((r as StartChoice).optionalJumps, isFalse);
  });

  testWidgets('the chip makes jumps optional', (tester) async {
    final r = await pick(tester, () async {
      await tester.tap(find.byKey(const Key('optional-jumps')));
      await tester.pump();
      expect(find.text('Jumps are optional'), findsOneWidget);
      await tester.tap(find.text('Checkers'));
    });
    expect((r! as StartChoice).optionalJumps, isTrue);
  });

  testWidgets('other games never carry the rule', (tester) async {
    final r = await pick(tester, () async {
      await tester.tap(find.byKey(const Key('optional-jumps')));
      await tester.pump();
      await tester.tap(find.text('Chess'));
    });
    expect((r! as StartChoice).type, GameType.chess);
    expect((r as StartChoice).optionalJumps, isFalse);
  });

  testWidgets('the War chip plays to the whole deck', (tester) async {
    final r = await pick(tester, () async {
      await tester.tap(find.byKey(const Key('whole-deck')));
      await tester.pump();
      expect(
        find.text('Flip cards, higher wins. Play until someone has them all'),
        findsOneWidget,
      );
      await tester.tap(find.text('War'));
    });
    expect((r! as StartChoice).type, GameType.war);
    expect((r as StartChoice).wholeDeck, isTrue);
    expect(r.optionalJumps, isFalse);
  });

  testWidgets('the War chip lets a 2 beat an ace', (tester) async {
    final r = await pick(tester, () async {
      await tester.tap(find.byKey(const Key('twos-beat-aces')));
      await tester.pump();
      expect(find.text('Flip cards, higher wins. Most cards after one deck. A 2 beats an ace'), findsOneWidget);
      await tester.tap(find.text('War'));
    });
    expect((r! as StartChoice).twosBeatAces, isTrue);
    expect((r as StartChoice).wholeDeck, isFalse);
  });
}
