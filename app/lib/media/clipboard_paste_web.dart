import 'dart:async';
import 'dart:js_interop';

import 'package:cross_file/cross_file.dart';
import 'package:web/web.dart' as web;

/// Web only: calls [onFiles] with the photos and videos pasted while [active] is true, keeping the
/// browser from pasting anything else from that paste.
StreamSubscription<Object?>? listenForPastedFiles(bool Function() active, void Function(List<XFile> files) onFiles) =>
    web.EventStreamProviders.pasteEvent.forTarget(web.document).listen((event) {
      if (!active()) return;
      final list = event.clipboardData?.files;
      if (list == null || list.length == 0) return;
      final files = <web.File>[
        for (var i = 0; i < list.length; i++)
          if (list.item(i) case final f? when f.type.startsWith('image/') || f.type.startsWith('video/')) f,
      ];
      if (files.isEmpty) return;
      event.preventDefault();
      unawaited(() async {
        final out = <XFile>[];
        for (final f in files) {
          final buffer = await f.arrayBuffer().toDart;
          out.add(XFile.fromData(buffer.toDart.asUint8List(), name: f.name, mimeType: f.type));
        }
        onFiles(out);
      }());
    });
