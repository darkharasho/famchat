import 'dart:async';

import 'package:cross_file/cross_file.dart';

/// Web only: calls [onFiles] with the files pasted while [active] is true, keeping the browser
/// from pasting them as text. Elsewhere pasting goes through [readClipboardMedia]; returns null.
StreamSubscription<Object?>? listenForPastedFiles(bool Function() active, void Function(List<XFile> files) onFiles) =>
    null;
