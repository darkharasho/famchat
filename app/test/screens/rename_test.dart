import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';

void main() {
  late FakeChatBackend backend;
  late TestDevice alice;

  setUp(() async {
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    await backend.addUser('Bob');
  });

  chatTestWidgets('rename yourself from Settings', (tester) async {
    setWindow(tester, const Size(400, 800));
    final hub = await pumpChatApp(tester, alice);
    hub.setConnected(true);
    ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider).go('/settings');
    await settle(tester);

    await tester.tap(find.byKey(const Key('settings-name')));
    await settle(tester);
    await tester.enterText(find.byKey(const Key('name-field')), '   ');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save')).onPressed, isNull, reason: 'blank');
    await tester.enterText(find.byKey(const Key('name-field')), '  Allie  ');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settle(tester);

    expect((await inApp(tester, () => alice.db.userById(alice.userId)))!.name, 'Allie');
    expect(find.text('Allie'), findsWidgets, reason: 'the Settings header shows the new name');
  });
}
