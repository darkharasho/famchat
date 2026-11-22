import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../chat/plaintext.dart' show FileBody;
import 'file_actions.dart';

/// Decrypted files are written to the app's own cache directory, one folder per message, for the
/// app that opens them; removed at sign-out and at the next start.
Future<Directory> _dir() async {
  final d = Directory('${(await getApplicationCacheDirectory()).path}/files');
  await d.create(recursive: true);
  return d;
}

String _safe(String id) => id.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_');

/// Writes [bytes] under [name] (already cleaned: no separators, never "." or "..") and opens it
/// with the system's app for it.
Future<OpenOutcome> openFileBytes({required String id, required String name, required String mime, required Uint8List bytes}) async {
  final folder = Directory('${(await _dir()).path}/${_safe(id)}');
  await folder.create(recursive: true);
  final f = File('${folder.path}/$name');
  await f.writeAsBytes(bytes, flush: true);
  if (Platform.isAndroid || Platform.isIOS) {
    final r = await OpenFilex.open(f.path, type: mime == FileBody.defaultMime ? null : mime);
    return switch (r.type) {
      ResultType.done => OpenOutcome.opened,
      ResultType.noAppToOpen => OpenOutcome.noApp,
      _ => OpenOutcome.failed,
    };
  }
  // Desktop: the shell's own "open" (no command line, so nothing in the name is ever run).
  return await launchUrl(Uri.file(f.path)) ? OpenOutcome.opened : OpenOutcome.noApp;
}

/// The system's save dialog (Files/Downloads on phones); false when cancelled.
Future<bool> saveFileBytes({required String name, required String mime, required Uint8List bytes}) async =>
    await FilePicker.saveFile(fileName: name, bytes: bytes, mimeType: mime) != null;

/// Removes files opened in a previous run.
Future<void> sweepOpenedFiles() async {
  try {
    await (await _dir()).delete(recursive: true);
  } catch (_) {
    // nothing to sweep
  }
}
