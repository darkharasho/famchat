import 'dart:convert';
import 'dart:typed_data';

import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/crypto/media.dart';
import 'package:famchat/media/media_service.dart';
import 'package:flutter_test/flutter_test.dart';

Plaintext decode(Map<String, Object?> j) => Plaintext.decode(utf8.encode(jsonEncode(j)));

void main() {
  final key = Uint8List.fromList(List.filled(32, 1));
  final sha = Uint8List.fromList(List.filled(32, 2));
  final withImage = LinkPreview(
    url: 'https://youtube.com/shorts/x',
    title: 'Cat jumps',
    description: 'Cats Inc',
    siteName: 'YouTube',
    image: PreviewImage(mediaKey: '01JC0000000000000000000000', key: key, sha256: sha, width: 320, height: 180),
  );

  test('texts carry a link preview, with or without an image', () {
    for (final p in [withImage, const LinkPreview(url: 'https://x.io', title: 'X')]) {
      final t = TextBody('look https://x.io', preview: p);
      final back = Plaintext.decode(t.encode()) as TextBody;
      expect(back.toJson(), t.toJson());
    }
    expect(const TextBody('hi').toJson().containsKey('preview'), isFalse);
    final ref = withImage.image!.ref;
    expect(ref, MediaRef(id: '01JC0000000000000000000000', key: key, sha256: sha, purpose: MediaPurpose.thumb));
  });

  test("a preview that doesn't check out is dropped, keeping the text", () {
    for (final bad in <Object?>[
      'x',
      {'url': 'javascript:alert(1)', 'title': 'x'},
      {'url': 'https://x.io'},
    ]) {
      final t = decode({'kind': 'text', 'text': 'hi', 'preview': bad}) as TextBody;
      expect((t.text, t.preview), ('hi', null), reason: '$bad');
    }
    final noImage = decode({'kind': 'text', 'text': 'hi', 'preview': {'url': 'https://x.io', 'title': 'x', 'image': {'mediaKey': 'nope'}}});
    expect(((noImage as TextBody).preview!.title, noImage.preview!.image), ('x', null), reason: 'a bad image is dropped');
  });
}
