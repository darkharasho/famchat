import 'dart:io';

import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/games/rules.dart';
import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';
import 'game_ui_test.dart' show chatId, direct, game;

/// Loads the app's own fonts, so text widths are real (the default test font
/// draws every glyph as a square of the font size).
Future<void> loadFonts() async {
  final families = <String, List<String>>{
    'AtkinsonHyperlegibleNext': [
      'AtkinsonHyperlegibleNext-Regular',
      'AtkinsonHyperlegibleNext-Medium',
      'AtkinsonHyperlegibleNext-Bold',
    ],
    'FamiljenGrotesk': [
      'FamiljenGrotesk-Medium',
      'FamiljenGrotesk-SemiBold',
      'FamiljenGrotesk-Bold',
    ],
    'NotoSansSymbols2': ['NotoSansSymbols2-Regular'],
  };
  for (final MapEntry(key: family, value: files) in families.entries) {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(
        Future.value(
          ByteData.sublistView(File('assets/fonts/$f.ttf').readAsBytesSync()),
        ),
      );
    }
    await loader.load();
  }
}

void main() {
  late FakeChatBackend backend;
  late TestDevice alice, grandma;

  setUpAll(loadFonts);

  setUp(() async {
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    grandma = await backend.addUser('Grandma');
  });

  Future<void> open(WidgetTester tester, List<MessageRow> messages) async {
    setWindow(tester, const Size(380, 800));
    await pumpChatApp(tester, alice);
    await inApp(tester, () async {
      await alice.db.upsertChat(direct(alice.userId, grandma.userId));
      for (final m in messages) {
        await alice.db.insertMessageIfAbsent(m);
      }
    });
    ProviderScope.containerOf(tester.element(find.byType(FamChatApp)))
        .read(routerProvider)
        .go('/chats/$chatId');
    await settle(tester);
  }

  chatTestWidgets(
    'at 380px both halves show their game and whose turn it is, uncut',
    (tester) async {
      await open(tester, [
        game('g1', GameType.tictactoe, grandma.userId),
        game('g2', GameType.landlord, grandma.userId, seed: 1),
      ]);
      expect(
        find.byKey(const Key('poke')),
        findsNWidgets(2),
        reason: "it's Grandma's turn in both",
      );
      for (final id in ['g1', 'g2']) {
        final half = find.byKey(Key('game-bar-$id'));
        expect(
          find.descendant(
            of: half,
            matching: find.textContaining("Grandma's turn", findRichText: true),
          ),
          findsOneWidget,
        );
        for (final p in tester.renderObjectList<RenderParagraph>(
          find.descendant(of: half, matching: find.byType(RichText)),
        )) {
          expect(
            p.didExceedMaxLines,
            isFalse,
            reason: '$id: "${p.text.toPlainText()}" is cut off',
          );
        }
      }
    },
  );
}
