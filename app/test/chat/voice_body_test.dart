import 'dart:convert';
import 'dart:typed_data';

import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/media.dart';
import 'package:famchat/media/media_service.dart';
import 'package:flutter_test/flutter_test.dart';

const mediaKey = '01JC0000000000000000000000';

VoiceBody voice({int durationMs = 4200, List<int>? waveform}) => VoiceBody(
      mediaKey: mediaKey,
      key: Uint8List.fromList(List.filled(32, 1)),
      sha256: Uint8List.fromList(List.filled(32, 2)),
      durationMs: durationMs,
      waveform: waveform ?? [for (var i = 0; i < 64; i++) i * 4],
      bytes: 25000,
    );

Map<String, Object?> json(VoiceBody v) => v.toJson();

Plaintext decode(Map<String, Object?> j) => Plaintext.decode(utf8.encode(jsonEncode(j)));

void main() {
  test('round-trips through encode/decode', () {
    final v = voice();
    final back = Plaintext.decode(v.encode()) as VoiceBody;
    expect(back.kind, 'voice');
    expect(back.mediaKey, mediaKey);
    expect(back.key, v.key);
    expect(back.sha256, v.sha256);
    expect(back.durationMs, 4200);
    expect(back.waveform, v.waveform);
    expect(back.bytes, 25000);
    expect(back.mime, 'audio/mp4');
  });

  test('waveform travels as b64url bytes', () {
    final j = json(voice(waveform: [0, 255, 7]));
    expect(j['waveform'], b64url(Uint8List.fromList([0, 255, 7])));
  });

  test('an empty waveform is allowed', () {
    expect((decode(json(voice(waveform: const []))) as VoiceBody).waveform, isEmpty);
  });

  test('ref points at the clip blob as a file', () {
    final r = voice().ref;
    expect(r.id, mediaKey);
    expect(r.purpose, MediaPurpose.file);
    expect(r.sha256, voice().sha256);
  });

  for (final (name, patch) in <(String, Map<String, Object?>)>[
    ('bad mediaKey', {'mediaKey': '../x'}),
    ('short key', {'key': b64url(Uint8List(16))}),
    ('bad sha256', {'sha256': 7}),
    ('zero duration', {'durationMs': 0}),
    ('duration over 15 minutes', {'durationMs': 900001}),
    ('fractional duration', {'durationMs': 1.5}),
    ('waveform too long', {'waveform': b64url(Uint8List(129))}),
    ('waveform not b64url', {'waveform': [1, 2, 3]}),
    ('bytes missing', {'bytes': null}),
    ('empty mime', {'mime': ''}),
  ]) {
    test('rejects $name', () {
      expect(() => decode({...json(voice()), ...patch}), throwsFormatException);
    });
  }

  test('accepts 15 minutes', () {
    expect((decode({...json(voice()), 'durationMs': 900000}) as VoiceBody).durationMs, 900000);
  });

  group('transcript', () {
    test('decodes target, text and lang, and round-trips', () {
      final t = decode({'kind': 'transcript', 'target': 'm1', 'text': 'hi', 'lang': 'en'}) as TranscriptBody;
      expect((t.kind, t.target, t.text, t.lang), ('transcript', 'm1', 'hi', 'en'));
      final back = Plaintext.decode(t.encode()) as TranscriptBody;
      expect((back.target, back.text, back.lang), ('m1', 'hi', 'en'));
    });

    test('lang is optional; a bad lang is dropped', () {
      TranscriptBody t(Object? lang) =>
          decode({'kind': 'transcript', 'target': 'm1', 'text': 'hi', 'lang': ?lang}) as TranscriptBody;
      expect(t(null).lang, isNull);
      expect(t(5).lang, isNull);
      expect(t('x' * 17).lang, isNull);
      expect(t(null).toJson().containsKey('lang'), isFalse);
    });

    test('rejects empty or missing target or text, and text over 20000', () {
      for (final j in [
        {'kind': 'transcript', 'text': 'hi'},
        {'kind': 'transcript', 'target': '', 'text': 'hi'},
        {'kind': 'transcript', 'target': 'm1'},
        {'kind': 'transcript', 'target': 'm1', 'text': ''},
        {'kind': 'transcript', 'target': 'm1', 'text': 'x' * (maxTranscriptLength + 1)},
      ]) {
        expect(() => decode(j), throwsFormatException, reason: '$j');
      }
      expect(decode({'kind': 'transcript', 'target': 'm1', 'text': 'x' * maxTranscriptLength}), isA<TranscriptBody>());
    });
  });
}
