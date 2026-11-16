// Files for voice clips: native platforms record to and play from temp files; the web uses blob
// and data: URLs. Only voice_io_native.dart touches dart:io.
export 'voice_io_web.dart' if (dart.library.io) 'voice_io_native.dart';
