// Received files per platform: opening a decrypted one in another app, and saving a copy. Only
// file_io_native.dart touches dart:io.
export 'file_io_web.dart' if (dart.library.io) 'file_io_native.dart';
