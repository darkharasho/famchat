import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'file_actions.dart';

/// The browser downloads it (there is no app to hand it to).
Future<OpenOutcome> openFileBytes({required String id, required String name, required String mime, required Uint8List bytes}) async {
  _download(name, mime, bytes);
  return OpenOutcome.opened;
}

Future<bool> saveFileBytes({required String name, required String mime, required Uint8List bytes}) async {
  _download(name, mime, bytes);
  return true;
}

void _download(String name, String mime, Uint8List bytes) {
  final url = web.URL.createObjectURL(web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mime)));
  final a = web.HTMLAnchorElement()
    ..href = url
    ..download = name;
  web.document.body?.append(a);
  a.click();
  a.remove();
  // After the click has started the download.
  Future<void>.delayed(const Duration(seconds: 30), () => web.URL.revokeObjectURL(url));
}

/// Nothing is written to disk on the web.
Future<void> sweepOpenedFiles() async {}

/// Nothing is written to disk on the web.
Future<void> dropOpenedFile(String id) async {}
