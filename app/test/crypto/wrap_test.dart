import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/keys.dart';
import 'package:famchat/crypto/sealed_box.dart';
import 'package:famchat/crypto/wrap.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DeviceKeys wrapper, me, other;
  late Uint8List chatKey;

  setUpAll(() async {
    wrapper = await DeviceKeys.generate();
    me = await DeviceKeys.generate();
    other = await DeviceKeys.generate();
    chatKey = newChatKey();
  });

  Future<ChatKeyWrap> wrap({List<int>? key}) async => wrapChatKey(
        chatKey: key ?? chatKey,
        chatId: 'C1',
        epoch: 3,
        recipientDeviceId: 'DB',
        recipientEncPub: await me.encPub(),
        wrapperDeviceId: 'DA',
        wrapperSignKey: wrapper.sign,
      );

  Future<Uint8List> unwrap(ChatKeyWrap w, {String chatId = 'C1', int epoch = 3, String deviceId = 'DB', List<int>? signPub}) async =>
      unwrapChatKey(
        wrap: w,
        chatId: chatId,
        epoch: epoch,
        myDeviceId: deviceId,
        me: me,
        wrapperSignPub: signPub ?? await wrapper.signPub(),
      );

  Matcher fails() => throwsA(isA<CryptoFailure>());

  test('wrap then unwrap returns the chat key', () async {
    final w = await wrap();
    expect(w.sig.length, 64);
    expect(await unwrap(w), chatKey);
    expect(await unwrap(ChatKeyWrap.fromJson(w.toJson())), chatKey);
  });

  test('wrap moved to another chat, epoch or device is rejected', () async {
    final w = await wrap();
    // The server rewrites the row's fields; the reader expects the new values, so only the signature can catch it.
    final movedChat = ChatKeyWrap(chatId: 'C2', epoch: 3, recipientDeviceId: 'DB', wrapperDeviceId: 'DA', sealed: w.sealed, sig: w.sig);
    await expectLater(unwrap(movedChat, chatId: 'C2'), fails());
    final movedEpoch = ChatKeyWrap(chatId: 'C1', epoch: 4, recipientDeviceId: 'DB', wrapperDeviceId: 'DA', sealed: w.sealed, sig: w.sig);
    await expectLater(unwrap(movedEpoch, epoch: 4), fails());
    final movedDevice = ChatKeyWrap(chatId: 'C1', epoch: 3, recipientDeviceId: 'DC', wrapperDeviceId: 'DA', sealed: w.sealed, sig: w.sig);
    await expectLater(unwrap(movedDevice, deviceId: 'DC'), fails());
    final otherWrapper = ChatKeyWrap(chatId: 'C1', epoch: 3, recipientDeviceId: 'DB', wrapperDeviceId: 'DX', sealed: w.sealed, sig: w.sig);
    await expectLater(unwrap(otherWrapper), fails());
    // An intact wrap served for a different chat, epoch or device than the reader asked for.
    await expectLater(unwrap(w, chatId: 'C2'), fails());
    await expectLater(unwrap(w, epoch: 4), fails());
    await expectLater(unwrap(w, deviceId: 'DC'), fails());
  });

  test('wrap signed by a different device is rejected', () async {
    final w = await wrap();
    await expectLater(unwrap(w, signPub: await other.signPub()), fails());
  });

  test('changed sealed bytes are rejected', () async {
    final w = await wrap();
    final sealed = Uint8List.fromList(w.sealed)..[40] ^= 1;
    final t = ChatKeyWrap(chatId: 'C1', epoch: 3, recipientDeviceId: 'DB', wrapperDeviceId: 'DA', sealed: sealed, sig: w.sig);
    await expectLater(unwrap(t), fails());
  });

  test('chat key must be 32 bytes', () async {
    await expectLater(wrap(key: Uint8List(31)), throwsArgumentError);
  });

  test('wrapped key that is not 32 bytes is rejected', () async {
    // A member device signs a wrap of a 16-byte value: signature is fine, result is refused.
    final sealed = await sealBox(await me.encPub(), Uint8List(16));
    final sig = Uint8List.fromList(
        (await Ed25519().sign(wrapSignedBytes('C1', 3, 'DB', 'DA', sealed), keyPair: wrapper.sign)).bytes);
    final w = ChatKeyWrap(chatId: 'C1', epoch: 3, recipientDeviceId: 'DB', wrapperDeviceId: 'DA', sealed: sealed, sig: sig);
    await expectLater(unwrap(w), fails());
  });

  test('wrapSignedBytes layout', () {
    final b = wrapSignedBytes('C', 1, 'R', 'W', [9, 9]);
    expect(b, [
      ...'famchat-wrap-v1'.codeUnits,
      0, 1, 0x43, 0, 0, 0, 1, 0, 1, 0x52, 0, 1, 0x57, 9, 9,
    ]);
  });

  test('malformed wrap json throws CryptoFailure', () async {
    final good = (await wrap()).toJson();
    final cases = <String, Map<String, Object?>>{
      'missing sig': Map.of(good)..remove('sig'),
      'missing chatId': Map.of(good)..remove('chatId'),
      'epoch as string': Map.of(good)..['epoch'] = '3',
      'negative epoch': Map.of(good)..['epoch'] = -1,
      'bad base64': Map.of(good)..['sealed'] = '***',
      'short sig': Map.of(good)..['sig'] = b64url([1, 2]),
      'short sealed': Map.of(good)..['sealed'] = b64url(Uint8List(10)),
    };
    cases.forEach((name, j) => expect(() => ChatKeyWrap.fromJson(j), fails(), reason: name));
  });
}
