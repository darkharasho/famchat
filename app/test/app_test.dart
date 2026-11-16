import 'package:famchat/session/secure_kv.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_harness.dart';
import 'support/fake_server.dart';

void main() {
  testWidgets('empty storage opens the join screen', (tester) async {
    await pumpApp(tester, server: FakeServer(), kv: MemorySecureKv());
    expect(find.text('Join FamChat'), findsOneWidget);
  });

  testWidgets('spikes stay reachable when signed out', (tester) async {
    await pumpApp(tester, server: FakeServer(), kv: MemorySecureKv());
    appRouter(tester).go('/spikes');
    await tester.pumpAndSettle();
    expect(find.text('Platform spikes'), findsOneWidget);
  });
}
