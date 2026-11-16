import 'dart:typed_data';

import 'package:famchat/chat/providers.dart';
import 'package:famchat/pairing/bundle.dart';
import 'package:famchat/pairing/new_device_pairing.dart';
import 'package:famchat/pairing/pair_code.dart';
import 'package:famchat/pairing/pairing_providers.dart';
import 'package:famchat/session/secure_kv.dart';
import 'package:famchat/session/session_controller.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/app_harness.dart';
import '../support/chat_harness.dart';
import '../support/fake_server.dart';
import '../support/pairing_helpers.dart';

void main() {
  late DateTime clock;
  late FakeServer server;
  late MemorySecureKv kv;

  setUp(() {
    clock = DateTime(2026, 11, 16, 12);
    server = FakeServer(now: () => clock);
    kv = MemorySecureKv();
  });

  final fastPoll = [pairPollEveryProvider.overrideWithValue(const Duration(milliseconds: 50))];

  Future<void> openPair(WidgetTester tester, {List<Override> extra = const []}) async {
    await pumpApp(tester, server: server, kv: kv, extra: [...fastPoll, ...extra]);
    await tester.tap(find.byKey(const Key('pair-link')));
    await tester.pumpAndSettle();
  }

  /// Pumps [n] poll intervals (no pumpAndSettle while the code shows: its spinner never settles).
  Future<void> polls(WidgetTester tester, [int n = 6]) async {
    for (var i = 0; i < n * 5; i++) {
      await tester.pump(const Duration(milliseconds: 12));
    }
  }

  Future<PairCode> showCode(WidgetTester tester, {String name = 'Kitchen tablet'}) async {
    await openPair(tester);
    await tester.enterText(find.byKey(const Key('pair-device-name')), name);
    await tester.tap(find.byKey(const Key('pair-start')));
    await polls(tester, 1);
    expect(find.byKey(const Key('pair-qr')), findsOneWidget);
    return PairCode.parse(tester.widget<SelectableText>(find.byKey(const Key('pair-code'))).data!)!;
  }

  Future<void> tapCancel(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Cancel'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  }

  testWidgets('join screen links to pairing', (tester) async {
    await openPair(tester);
    expect(find.text('Show my code'), findsOneWidget);
  });

  chatTestWidgets('shows the code and QR, then signs in after approval', (tester) async {
    final code = await showCode(tester);
    expect(find.textContaining('Expires in 5:00'), findsOneWidget);
    final x = server.pairSessionByCode(code.lookup)!;
    expect(x.body['deviceName'], 'Kitchen tablet');

    final key = HandoverKey(chatId: 'C1', epoch: 1, key: Uint8List(32)..[3] = 4);
    final approver = (await tester.runAsync(() => approveByHand(server, code, keys: [key])))!;
    await polls(tester);
    await settle(tester);

    expect(find.text('No chats yet'), findsOneWidget);
    final session = (appContainer(tester).read(sessionProvider) as SignedIn).session;
    expect((session.userId, session.deviceId, session.deviceName), (approver.userId, x.deviceId, 'Kitchen tablet'));
    expect(kv.values, isNotEmpty);
    final db = appContainer(tester).read(chatDbProvider);
    expect(await inApp(tester, () => db.key('C1', 1)), key.key);
  });

  testWidgets('expired code offers a new one', (tester) async {
    final first = await showCode(tester);
    clock = clock.add(const Duration(minutes: 6));
    await polls(tester);
    await tester.pumpAndSettle();
    expect(find.text('This code expired.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('pair-restart')));
    await polls(tester, 1);
    final second = PairCode.parse(tester.widget<SelectableText>(find.byKey(const Key('pair-code'))).data!)!;
    expect(second.secret, isNot(first.secret));
    await tapCancel(tester);
  });

  testWidgets('cancel returns to join', (tester) async {
    final code = await showCode(tester);
    await tapCancel(tester);
    expect(find.text('Join FamChat'), findsOneWidget);
    expect(server.pairSessionByCode(code.lookup)!.cancelledAt, isNotNull);
  });

  group('a code from the other device (reverse pairing)', () {
    /// An offer from a signed-in device; returns the code that device would show.
    Future<PairCode> offer(WidgetTester tester) async {
      final alice = (await tester.runAsync(() => signedInClient(server)))!;
      final o = (await tester.runAsync(alice.api.pairOffer))!;
      return PairCode(o.lookup, newPairSecret());
    }

    Future<void> openEnter(WidgetTester tester, {List<Override> extra = const [], String name = 'New phone'}) async {
      await openPair(tester, extra: extra.isEmpty ? [qrScannerProvider.overrideWithValue(null)] : extra);
      await tester.enterText(find.byKey(const Key('pair-device-name')), name);
      await tester.tap(find.byKey(const Key('pair-scan-start')));
      await tester.pumpAndSettle();
    }

    /// Approves the session that took the offer, as the offering device would (by hand).
    Future<void> approveTaken(WidgetTester tester, PairCode code, {String? secret}) async {
      final x = server.pairSessions.values.single;
      expect(server.pairOffers.values.single.sessionId, x.id);
      await tester.runAsync(() => approveByHand(server, PairCode(x.code, code.secret), secret: secret));
    }

    chatTestWidgets('typed code from the other device signs in after approval', (tester) async {
      final code = await offer(tester);
      await openEnter(tester);
      expect(find.textContaining('Show a code'), findsWidgets);
      await tester.enterText(find.byKey(const Key('link-code-field')), code.display.toLowerCase());
      await tester.tap(find.byKey(const Key('link-connect')));
      await polls(tester, 1);
      expect(find.textContaining('approve "New phone"'), findsOneWidget);
      expect(server.pairSessions.values.single.body['deviceName'], 'New phone');

      await approveTaken(tester, code);
      await polls(tester);
      await settle(tester);
      expect(find.text('No chats yet'), findsOneWidget);
      expect(appContainer(tester).read(sessionProvider), isA<SignedIn>());
    });

    chatTestWidgets('a scanned code connects straight away', (tester) async {
      final code = await offer(tester);
      await openEnter(tester, extra: [
        qrScannerProvider.overrideWithValue(
          (context, onCode) => TextButton(onPressed: () => onCode(LinkQr(code).encode()), child: const Text('Fake scan')),
        ),
      ]);
      await tester.tap(find.text('Fake scan'));
      await polls(tester, 1);
      expect(server.pairOffers.values.single.sessionId, isNotNull);
      expect(find.textContaining('approve "New phone"'), findsOneWidget);
      await tapCancel(tester);
      expect(server.pairSessions.values.single.cancelledAt, isNotNull);
    });

    testWidgets('a bad or unknown code shows an error and lets you try again', (tester) async {
      await openEnter(tester);
      await tester.enterText(find.byKey(const Key('link-code-field')), 'hello');
      await tester.tap(find.byKey(const Key('link-connect')));
      await tester.pumpAndSettle();
      expect(find.textContaining("isn't a FamChat code"), findsOneWidget);
      expect(server.pairSessions, isEmpty);

      await tester.enterText(find.byKey(const Key('link-code-field')), 'ZZZZ-ABCD-EFGH-0123');
      await tester.tap(find.byKey(const Key('link-connect')));
      await tester.pumpAndSettle();
      expect(find.text(unknownOfferMessage), findsOneWidget);
      await tester.tap(find.byKey(const Key('pair-restart')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('link-code-field')), findsOneWidget);
    });

    testWidgets('a forged approval is refused', (tester) async {
      final code = await offer(tester);
      await openEnter(tester);
      await tester.enterText(find.byKey(const Key('link-code-field')), code.display);
      await tester.tap(find.byKey(const Key('link-connect')));
      await polls(tester, 1);
      await approveTaken(tester, code, secret: 'ZZZZZZZZZZZZ');
      await polls(tester);
      await tester.pumpAndSettle();
      expect(find.text(forgedBundleMessage), findsOneWidget);
      expect(appContainer(tester).read(sessionProvider), isA<SignedOut>());
    });
  });

  testWidgets('a forged approval is refused and nothing is saved', (tester) async {
    final code = await showCode(tester);
    await tester.runAsync(() => approveByHand(server, code, secret: 'ZZZZZZZZZZZZ'));
    await polls(tester);
    await tester.pumpAndSettle();
    expect(find.text(forgedBundleMessage), findsOneWidget);
    expect(kv.values, isEmpty);
    expect(appContainer(tester).read(sessionProvider), isA<SignedOut>());
  });
}
