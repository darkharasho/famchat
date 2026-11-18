import 'package:famchat/screens/chats/pane_divider.dart';
import 'package:famchat/settings/list_width.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// A stand-in for the two-pane shell: the list box, the divider over its edge.
class _Split extends ConsumerWidget {
  const _Split();

  @override
  Widget build(BuildContext context, WidgetRef ref) => LayoutBuilder(builder: (context, c) {
        final w = clampListWidth(ref.watch(listWidthProvider), c.maxWidth);
        return Stack(fit: StackFit.expand, children: [
          Positioned(left: 0, top: 0, bottom: 0, child: SizedBox(key: const Key('list'), width: w)),
          Positioned(left: w + 0.5 - PaneDivider.grabWidth / 2, top: 0, bottom: 0, child: PaneDivider(shownWidth: w)),
        ]);
      });
}

Future<void> pumpSplit(WidgetTester t) async {
  t.view.physicalSize = const Size(1200, 800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(const ProviderScope(child: MaterialApp(home: Scaffold(body: _Split()))));
  await t.pumpAndSettle();
}

double listWidth(WidgetTester t) => t.getSize(find.byKey(const Key('list'))).width;

void main() {
  setUp(() => SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty());

  test('clamps to the limits and leaves the conversation its room', () {
    expect(clampListWidth(360, 1200), 360);
    expect(clampListWidth(100, 1200), minListWidth);
    expect(clampListWidth(900, 1200), maxListWidth);
    expect(clampListWidth(500, 800), 800 - minConversationWidth);
    expect(clampListWidth(500, 600), minListWidth); // a tight window keeps the list usable
  });

  testWidgets('dragging resizes the list and is remembered', (t) async {
    await pumpSplit(t);
    expect(listWidth(t), defaultListWidth);
    await t.drag(find.byType(PaneDivider), const Offset(100, 0));
    await t.pumpAndSettle();
    expect(listWidth(t), closeTo(460, 1));
    expect(await SharedPreferencesAsync().getDouble(listWidthPrefKey), closeTo(460, 1));

    // A fresh app starts from the stored width.
    await t.pumpWidget(const SizedBox());
    await pumpSplit(t);
    expect(listWidth(t), closeTo(460, 1));
  });

  testWidgets('dragging stops at the limits', (t) async {
    await pumpSplit(t);
    await t.drag(find.byType(PaneDivider), const Offset(-500, 0));
    await t.pumpAndSettle();
    expect(listWidth(t), minListWidth);
    await t.drag(find.byType(PaneDivider), const Offset(1000, 0));
    await t.pumpAndSettle();
    expect(listWidth(t), maxListWidth);
  });

  testWidgets('double-click puts back the default', (t) async {
    await SharedPreferencesAsync().setDouble(listWidthPrefKey, 500);
    await pumpSplit(t);
    expect(listWidth(t), 500);
    await t.tap(find.byType(PaneDivider));
    await t.pump(const Duration(milliseconds: 50));
    await t.tap(find.byType(PaneDivider));
    await t.pumpAndSettle();
    expect(listWidth(t), defaultListWidth);
    expect(await SharedPreferencesAsync().getDouble(listWidthPrefKey), isNull);
  });
}
