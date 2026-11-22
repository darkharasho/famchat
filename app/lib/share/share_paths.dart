// Which shared paths may be sent (see share_paths_io.dart). Only that file touches dart:io.
export 'share_paths_stub.dart' if (dart.library.io) 'share_paths_io.dart';
