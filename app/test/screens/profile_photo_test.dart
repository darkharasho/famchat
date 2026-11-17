import 'dart:typed_data';

import 'package:famchat/chat/chat_sync.dart';
import 'package:famchat/main.dart';
import 'package:famchat/media/photo_picker.dart';
import 'package:famchat/router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

import '../support/chat_harness.dart';
import '../support/fake_chat_backend.dart';

/// A 12×8 photo: the profile photo is its centered 8×8 square.
final photo = Uint8List.fromList(img.encodePng(img.Image(width: 12, height: 8)));

void main() {
  late FakeChatBackend backend;
  late TestDevice alice, bob;

  setUp(() async {
    backend = FakeChatBackend();
    alice = await backend.addUser('Alice');
    bob = await backend.addUser('Bob');
  });

  void go(WidgetTester tester, String to) =>
      ProviderScope.containerOf(tester.element(find.byType(FamChatApp))).read(routerProvider).go(to);

  chatTestWidgets('set a profile photo from Settings, then remove it', (tester) async {
    setWindow(tester, const Size(400, 800));
    final hub = await pumpChatApp(tester, alice, picker: (source) async => [PickedPhoto(photo)]);
    hub.setConnected(true);
    go(tester, '/settings');
    await settle(tester);
    expect(find.byKey(const Key('avatar-photo')), findsNothing);

    await tester.tap(find.text('Profile photo'));
    await settle(tester);
    expect(find.text('Remove photo'), findsNothing);
    await tester.tap(find.text('Choose a photo'));
    await settle(tester);

    final sent = backend.avatarOf(alice.userId);
    expect(sent, isNotNull);
    final square = img.decodeJpg(sent!)!;
    expect((square.width, square.height), (8, 8));
    expect(find.byKey(const Key('avatar-photo')), findsOneWidget);
    expect(backend.avatarDownloads, isEmpty, reason: 'your own photo is cached as it is set');

    await tester.tap(find.text('Profile photo'));
    await settle(tester);
    await tester.tap(find.text('Remove photo'));
    await settle(tester);
    expect(backend.avatarOf(alice.userId), isNull);
    expect(find.byKey(const Key('avatar-photo')), findsNothing);
  });

  chatTestWidgets("someone's photo shows on their chat, downloaded once", (tester) async {
    setWindow(tester, const Size(400, 800));
    backend.setAvatar(bob.userId, photo);
    await pumpChatApp(tester, alice);
    await inApp(tester, () => ChatSync(db: alice.db, api: alice.api, hub: alice.hub, me: alice.me).openDirect(bob.userId));
    await settle(tester);
    expect(find.byKey(const Key('avatar-photo')), findsOneWidget);
    go(tester, '/settings');
    await settle(tester);
    go(tester, '/');
    await settle(tester);
    expect(find.byKey(const Key('avatar-photo')), findsOneWidget);
    expect(backend.avatarDownloads, hasLength(1));
  });
}
