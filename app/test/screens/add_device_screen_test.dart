import 'dart:typed_data';

import 'package:famchat/chat/providers.dart';
import 'package:famchat/crypto/device_cert.dart';
import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/keys.dart';
import 'package:famchat/crypto/pairing.dart';
import 'package:famchat/pairing/bundle.dart';
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
  late FakeServer server;
  late MemorySecureKv kv;

  setUp(() {
    server = FakeServer();
    kv = MemorySecureKv();
  });

  Future<void> openAdd(WidgetTester tester, {List<Override> extra = const []}) async {
    await pumpApp(tester, server: server, kv: kv, extra: extra.isEmpty ? [qrScannerProvider.overrideWithValue(null)] : extra);
    await signInDirectly(tester, server, name: 'Alice');
    await tester.tap(find.byTooltip('Devices'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-device')));
    await tester.pumpAndSettle();
  }

  Future<StartedPairing> newDevice(WidgetTester tester, {String name = 'Kitchen tablet', String platform = 'android'}) async =>
      (await tester.runAsync(() => startPairing(server, deviceName: name, platform: platform)))!;

  Future<void> find_(WidgetTester tester, String code) async {
    await tester.enterText(find.byKey(const Key('pair-code-field')), code);
    await tester.tap(find.byKey(const Key('pair-find')));
    await settle(tester);
  }

  chatTestWidgets('Add a device opens the flow', (tester) async {
    await openAdd(tester);
    expect(find.text('Find device'), findsOneWidget);
    expect(find.textContaining('Then type the code it shows.'), findsOneWidget);
  });

  chatTestWidgets('typed code shows the device and approves it', (tester) async {
    await openAdd(tester);
    final db = appContainer(tester).read(chatDbProvider);
    final key = Uint8List(32)..[0] = 42;
    await inApp(tester, () => db.putKey('C1', 3, key));
    final n = await newDevice(tester);

    await find_(tester, n.code.display.toLowerCase());
    expect(find.text('Add "Kitchen tablet" (Android)?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('pair-approve')));
    await settle(tester);
    expect(find.textContaining('was approved'), findsOneWidget);

    final session = (appContainer(tester).read(sessionProvider) as SignedIn).session;
    final sealed = b64urlDecode(server.pairSessionByCode(n.code.lookup)!.bundle!);
    final bundle = (await tester.runAsync(
        () async => PairBundle.decode(await openPairBundle(eph: n.eph, secret: n.code.secret, sealed: sealed))))!;
    expect(bundle.userId, session.userId);
    expect(b64url(bundle.identitySeed), session.identitySeed);
    expect(bundle.keys.single.chatId, 'C1');
    expect(bundle.keys.single.key, key);
    final ok = (await tester.runAsync(() async {
      final identity = await session.identityKey();
      return verifyDeviceCert(DeviceCert(await publicKeyOf(identity), await n.keys.encPub(), await n.keys.signPub(), bundle.certSig));
    }))!;
    expect(ok, isTrue);
  });

  chatTestWidgets('wrong code shows an error', (tester) async {
    await openAdd(tester);
    await find_(tester, 'hello');
    expect(find.textContaining("That isn't a pairing code"), findsOneWidget);
    await find_(tester, 'ZZZZ-ABCD-EFGH-0123');
    expect(find.textContaining('No device is waiting with that code'), findsOneWidget);
  });

  chatTestWidgets('swapped keys show a warning and nothing is approved', (tester) async {
    await openAdd(tester);
    final n = await newDevice(tester);
    final evil = (await tester.runAsync(DeviceKeys.generate))!;
    server.tamperNextLookup = {'encPub': b64url((await tester.runAsync(evil.encPub))!)};
    await find_(tester, n.code.display);
    expect(find.textContaining("doesn't match the device"), findsOneWidget);
    expect(find.byKey(const Key('pair-approve')), findsNothing);
    expect(server.pairSessionByCode(n.code.lookup)!.approvedAt, isNull);
  });

  chatTestWidgets('scanner result goes straight to confirmation', (tester) async {
    var qr = '';
    await openAdd(tester, extra: [
      qrScannerProvider.overrideWithValue(
        (context, onCode) => Center(child: TextButton(onPressed: () => onCode(qr), child: const Text('Fake scan'))),
      ),
    ]);
    expect(find.textContaining('Then scan the code it shows, or type it.'), findsOneWidget);
    final n = await newDevice(tester, name: 'Work laptop', platform: 'windows');
    qr = n.qr;
    await tester.tap(find.text('Fake scan'));
    await settle(tester);
    expect(find.text('Add "Work laptop" (Windows)?'), findsOneWidget);
  });
}
