// Picking photos and videos: image_picker on every platform (its macOS, Windows and Linux
// implementations use file_selector). On iOS/Android/web the picker already scales photos to
// 2048 px and re-encodes HEIC as JPEG.

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import 'photo.dart';
import 'video.dart';

/// At most this many photos and videos per pick; each becomes its own message.
const maxPhotosPerPick = 10;

/// Longest video the camera records.
const maxRecordedVideo = Duration(minutes: 5);

enum PickSource { library, camera, cameraVideo }

/// Something picked to send.
sealed class PickedMedia {
  const PickedMedia();
}

class PickedPhoto extends PickedMedia {
  const PickedPhoto(this.bytes);
  final Uint8List bytes;
}

class PickedVideo extends PickedMedia {
  const PickedVideo(this.file);
  final XFile file;
}

typedef MediaPicker = Future<List<PickedMedia>> Function(PickSource source);

/// Whether this platform offers a camera source.
bool get cameraAvailable =>
    !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

Future<List<PickedMedia>> pickMedia(PickSource source) async {
  final picker = ImagePicker();
  const side = maxPhotoSide * 1.0;
  final files = switch (source) {
    PickSource.camera => [?await picker.pickImage(source: ImageSource.camera, maxWidth: side, maxHeight: side, imageQuality: 92)],
    PickSource.cameraVideo => [?await picker.pickVideo(source: ImageSource.camera, maxDuration: maxRecordedVideo)],
    PickSource.library =>
      await picker.pickMultipleMedia(maxWidth: side, maxHeight: side, imageQuality: 92, limit: maxPhotosPerPick),
  };
  return [
    for (final f in files.take(maxPhotosPerPick))
      if (source == PickSource.cameraVideo || isVideoFile(f)) PickedVideo(f) else PickedPhoto(await f.readAsBytes()),
  ];
}
