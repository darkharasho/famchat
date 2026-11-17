import 'dart:convert';
import 'dart:typed_data';

import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/crypto/media.dart';
import 'package:cross_file/cross_file.dart';
import 'package:famchat/media/media_service.dart';
import 'package:famchat/media/video.dart';
import 'package:flutter_test/flutter_test.dart';

const mediaKey = '01JC0000000000000000000000';
const thumbKey = '01JC0000000000000000000001';

VideoBody video({bool thumb = true}) => VideoBody(
      mediaKey: mediaKey,
      key: Uint8List.fromList(List.filled(32, 1)),
      sha256: Uint8List.fromList(List.filled(32, 2)),
      thumbKey: thumb ? thumbKey : null,
      thumbSha256: thumb ? Uint8List.fromList(List.filled(32, 3)) : null,
      width: 1280,
      height: 720,
      durationMs: 12500,
      bytes: 4000000,
    );

Plaintext decode(Map<String, Object?> j) => Plaintext.decode(utf8.encode(jsonEncode(j)));

void main() {
  test('round-trips, with and without a poster frame', () {
    for (final v in [video(), video(thumb: false)]) {
      final back = Plaintext.decode(v.encode()) as VideoBody;
      expect(back.toJson(), v.toJson());
      expect(back.kind, 'video');
      expect(back.mime, 'video/mp4');
    }
    expect(video(thumb: false).toJson().containsKey('thumbKey'), isFalse);
  });

  test('refs: the file and the poster frame, under one key', () {
    final v = video();
    expect(v.ref, MediaRef(id: mediaKey, key: v.key, sha256: v.sha256, purpose: MediaPurpose.file));
    expect(v.thumbRef, MediaRef(id: thumbKey, key: v.key, sha256: v.thumbSha256!, purpose: MediaPurpose.thumb));
    expect(video(thumb: false).thumbRef, isNull);
  });

  test('bad fields are refused', () {
    final good = video().toJson();
    for (final bad in <Map<String, Object?>>[
      {...good, 'durationMs': 0},
      {...good, 'width': -1},
      {...good, 'mediaKey': 'nope'},
      {...good, 'thumbKey': 'nope'},
      {...good}..remove('thumbSha256'), // a poster key without its hash
      {...good, 'bytes': 'big'},
    ]) {
      expect(() => decode(bad), throwsFormatException, reason: '$bad');
    }
  });

  test('only formats every platform plays are sent without converting', () {
    bool ok(String path, [String? mime]) => playsEverywhere(XFile(path, mimeType: mime));
    expect(ok('/a.mp4'), isTrue);
    expect(ok('/a.MOV'), isTrue);
    expect(ok('/a.m4v'), isTrue);
    expect(ok('/x', 'video/mp4'), isTrue);
    expect(ok('/x', 'video/quicktime'), isTrue);
    expect(ok('/a.mkv'), isFalse);
    expect(ok('/a.webm'), isFalse);
    expect(ok('/a.avi'), isFalse);
    expect(ok('/x', 'video/webm'), isFalse);
  });
}
