// Photos and videos picked, pasted, dropped or shared into a chat, waiting above the composer to be
// sent with what's typed (the caption). Kept per chat for the app run, so leaving the chat (or the
// wide layout rebuilding the view) doesn't lose them.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'photo_picker.dart';

/// At most this many wait at once; more are dropped (the tray says so).
const maxStagedMedia = 30;

final stagedMediaProvider = NotifierProvider.family<StagedMedia, List<PickedMedia>, String>(StagedMedia.new);

class StagedMedia extends Notifier<List<PickedMedia>> {
  StagedMedia(this.chatId);

  final String chatId;

  @override
  List<PickedMedia> build() => const [];

  /// Adds [items] after those already waiting; returns how many didn't fit.
  int add(List<PickedMedia> items) {
    final room = maxStagedMedia - state.length;
    final taken = items.take(room < 0 ? 0 : room).toList();
    if (taken.isNotEmpty) state = List.unmodifiable([...state, ...taken]);
    return items.length - taken.length;
  }

  void removeAt(int i) {
    if (i < 0 || i >= state.length) return;
    state = List.unmodifiable([...state]..removeAt(i));
  }

  void clear() => state = const [];
}
