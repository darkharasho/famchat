import 'dart:convert';
import 'dart:typed_data';

import 'package:famchat/media/photo.dart';
import 'package:famchat/media/photo_processor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

bool isJpeg(Uint8List b) => b.length > 3 && b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff;

bool containsAscii(Uint8List b, String s) {
  final needle = ascii.encode(s);
  outer:
  for (var i = 0; i + needle.length <= b.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (b[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final processor = PlatformPhotoProcessor();

  test('fitWithin scales the long side down and never up', () {
    expect(fitWithin(3000, 1000, 2048), (2048, 683));
    expect(fitWithin(1000, 3000, 2048), (683, 2048));
    expect(fitWithin(800, 600, 2048), (800, 600));
    expect(fitWithin(5000, 1, 320), (320, 1));
  });

  test('a 3000×1000 PNG becomes a 2048×683 JPEG and a 320×107 thumb', () async {
    final src = img.Image(width: 3000, height: 1000);
    img.fill(src, color: img.ColorRgb8(200, 30, 30));
    final p = await processor.process(img.encodePng(src));
    expect((p.width, p.height), (2048, 683));
    expect(isJpeg(p.full) && isJpeg(p.thumb), isTrue);
    final full = img.decodeJpg(p.full)!, thumb = img.decodeJpg(p.thumb)!;
    expect((full.width, full.height), (2048, 683));
    expect((thumb.width, thumb.height), (320, 107));
    final px = full.getPixel(100, 100);
    expect((px.r - 200).abs() < 10 && px.g < 45 && px.b < 45, isTrue, reason: 'colour kept: $px');
  });

  test('a small image is not upscaled', () async {
    final p = await processor.process(img.encodeJpg(img.Image(width: 200, height: 100)));
    expect((p.width, p.height), (200, 100));
    final thumb = img.decodeJpg(p.thumb)!;
    expect((thumb.width, thumb.height), (200, 100));
  });

  test('EXIF (camera, location) is dropped and orientation applied', () async {
    final src = img.Image(width: 400, height: 200);
    src.exif.imageIfd['Make'] = 'SecretCam';
    src.exif.imageIfd['Orientation'] = 6; // rotate 90° clockwise to display
    final p = await processor.process(img.encodeJpg(src));
    expect(containsAscii(p.full, 'SecretCam'), isFalse);
    expect(containsAscii(p.full, 'Exif'), isFalse);
    expect(containsAscii(p.thumb, 'Exif'), isFalse);
    expect((p.width, p.height), (200, 400));
  });

  test('garbage bytes throw UnsupportedImageException', () async {
    await expectLater(processor.process(Uint8List.fromList(List.filled(100, 7))), throwsA(isA<UnsupportedImageException>()));
  });
}
