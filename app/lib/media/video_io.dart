// Video files per platform: preparing a picked video for sending, and giving a player something to
// open for a decrypted one. Only video_io_native.dart touches dart:io.
export 'video_io_web.dart' if (dart.library.io) 'video_io_native.dart';
