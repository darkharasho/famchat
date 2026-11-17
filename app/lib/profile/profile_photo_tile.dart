// Settings → Profile photo: choose or take one, or remove it.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../chat/providers.dart';
import '../media/photo.dart';
import '../media/photo_picker.dart';
import '../media/providers.dart';
import '../widgets/common.dart';
import 'avatar.dart';

enum _Action { choose, take, remove }

class ProfilePhotoTile extends ConsumerStatefulWidget {
  const ProfilePhotoTile({super.key});

  @override
  ConsumerState<ProfilePhotoTile> createState() => _ProfilePhotoTileState();
}

class _ProfilePhotoTileState extends ConsumerState<ProfilePhotoTile> {
  bool _busy = false;

  void _snack(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _open(bool hasPhoto) async {
    final action = await showModalBottomSheet<_Action>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose a photo'),
            onTap: () => Navigator.pop(context, _Action.choose),
          ),
          if (cameraAvailable)
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(context, _Action.take),
            ),
          if (hasPhoto)
            ListTile(
              leading: Icon(Icons.delete_outline_rounded, color: Theme.of(context).colorScheme.error),
              title: Text('Remove photo', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () => Navigator.pop(context, _Action.remove),
            ),
        ]),
      ),
    );
    if (action == null || !mounted) return;
    final sync = ref.read(chatSyncProvider);
    if (sync == null) return;
    setState(() => _busy = true);
    try {
      if (action == _Action.remove) {
        await sync.setAvatar(null);
        return;
      }
      final picked = await ref.read(photoPickerProvider)(action == _Action.take ? PickSource.camera : PickSource.library);
      final original = picked.whereType<PickedPhoto>().firstOrNull;
      if (original == null) {
        if (picked.isNotEmpty) _snack('Pick a photo, not a video.');
        return;
      }
      final jpeg = await avatarJpeg(ref.read(photoProcessorProvider), original.bytes, offload: ref.read(mediaOffloadProvider));
      final key = await sync.setAvatar(jpeg);
      // Shown from the cache at once, never downloaded back.
      final me = ref.read(myUserIdProvider);
      if (key != null && me != null) {
        await ref.read(mediaDbProvider).cachePut('avatar|$me|$key', jpeg, maxBytes: mediaCacheBytes);
      }
    } on UnsupportedImageException {
      _snack("That image can't be used.");
    } catch (_) {
      _snack("Couldn't change your profile photo.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(myUserIdProvider);
    final hasPhoto = me != null && ref.watch(usersProvider).value?[me]?.avatarKey != null;
    return ListTile(
      key: const Key('settings-profile-photo'),
      leading: const TileIcon(Icons.account_circle_outlined),
      title: const Text('Profile photo'),
      subtitle: const Text('Shown to your family'),
      trailing: _busy
          ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.chevron_right_rounded),
      onTap: _busy || me == null ? null : () => _open(hasPhoto),
    );
  }
}
