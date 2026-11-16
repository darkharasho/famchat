import 'package:famchat/theme/app_theme.dart';
import 'package:famchat/theme/person_colors.dart';
import 'package:famchat/widgets/brand_mark.dart';
import 'package:famchat/widgets/common.dart';
import 'package:famchat/widgets/person_avatar.dart';
import 'package:famchat/widgets/typing_dots.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget host(Widget child, {bool reduced = false}) => MaterialApp(
      theme: buildTheme(Brightness.light),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  test('initials take the first and last word', () {
    expect(initialsOf('Grandma Rose'), 'GR');
    expect(initialsOf('mom'), 'M');
    expect(initialsOf('  Mary Jo  Smith '), 'MS');
    expect(initialsOf(''), '?');
  });

  testWidgets('avatar color comes from the color key, not the name', (tester) async {
    await tester.pumpWidget(host(const Row(children: [
      PersonAvatar(key: Key('a'), label: 'Bob', colorKey: 'user-1'),
      PersonAvatar(key: Key('b'), label: 'Robert', colorKey: 'user-1', online: true),
    ])));
    Color colorOf(String k) => ((tester.widget<Container>(
      find.descendant(of: find.byKey(Key(k)), matching: find.byKey(const Key('avatar-circle'))),
    )).decoration! as BoxDecoration).color!;
    expect(colorOf('a'), personColor('user-1').bg);
    expect(colorOf('b'), colorOf('a'));
    expect(find.text('B'), findsOneWidget);
    expect(find.text('R'), findsOneWidget);
    expect(find.byKey(const Key('presence-dot')), findsOneWidget);
  });

  testWidgets('typing dots stay still when motion is reduced', (tester) async {
    await tester.pumpWidget(host(const TypingDots(), reduced: true));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('typing dots move otherwise', (tester) async {
    await tester.pumpWidget(host(const TypingDots()));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('AppearIn shows its child at once when not animating', (tester) async {
    await tester.pumpWidget(host(const AppearIn(animate: false, child: Text('hi'))));
    expect(tester.widget<FadeTransition>(find.byType(FadeTransition).last).opacity.value, 1);
  });

  testWidgets('AppearIn fades in when animating', (tester) async {
    await tester.pumpWidget(host(const AppearIn(child: Text('hi'))));
    expect(tester.widget<FadeTransition>(find.byType(FadeTransition).last).opacity.value, lessThan(1));
    await tester.pumpAndSettle();
    expect(tester.widget<FadeTransition>(find.byType(FadeTransition).last).opacity.value, 1);
  });

  testWidgets('brand mark paints at small and large sizes and is labelled', (tester) async {
    await tester.pumpWidget(host(const Column(mainAxisSize: MainAxisSize.min, children: [
      BrandMark(size: 24),
      BrandMark(size: 96),
      Wordmark(),
    ])));
    expect(tester.takeException(), isNull);
    expect(find.bySemanticsLabel('FamChat'), findsNWidgets(3)); // two marks, and the wordmark read once
  });
}
