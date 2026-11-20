// Photos and videos on the clipboard, for pasting into a chat. Desktop clipboards can hold copied
// files (from a file manager) or image data (a screenshot, "Copy image"); phones hold image data.
// On the web the browser hands pasted files to a `paste` event instead (clipboard_paste_web.dart).
import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

import 'photo_picker.dart';
import 'send_media.dart';

export 'clipboard_paste_stub.dart' if (dart.library.js_interop) 'clipboard_paste_web.dart';

typedef ClipboardMediaReader = Future<List<PickedMedia>> Function();

bool get _desktop =>
    !kIsWeb && {TargetPlatform.linux, TargetPlatform.macOS, TargetPlatform.windows}.contains(defaultTargetPlatform);

/// The photos and videos on the clipboard (at most [maxPhotosPerPick]); empty when there are none
/// or it can't be read. Never throws.
Future<List<PickedMedia>> readClipboardMedia() async {
  try {
    if (_desktop) {
      final files = await Pasteboard.files();
      if (files.isNotEmpty) {
        final sorted = await pickedFromFiles([for (final f in files.take(maxPhotosPerPick)) XFile(f)]);
        if (sorted.media.isNotEmpty) return sorted.media;
      }
    }
    // Text wins over an image: Word, Excel and web pages copy a picture of the text alongside it.
    if (await Clipboard.hasStrings()) return const [];
    final image = await Pasteboard.image;
    if (image != null && image.isNotEmpty) return [PickedPhoto(image)];
  } catch (e) {
    debugPrint('clipboard read failed: $e');
  }
  return const [];
}
