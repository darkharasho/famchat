import 'package:famchat/main.dart';
import 'package:famchat/router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows home', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: FamChatApp()));
    expect(find.text('FamChat'), findsWidgets);
  });

  testWidgets('navigates to spikes', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: FamChatApp()));
    appRouter.go('/spikes');
    await tester.pumpAndSettle();
    expect(find.text('Platform spikes'), findsOneWidget);
    appRouter.go('/');
    await tester.pumpAndSettle();
  });
}
