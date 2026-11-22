// Files sent in a chat: reading a file message, and how one is described (type, size, label).
import 'dart:convert';

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
};

/// A MIME type for [name] when the platform gave none, or null.
String? mimeForName(String name) => _mimes[fileExtension(name)];

/// Programs and scripts: never opened from FamChat with a tap (opening one runs it). They can be
/// saved and opened from there.
const runnableExtensions = {
  'exe', 'msi', 'msix', 'appx', 'bat', 'cmd', 'com', 'scr', 'pif', 'cpl', 'ps1', 'psm1', 'vbs', 'vbe', 'js', 'jse',
  'wsf', 'wsh', 'hta', 'lnk', 'url', 'reg', 'inf', 'jar', 'sh', 'bash', 'zsh', 'command', 'tool', 'app', 'pkg',
  'dmg', 'desktop', 'appimage', 'run', 'bin', 'deb', 'rpm', 'apk', 'xapk', 'aab', 'ipa', 'mobileconfig', 'workflow',
};

bool isRunnable(String name) => runnableExtensions.contains(fileExtension(name));
