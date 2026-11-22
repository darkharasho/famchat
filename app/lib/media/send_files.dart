// Sending picked, dropped or shared files: each its own `file` message.
import '../chat/files.dart' show mimeForName;
import '../chat/plaintext.dart' show FileBody, cleanFileName;
import 'file_actions.dart';
import 'media_service.dart';

/// What couldn't be sent.
class FileSendReport {
  final tooLarge = <String>[];
  var failed = 0, sent = 0;

  /// What to tell the person, or null when everything went.
  String? get problem {
    final mb = (maxFileBytes / (1024 * 1024)).round();
    if (tooLarge.length == 1) return '"${tooLarge.single}" is too large to send ($mb MB max).';
    if (tooLarge.length > 1) return '${tooLarge.length} files are too large to send ($mb MB max).';
    if (failed > 0) return failed == 1 ? "That file couldn't be sent." : "$failed files couldn't be sent.";
    return null;
  }
}

/// Sends each of [files] to [chatId] in order; [replyTo] goes with the first one sent. Sizes are
/// checked before anything is read into memory.
Future<FileSendReport> sendFiles(MediaService media, String chatId, List<OutgoingFile> files, {String? replyTo}) async {
  final report = FileSendReport();
  for (final f in files) {
    final name = cleanFileName(f.name);
    // Pickers often say nothing, or only "some bytes": the extension tells more.
    final given = f.mime;
    final mime = given == null || given.isEmpty || given == FileBody.defaultMime ? mimeForName(name) ?? given : given;
    try {
      final size = await f.length();
      if (size > maxFileBytes) throw FileTooLargeException(size);
      await media.sendFile(chatId,
          name: name, bytes: await f.read(), mime: mime, replyTo: report.sent == 0 ? replyTo : null);
      report.sent++;
    } on FileTooLargeException {
      report.tooLarge.add(name);
    } catch (_) {
      report.failed++;
    }
  }
  return report;
}
