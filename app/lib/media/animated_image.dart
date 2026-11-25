// GIF links (docs/protocol.md "Link previews"): checks that a preview image the server marked
// animated really is an animated GIF or WebP, and reads its size from the header (no decoding).
import 'dart:typed_data';

/// The width and height of [b] when it's an animated GIF (2+ frames or a loop block) or an
/// animated WebP, else null.
(int, int)? animatedImageSize(Uint8List b) {
  bool ascii(int at, String s) {
    if (at + s.length > b.length) return false;
    for (var k = 0; k < s.length; k++) {
      if (b[at + k] != s.codeUnitAt(k)) return false;
    }
    return true;
  }

  if (b.length >= 13 && ascii(0, 'GIF8')) {
    final w = b[6] | b[7] << 8, h = b[8] | b[9] << 8;
    if (w == 0 || h == 0) return null;
    var controls = 0;
    for (var i = 13; i + 3 < b.length; i++) {
      if (b[i] != 0x21) continue;
      if (b[i + 1] == 0xff && b[i + 2] == 0x0b && b[i + 3] == 0x4e) return (w, h); // NETSCAPE2.0
      if (b[i + 1] == 0xf9 && b[i + 2] == 0x04 && ++controls >= 2) return (w, h);
    }
    return null;
  }
  // RIFF....WEBPVP8X, the animation flag, then the canvas size less one (24-bit little-endian).
  if (b.length >= 30 && ascii(0, 'RIFF') && ascii(8, 'WEBPVP8X') && b[20] & 0x02 != 0) {
    final w = (b[24] | b[25] << 8 | b[26] << 16) + 1, h = (b[27] | b[28] << 8 | b[29] << 16) + 1;
    return (w, h);
  }
  return null;
}
