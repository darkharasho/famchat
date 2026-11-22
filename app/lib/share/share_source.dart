// The phone share sheet (receive_sharing_intent) on Android and iOS; nothing elsewhere.
import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../media/photo_picker.dart';
import '../media/send_media.dart';
import '../session/app_links.dart' show inviteFromLink;
import 'share.dart';
import 'share_paths.dart';

ShareSource platformShareSource() =>
    !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)
        ? const _PhoneShareSource()
        : const NoShareSource();

class _PhoneShareSource implements ShareSource {
  const _PhoneShareSource();

  @override
  Future<IncomingShare?> initial() async {
    try {
      final s = await sharedToIncoming(await ReceiveSharingIntent.instance.getInitialMedia(), allow: await _filter());
      return s.isEmpty ? null : s;
    } catch (_) {
      return null; // no share extension (iOS) or the plugin is missing
    }
  }

  @override
  Stream<IncomingShare> get updates => ReceiveSharingIntent.instance
      .getMediaStream()
      .asyncMap((files) async => sharedToIncoming(files, allow: await _filter()))
      .where((s) => !s.isEmpty)
      .handleError((Object _) {});

  @override
  Future<void> done() async {
    try {
      await ReceiveSharingIntent.instance.reset();
    } catch (_) {
      // nothing to reset
    }
  }
}

/// Which shared paths may be sent; refuses all when the app's directories can't be found.
Future<bool Function(String path)> _filter() async {
  try {
    return await sharedPathFilter();
  } catch (_) {
    return (_) => false;
  }
}

/// The plugin's files as photos, videos, other files and text (links come in as text). Files whose
/// path [allow] refuses (FamChat's own storage) are dropped.
Future<IncomingShare> sharedToIncoming(List<SharedMediaFile> files, {required bool Function(String path) allow}) async {
  final media = <PickedMedia>[];
  final others = <XFile>[];
  final texts = <String>[];
  for (final f in files) {
    final isPath = f.type != SharedMediaType.text && f.type != SharedMediaType.url || await _isFile(f.path);
    if (isPath && !allow(f.path)) continue;
    switch (f.type) {
      // Android calls a shared text file (.txt, .csv) "text" too, with its path.
      case SharedMediaType.text when await _isFile(f.path):
        others.add(XFile(f.path, mimeType: f.mimeType));
      case SharedMediaType.text || SharedMediaType.url:
        final t = f.path.trim();
        // A tapped invite link reaches the app as a "view" too: the invite listener handles it.
        final uri = Uri.tryParse(t);
        if (t.isNotEmpty && (uri == null || inviteFromLink(uri) == null)) texts.add(t);
      case SharedMediaType.image:
        media.add(PickedPhoto(await XFile(f.path).readAsBytes()));
      case SharedMediaType.video:
        media.add(PickedVideo(XFile(f.path, mimeType: f.mimeType)));
      case SharedMediaType.file:
        final sorted = await pickedFromFiles([XFile(f.path, mimeType: f.mimeType)]);
        media.addAll(sorted.media);
        others.addAll(sorted.others);
    }
    final message = f.message;
    if (message != null && message.trim().isNotEmpty && !texts.contains(message.trim())) texts.add(message.trim());
  }
  return IncomingShare(
    media: media.take(maxPhotosPerPick).toList(),
    files: others.take(maxPhotosPerPick).toList(),
    text: texts.isEmpty ? null : texts.join('\n'),
  );
}

/// Whether [path] is a file the plugin copied in (an absolute path that reads), not shared text.
Future<bool> _isFile(String path) async {
  if (!path.startsWith('/') || path.contains('\n')) return false;
  try {
    await XFile(path).length();
    return true;
  } catch (_) {
    return false;
  }
}
