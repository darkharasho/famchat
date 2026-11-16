// Riverpod wiring for the chat layer: one ChatSync per signed-in device, and streams of the
// local database for the screens.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../session/session_controller.dart';
import 'chat_sync.dart';
import 'db/chat_db.dart';
import 'directory.dart';
import 'http_chat_api.dart';
import 'hub_link.dart';
import 'wire.dart';

final chatDbProvider = Provider<ChatDb>((ref) {
  final db = openChatDb();
  ref.onDispose(db.close);
  return db;
});

final chatApiProvider = Provider<ChatApi>((ref) => HttpChatApi(ref.watch(apiClientProvider)));

final hubLinkProvider = Provider<HubLink>((ref) {
  final api = ref.watch(chatApiProvider);
  return HubConnection(ticket: api.wsTicket, apiBase: ref.watch(apiBaseProvider));
});

/// This device's identity and keys while signed in; rebuilt only when the device changes (not on
/// every refresh-token rotation).
final localIdentityProvider = FutureProvider<LocalIdentity?>((ref) async {
  final ids = ref.watch(sessionProvider.select((s) => s is SignedIn ? (s.session.userId, s.session.deviceId) : null));
  if (ids == null) return null;
  final s = (ref.read(sessionProvider) as SignedIn).session;
  final identity = await s.identityKey();
  return LocalIdentity(
    userId: ids.$1,
    deviceId: ids.$2,
    keys: await s.deviceKeys(),
    identityPub: Uint8List.fromList((await identity.extractPublicKey()).bytes),
  );
});

final myUserIdProvider = Provider<String?>((ref) => ref.watch(localIdentityProvider).value?.userId);

/// The running chat engine, or null when signed out. Signing out wipes the local chat database.
final chatSyncProvider = Provider<ChatSync?>((ref) {
  ref.listen(sessionProvider, (prev, next) {
    if (prev is SignedIn && next is SignedOut) unawaited(ref.read(chatDbProvider).wipe());
  });
  final me = ref.watch(localIdentityProvider).value;
  if (me == null) return null;
  final sync = ChatSync(db: ref.watch(chatDbProvider), api: ref.watch(chatApiProvider), hub: ref.watch(hubLinkProvider), me: me);
  unawaited(sync.start());
  ref.onDispose(() => unawaited(sync.stop()));
  return sync;
});

final chatListProvider = StreamProvider<List<ChatListItem>>((ref) {
  final me = ref.watch(myUserIdProvider);
  if (me == null) return Stream.value(const []);
  return ref.watch(chatDbProvider).watchChatList(me);
});

final chatProvider = StreamProvider.family<ChatRow?, String>((ref, id) => ref.watch(chatDbProvider).watchChat(id));

final messagesProvider =
    StreamProvider.family<List<MessageRow>, String>((ref, id) => ref.watch(chatDbProvider).watchMessages(id));

final membersProvider =
    StreamProvider.family<List<MemberRow>, String>((ref, id) => ref.watch(chatDbProvider).watchMembers(id));

/// Verified account resets of the chat's other members whose banner wasn't dismissed in this chat.
final resetBannersProvider = StreamProvider.family<List<ResetRow>, String>((ref, chatId) {
  final me = ref.watch(myUserIdProvider);
  if (me == null) return Stream.value(const []);
  return ref.watch(chatDbProvider).watchResetBanners(chatId, me);
});

/// Every family member, by id.
final usersProvider = StreamProvider<Map<String, UserRow>>(
  (ref) => ref.watch(chatDbProvider).watchUsers().map((us) => {for (final u in us) u.id: u}),
);

final onlineProvider = StreamProvider<Set<String>>((ref) async* {
  final sync = ref.watch(chatSyncProvider);
  if (sync == null) {
    yield const {};
    return;
  }
  yield sync.onlineNow;
  yield* sync.online;
});

final typingProvider = StreamProvider.family<Set<String>, String>((ref, chatId) async* {
  final sync = ref.watch(chatSyncProvider);
  if (sync == null) {
    yield const {};
    return;
  }
  yield sync.typingNow(chatId);
  yield* sync.typingUsers.map((m) => m[chatId] ?? const {});
});

/// What a chat is called: a group's title, or the other person's name in a 1:1.
String chatTitle(ChatRow chat, List<MemberRow> members, Map<String, UserRow> users, String? me) {
  if (chat.kind == 'group') return chat.title ?? 'Group';
  final other = members.where((m) => m.userId != me).firstOrNull;
  return users[other?.userId]?.name ?? 'Chat';
}

/// For a 1:1, the other member's id.
String? otherMember(ChatRow chat, List<MemberRow> members, String? me) =>
    chat.kind == 'direct' ? members.where((m) => m.userId != me).firstOrNull?.userId : null;
