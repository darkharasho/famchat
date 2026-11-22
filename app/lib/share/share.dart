// Sharing into FamChat from other apps (the share sheet): what came in, where it comes from, and
// the share waiting for a chat to be picked.
import 'package:cross_file/cross_file.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../media/photo_picker.dart';
import 'share_source.dart';

/// Photos, videos, other files and/or text another app shared.
class IncomingShare {
  const IncomingShare({this.media = const [], this.files = const [], this.text});
  final List<PickedMedia> media;

  /// Anything that isn't a photo or video: sent as files.
  final List<XFile> files;
  final String? text;

  bool get isEmpty => media.isEmpty && files.isEmpty && (text == null || text!.trim().isEmpty);
}

abstract interface class ShareSource {
  /// What the app was opened with, if anything.
  Future<IncomingShare?> initial();

  /// Shares that arrive while it runs.
  Stream<IncomingShare> get updates;

  /// The current share was handled (sent or dropped).
  Future<void> done();
}

/// Platforms without a share sheet (desktop, web).
class NoShareSource implements ShareSource {
  const NoShareSource();

  @override
  Future<IncomingShare?> initial() async => null;

  @override
  Stream<IncomingShare> get updates => const Stream.empty();

  @override
  Future<void> done() async {}
}

final shareSourceProvider = Provider<ShareSource>((ref) => platformShareSource());

/// The share waiting for a chat (shown by the Send to screen).
class PendingShare extends Notifier<IncomingShare?> {
  @override
  IncomingShare? build() => null;

  void set(IncomingShare? share) => state = share;
}

final pendingShareProvider = NotifierProvider<PendingShare, IncomingShare?>(PendingShare.new);

/// Whether a shared file at [path] (absolute, links already resolved) may be sent: not when it's
/// in one of [privateDirs] (the app's own storage), unless it sits directly in one of [cacheDirs]
/// (where the share plugin copies shared streams; not in a folder there, such as decrypted files).
bool sharedPathAllowed(String path, {required List<String> privateDirs, required List<String> cacheDirs}) {
  String dir(String d) => d.endsWith('/') ? d : '$d/';
  if (path.split('/').any((part) => part == '..' || part == '.')) return false;
  if (!privateDirs.any((d) => path.startsWith(dir(d)) || path == d)) return true;
  final parent = path.substring(0, path.lastIndexOf('/') + 1);
  return cacheDirs.any((c) => parent == dir(c));
}

/// "2 photos and a video", "a file and a message".
String shareSummary(IncomingShare s) {
  String count(int n, String one) => n == 1 ? 'a $one' : '$n ${one}s';
  final photos = s.media.whereType<PickedPhoto>().length;
  final videos = s.media.whereType<PickedVideo>().length;
  final parts = [
    if (photos > 0) count(photos, 'photo'),
    if (videos > 0) count(videos, 'video'),
    if (s.files.isNotEmpty) count(s.files.length, 'file'),
    if (s.text != null && s.text!.trim().isNotEmpty) 'a message',
  ];
  if (parts.isEmpty) return 'nothing';
  if (parts.length == 1) return parts.single;
  return '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
}
