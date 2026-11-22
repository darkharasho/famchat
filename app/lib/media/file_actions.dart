// Files in and out: picking files to send, and opening or saving a received one. Providers so
// tests swap in fakes (no system dialogs or other apps in tests).
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart' as fp;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'file_io.dart' as io;

/// How opening a file went. [notAllowed]: not a type a tap opens (see `opensWithTap`); save it.
enum OpenOutcome { opened, noApp, failed, notAllowed }

abstract interface class FileActions {
  /// Opens decrypted file [bytes] of message [id] in the system's app for it (the web downloads it).
  Future<OpenOutcome> open({required String id, required String name, required String mime, required Uint8List bytes});

  /// Saves a copy where the person picks; false when they cancelled.
  Future<bool> save({required String name, required String mime, required Uint8List bytes});
}

class PlatformFileActions implements FileActions {
  const PlatformFileActions();

  @override
  Future<OpenOutcome> open({required String id, required String name, required String mime, required Uint8List bytes}) =>
      io.openFileBytes(id: id, name: name, mime: mime, bytes: bytes);

  @override
  Future<bool> save({required String name, required String mime, required Uint8List bytes}) =>
      io.saveFileBytes(name: name, mime: mime, bytes: bytes);
}

final fileActionsProvider = Provider<FileActions>((ref) => const PlatformFileActions());

/// A file about to be sent: its size is checked before its bytes are read.
class OutgoingFile {
  const OutgoingFile({required this.name, required this.length, required this.read, this.openRead, this.mime});

  OutgoingFile.xfile(XFile f, {String? name})
      : this(name: name ?? f.name, length: f.length, read: f.readAsBytes, openRead: f.openRead, mime: f.mimeType);

  OutgoingFile.bytes(String name, Uint8List bytes, {String? mime})
      : this(name: name, length: () async => bytes.length, read: () async => bytes, mime: mime);

  final String name;
  final String? mime;

  /// Its size, or null when the platform can't tell without reading it.
  final Future<int?> Function() length;
  final Future<Uint8List> Function() read;

  /// Its bytes in chunks, to read a file of unknown size only up to the limit.
  final Stream<List<int>> Function()? openRead;
}

typedef FilesPicker = Future<List<OutgoingFile>> Function();

/// Any files, several at once; empty when cancelled.
Future<List<OutgoingFile>> pickFiles() async => [
      for (final f in await fp.FilePicker.pickFiles())
        OutgoingFile(
          name: f.name,
          length: () async => f.lengthSync() ?? await f.length(),
          read: f.readAsBytes,
          openRead: f.readAsByteStream,
          mime: f.xFile.mimeType,
        ),
    ];

final filePickerProvider = Provider<FilesPicker>((ref) => pickFiles);

/// Removes decrypted files opened in a previous run (or before signing out).
Future<void> sweepOpenedFiles() => io.sweepOpenedFiles();

/// Deletes the decrypted copy of message [id] left by opening it, if any.
Future<void> dropOpenedFile(String id) => io.dropOpenedFile(id);
