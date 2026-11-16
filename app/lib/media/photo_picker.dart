// Picking photos: image_picker on every platform (its macOS, Windows and Linux implementations use
// file_selector). On iOS/Android/web the picker already scales to 2048 px and re-encodes HEIC as JPEG.

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import 'photo.dart';

/// At most this many photos per pick; each becomes its own message.
const maxPhotosPerPick = 10;

typedef PhotoPicker = Future<List<Uint8List>> Function({required bool camera});

/// Whether this platform offers a camera source.
bool get cameraAvailable =>
    !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

Future<List<Uint8List>> pickPhotos({required bool camera}) async {
  final picker = ImagePicker();
  const side = maxPhotoSide * 1.0;
  final files = camera
      ? [?await picker.pickImage(source: ImageSource.camera, maxWidth: side, maxHeight: side, imageQuality: 92)]
      : await picker.pickMultiImage(maxWidth: side, maxHeight: side, imageQuality: 92, limit: maxPhotosPerPick);
  return [for (final f in files.take(maxPhotosPerPick)) await f.readAsBytes()];
}
