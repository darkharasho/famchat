import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/screens/chats/message_bubble.dart';
import 'package:famchat/theme/app_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

MessageRow row(String text) => MessageRow(
      id: 'm1',
      chatId: 'c1',
      seq: 1,
      senderUserId: 'u1',
      senderDeviceId: 'd1',
      kind: 'text',
      body: '{"kind":"text","text":"$text"}',
      targetId: null,
      envelope: null,
      createdAt: DateTime(2026, 1, 1, 14, 5).millisecondsSinceEpoch,
      state: 'sent',
    );

Future<void> pump(WidgetTester tester, String text, {bool forwarded = false}) => tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: MessageBubble(
          message: row(text),
          mine: true,
          senderName: null,
          reactions: const {},
          myUserId: 'u1',
          onReact: (_) {},
          onRetry: () {},
          lastInGroup: true,
          forwarded: forwarded,
        ),
      ),
    ));

/// The bubble container (the one capped at 520 wide).
BoxDecoration? decoration(WidgetTester tester) => tester
    .widget<Container>(find.byWidgetPredicate((w) => w is Container && w.constraints?.maxWidth == 520))
    .decoration as BoxDecoration?;

double fontSize(WidgetTester tester, String text) => tester.widget<Text>(find.text(text)).style!.fontSize!;

void main() {
  testWidgets('one emoji alone: no bubble, and big', (tester) async {
    await pump(tester, '😂');
    expect(find.byKey(const Key('bare-emoji-m1')), findsOneWidget);
    expect(decoration(tester), isNull);
    expect(fontSize(tester, '😂'), 56);
  });

  testWidgets('two and three emoji step down in size, still no bubble', (tester) async {
    await pump(tester, '🌻⭐');
    expect(decoration(tester), isNull);
    expect(fontSize(tester, '🌻⭐'), 48);
    await pump(tester, '🌻⭐😊');
    expect(decoration(tester), isNull);
    expect(fontSize(tester, '🌻⭐😊'), 40);
  });

  testWidgets('four emoji, or emoji with text, keep the bubble', (tester) async {
    await pump(tester, '🌻⭐😊😂');
    expect(decoration(tester), isNotNull);
    await pump(tester, 'On my way 😄');
    expect(decoration(tester), isNotNull);
    expect(find.byKey(const Key('bare-emoji-m1')), findsNothing);
  });

  testWidgets('a forwarded emoji keeps its bubble (the label needs it)', (tester) async {
    await pump(tester, '😂', forwarded: true);
    expect(decoration(tester), isNotNull);
  });
}
