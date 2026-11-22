// Profile photos (docs/protocol.md "Profile photos"): making one from a picked image, setting it,
// and loading anyone's for their avatar (cached locally by key, since a key never changes).
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../chat/providers.dart';
import '../media/media_service.dart' show Offload;
import '../media/photo.dart';
import '../media/providers.dart';

/// Side of the square photo sent, in pixels.
const avatarSide = 512;

/// [original] as a centered square [avatarSide] JPEG: through the photo pipeline first (any format
/// it reads, orientation applied, metadata dropped); the cropping runs through [offload] (a
/// background isolate; inline when null). Throws [UnsupportedImageException].
Future<Uint8List> avatarJpeg(PhotoProcessor processor, Uint8List original, {Offload? offload}) async {
  final photo = await processor.process(original);
  final full = photo.full;
  final square = offload == null ? _square(full) : await offload(() => _square(full));
  if (square == null) throw const UnsupportedImageException();
  return square;
}

Uint8List? _square(Uint8List jpeg) {
  final image = img.decodeImage(jpeg);
  if (image == null) return null;
  final side = image.width < image.height ? image.width : image.height;
  final cropped = img.copyCrop(image,
      x: (image.width - side) ~/ 2, y: (image.height - side) ~/ 2, width: side, height: side);
  final sized = side > avatarSide
      ? img.copyResize(cropped, width: avatarSide, height: avatarSide, interpolation: img.Interpolation.average)
      : cropped;
  return Uint8List.fromList(img.encodeJpg(sized, quality: 85));
}

/// A user's photo [key] (a JPEG), from the local cache or downloaded once.
final avatarBytesProvider = FutureProvider.autoDispose.family<Uint8List?, (String, String)>((ref, id) async {
  final (userId, key) = id;
  final cache = ref.watch(mediaDbProvider);
  final cacheKey = 'avatar|$userId|$key';
  final cached = await cache.cacheGet(cacheKey);
  if (cached != null) return cached;
  final bytes = await ref.watch(chatApiProvider).avatar(userId, key);
  await cache.cachePut(cacheKey, bytes, maxBytes: mediaCacheBytes);
  return bytes;
});

/// [userId]'s photo, or null when they have none (or it hasn't loaded).
final userPhotoProvider = Provider.autoDispose.family<Uint8List?, String>((ref, userId) {
  final key = ref.watch(usersProvider).value?[userId]?.avatarKey;
  if (key == null) return null;
  return ref.watch(avatarBytesProvider((userId, key))).value;
});

/// Group [chatId]'s photo [key] (a JPEG), from the local cache or downloaded once.
final chatAvatarBytesProvider = FutureProvider.autoDispose.family<Uint8List?, (String, String)>((ref, id) async {
  final (chatId, key) = id;
  final cache = ref.watch(mediaDbProvider);
  final cacheKey = chatAvatarCacheKey(chatId, key);
  final cached = await cache.cacheGet(cacheKey);
  if (cached != null) return cached;
  final bytes = await ref.watch(chatApiProvider).chatAvatar(chatId, key);
  await cache.cachePut(cacheKey, bytes, maxBytes: mediaCacheBytes);
  return bytes;
});

/// The cache key a group photo is kept under (so a photo just set shows without a download).
String chatAvatarCacheKey(String chatId, String key) => 'chat-avatar|$chatId|$key';
