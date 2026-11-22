// Files sent in a chat: reading a file message, and how one is described (type, size, label).
import 'dart:convert';

import 'package:characters/characters.dart';

import 'db/chat_db.dart';
import 'plaintext.dart';

/// The file in [m], or null (not a file, or a body this version can't read).
FileBody? fileOf(MessageRow m) {
  if (m.kind != 'file' || m.body == null) return null;
  try {
    final p = Plaintext.decode(utf8.encode(m.body!));
    return p is FileBody ? p : null;
  } on FormatException {
    return null;
  }
}

/// "812 B", "14 KB", "2.4 MB", "1.1 GB" (powers of 1024, one decimal under 10).
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  // 9.96 rounds to "10.0": show whole numbers from 9.95 up.
  final s = v < 9.95 ? v.toStringAsFixed(1) : v.round().toString();
  return '${s.endsWith('.0') ? s.substring(0, s.length - 2) : s} ${units[i]}';
}

/// What kind of file it is, for its icon.
enum FileCategory { pdf, document, spreadsheet, slides, archive, audio, code, image, video, generic }

/// [name]'s extension, lowercased and without the dot ('' when it has none).
String fileExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 || dot == name.length - 1 ? '' : name.substring(dot + 1).toLowerCase();
}

final _byExtension = {
  'pdf': FileCategory.pdf,
  for (final e in ['doc', 'docx', 'odt', 'rtf', 'pages', 'txt', 'md']) e: FileCategory.document,
  for (final e in ['xls', 'xlsx', 'ods', 'csv', 'tsv', 'numbers']) e: FileCategory.spreadsheet,
  for (final e in ['ppt', 'pptx', 'odp', 'key']) e: FileCategory.slides,
  for (final e in ['zip', 'rar', '7z', 'tar', 'gz', 'tgz', 'bz2', 'xz', 'zst']) e: FileCategory.archive,
  for (final e in ['mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'opus', 'aiff', 'wma']) e: FileCategory.audio,
  for (final e in [
    'json', 'xml', 'yaml', 'yml', 'toml', 'html', 'htm', 'css', 'js', 'ts', 'dart', 'py', 'java', 'kt', 'swift',
    'c', 'h', 'cpp', 'cs', 'go', 'rs', 'rb', 'php', 'sh', 'sql', 'log', 'ini', 'conf',
  ])
    e: FileCategory.code,
  for (final e in ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp', 'tif', 'tiff', 'svg']) e: FileCategory.image,
  for (final e in ['mp4', 'mov', 'm4v', 'mkv', 'webm', 'avi', 'wmv']) e: FileCategory.video,
};

/// The file's category, from its extension, else its MIME type.
FileCategory fileCategoryOf(String name, String mime) {
  final byName = _byExtension[fileExtension(name)];
  if (byName != null) return byName;
  final m = mime.toLowerCase();
  if (m == 'application/pdf') return FileCategory.pdf;
  if (m.startsWith('audio/')) return FileCategory.audio;
  if (m.startsWith('image/')) return FileCategory.image;
  if (m.startsWith('video/')) return FileCategory.video;
  if (m.startsWith('text/')) return FileCategory.code;
  if (m.contains('zip') || m.contains('compressed') || m.contains('x-tar')) return FileCategory.archive;
  if (m.contains('spreadsheet') || m.contains('excel')) return FileCategory.spreadsheet;
  if (m.contains('presentation') || m.contains('powerpoint')) return FileCategory.slides;
  if (m.contains('word') || m.contains('opendocument.text')) return FileCategory.document;
  return FileCategory.generic;
}

/// A short type label: "PDF", "DOCX" (the extension, up to 5 letters), else "File".
String fileTypeLabel(String name) {
  final ext = fileExtension(name);
  return ext.isEmpty || ext.length > 5 ? 'File' : ext.toUpperCase();
}

const _mimes = {
  'pdf': 'application/pdf',
  'txt': 'text/plain',
  'md': 'text/markdown',
  'csv': 'text/csv',
  'json': 'application/json',
  'html': 'text/html',
  'rtf': 'application/rtf',
  'doc': 'application/msword',
  'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'odt': 'application/vnd.oasis.opendocument.text',
  'ods': 'application/vnd.oasis.opendocument.spreadsheet',
  'odp': 'application/vnd.oasis.opendocument.presentation',
  'zip': 'application/zip',
  'gz': 'application/gzip',
  '7z': 'application/x-7z-compressed',
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'wav': 'audio/wav',
  'ogg': 'audio/ogg',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'mp4': 'video/mp4',
  'mov': 'video/quicktime',
  'm4v': 'video/x-m4v',
  'webm': 'video/webm',
  'mkv': 'video/x-matroska',
  'avi': 'video/x-msvideo',
  'webp': 'image/webp',
  'heic': 'image/heic',
  'heif': 'image/heif',
  'bmp': 'image/bmp',
  'tif': 'image/tiff',
  'tiff': 'image/tiff',
  'aac': 'audio/aac',
  'flac': 'audio/flac',
  'opus': 'audio/opus',
  'aiff': 'audio/aiff',
  'tar': 'application/x-tar',
  'tgz': 'application/gzip',
  'rar': 'application/vnd.rar',
};

/// A MIME type for [name] when the platform gave none, or null.
String? mimeForName(String name) => _mimes[fileExtension(name)];

/// What a tap may open in another app: documents, media and archives, by extension. Anything else
/// (programs, scripts, shortcuts, disk images, macro documents, …) is only saved, never opened:
/// opening one can run it.
const openableExtensions = {
  'pdf',
  'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp', 'tif', 'tiff',
  'mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'opus', 'aiff',
  'mp4', 'mov', 'm4v', 'webm', 'mkv', 'avi',
  'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'odt', 'ods', 'odp', 'rtf', 'pages', 'numbers', 'key',
  'txt', 'csv', 'md', 'json',
  'zip', '7z', 'tar', 'gz', 'tgz', 'rar',
};

/// Whether a tap may open [name] (the name as written to disk) in another app.
bool opensWithTap(String name) => openableExtensions.contains(fileExtension(name));

/// Characters Windows doesn't allow in a file name (and the separators everywhere).
final _forbiddenOnDisk = RegExp(r'[<>:"/\\|?*\u0000-\u001F]');

/// Device names Windows reserves, with any extension ("CON.txt" is the console).
final _reservedOnWindows = RegExp(r'^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])$', caseSensitive: false);

/// Longest file name on disk, in UTF-8 bytes (ext4 and APFS count bytes).
const maxDiskNameBytes = 255;

/// [name] as a file name every platform can write: characters Windows forbids become `_`, reserved
/// device names get a `_` in front, trailing dots and spaces go, and it's cut to
/// [maxDiskNameBytes] UTF-8 bytes keeping the extension (never splitting a character). [name]
/// itself is still what's shown.
String diskFileName(String name) {
  final trailing = RegExp(r'[.\s]+$');
  var n = name.replaceAll(_forbiddenOnDisk, '_').trim().replaceFirst(trailing, '');
  final dot = n.indexOf('.');
  if (_reservedOnWindows.hasMatch((dot < 0 ? n : n.substring(0, dot)).trimRight())) n = '_$n';
  if (utf8.encode(n).length > maxDiskNameBytes) {
    final ext = fileExtension(n);
    final suffix = ext.isEmpty || ext.length > 16 ? '' : '.${n.substring(n.length - ext.length)}';
    final room = maxDiskNameBytes - utf8.encode(suffix).length;
    final base = StringBuffer();
    var used = 0;
    for (final c in n.substring(0, n.length - suffix.length).characters) {
      final size = utf8.encode(c).length;
      if (used + size > room) break;
      base.write(c);
      used += size;
    }
    n = '${base.toString().replaceFirst(trailing, '')}$suffix';
  }
  n = n.replaceFirst(trailing, '');
  return n.isEmpty ? 'file' : n;
}
