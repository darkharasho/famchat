// The web has no libmpv (media_kit's NativePlayer); decodeToPcm never calls this there.
import 'dart:typed_data';

Future<Float32List> decodeWithMpv(String m4aPath, {Duration timeout = const Duration(seconds: 60)}) =>
    throw UnsupportedError('not on the web');
