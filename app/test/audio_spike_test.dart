import 'package:famchat/spikes/audio_spike.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

int indexOf(Uint8List bytes, String tag) {
  final t = tag.codeUnits;
  outer:
  for (var i = 0; i + t.length <= bytes.length; i++) {
    for (var j = 0; j < t.length; j++) {
      if (bytes[i + j] != t[j]) continue outer;
    }
    return i;
  }
  return -1;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fixture is AAC-LC mono', () async {
    final bytes = (await rootBundle.load(kFixtureAsset)).buffer.asUint8List();
    expect(indexOf(bytes, 'ftyp'), 4);
    final mp4a = indexOf(bytes, 'mp4a');
    expect(mp4a, greaterThan(0));
    // AudioSampleEntry: type(4) reserved(6) dataRefIndex(2) reserved(8) channelCount(2)
    final channels = ByteData.sublistView(bytes, mp4a + 20, mp4a + 22).getUint16(0);
    expect(channels, 1);
    // esds DecoderSpecificInfo: audioObjectType (top 5 bits) 2 = AAC-LC
    final esds = indexOf(bytes, 'esds');
    expect(esds, greaterThan(mp4a));
    var p = esds + 8; // skip 'esds' + version/flags
    int len() {
      var n = 0;
      int b;
      do {
        b = bytes[p++];
        n = (n << 7) | (b & 0x7f);
      } while (b & 0x80 != 0);
      return n;
    }

    expect(bytes[p++], 0x03); // ES_Descriptor
    len();
    p += 2; // ES_ID
    expect(bytes[p++] & 0xe0, 0, reason: 'no ES flags expected');
    expect(bytes[p++], 0x04); // DecoderConfigDescriptor
    len();
    expect(bytes[p], 0x40, reason: 'MPEG-4 audio');
    p += 13;
    expect(bytes[p++], 0x05); // DecoderSpecificInfo
    len();
    expect(bytes[p] >> 3, 2, reason: 'audioObjectType 2 = AAC-LC');
  });
}
