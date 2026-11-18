import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/screens/chats/message_bubble.dart';
import 'package:famchat/theme/app_theme.dart';
import 'package:famchat/widgets/link_text.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const id = 'm1';

MessageRow textRow({String state = 'sent'}) => MessageRow(
      id: id,
      chatId: 'c1',
      seq: state == 'sent' ? 1 : null,
      senderUserId: 'u1',
      senderDeviceId: 'd1',
      kind: 'text',
      body: '{"kind":"text","text":"Hello there"}',
      targetId: null,
      envelope: null,
      createdAt: DateTime(2026, 1, 1, 14, 5).millisecondsSinceEpoch,
      state: state,
    );

Future<void> pumpBubble(
  WidgetTester tester, {
  String state = 'sent',
  bool mine = true,
  bool lastInGroup = true,
  bool edited = false,
  double avatarSpace = 0,
  bool h24 = false,
  Map<String, Set<String>> reactions = const {},
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(alwaysUse24HourFormat: h24),
        child: MessageBubble(
          message: textRow(state: state),
          mine: mine,
          senderName: null,
          reactions: reactions,
          myUserId: 'u1',
          onReact: (_) {},
          onRetry: () {},
          lastInGroup: lastInGroup,
          edited: edited,
          avatarSpace: avatarSpace,
        ),
      ),
    ),
  ));
}

/// The bubble's decorated container (the one around the text).
Finder get bubble => find.ancestor(
      of: find.byType(LinkText),
      matching: find.byWidgetPredicate((w) => w is Container && w.decoration is BoxDecoration && w.constraints?.maxWidth == 520),
    );

Finder get time => find.byKey(const Key('time-$id'));

void main() {
  testWidgets('last in run: the time is under the bubble, outside it', (tester) async {
    await pumpBubble(tester);
    expect(find.text('2:05 PM'), findsOneWidget);
    expect(time, findsOneWidget);
    expect(find.descendant(of: bubble, matching: find.text('2:05 PM')), findsNothing);
    expect(tester.getTopLeft(time).dy, greaterThanOrEqualTo(tester.getBottomLeft(bubble).dy));
  });

  testWidgets('24-hour device shows 14:05', (tester) async {
    await pumpBubble(tester, h24: true);
    expect(find.text('14:05'), findsOneWidget);
    expect(find.descendant(of: bubble, matching: find.text('14:05')), findsNothing);
  });

  testWidgets('not last in run: no time', (tester) async {
    await pumpBubble(tester, lastInGroup: false);
    expect(time, findsNothing);
    expect(find.text('2:05 PM'), findsNothing);
  });

  testWidgets('pending mid-run: time and pending icon under the bubble', (tester) async {
    await pumpBubble(tester, state: 'pending', lastInGroup: false);
    final icon = find.byKey(const Key('pending-icon'));
    expect(time, findsOneWidget);
    expect(icon, findsOneWidget);
    final bottom = tester.getBottomLeft(bubble).dy;
    expect(tester.getTopLeft(time).dy, greaterThanOrEqualTo(bottom));
    expect(tester.getTopLeft(icon).dy, greaterThanOrEqualTo(bottom));
    expect(find.descendant(of: bubble, matching: icon), findsNothing);
  });

  testWidgets('edited mid-run: edited inside, no time', (tester) async {
    await pumpBubble(tester, edited: true, lastInGroup: false);
    expect(find.descendant(of: bubble, matching: find.text('edited')), findsOneWidget);
    expect(time, findsNothing);
  });

  testWidgets('theirs with avatar space: time lines up with the bubble', (tester) async {
    await pumpBubble(tester, mine: false, avatarSpace: 36);
    expect(time, findsOneWidget);
    expect(find.descendant(of: bubble, matching: time), findsNothing);
    expect(tester.getTopLeft(time).dx, greaterThanOrEqualTo(tester.getTopLeft(bubble).dx));
    expect(tester.getTopLeft(time).dx - tester.getTopLeft(bubble).dx, lessThanOrEqualTo(16));
  });

  testWidgets('mine: time right-aligned with the bubble', (tester) async {
    await pumpBubble(tester);
    expect((tester.getTopRight(time).dx - tester.getTopRight(bubble).dx).abs(), lessThanOrEqualTo(8));
  });

  testWidgets('with reactions: the time sits below the reaction pill', (tester) async {
    await pumpBubble(tester, reactions: {'❤️': {'me'}});
    final pill = find.text('❤️ 1');
    expect(pill, findsOneWidget);
    expect(time, findsOneWidget);
    expect(tester.getTopLeft(time).dy, greaterThanOrEqualTo(tester.getBottomLeft(pill).dy));
  });
}
