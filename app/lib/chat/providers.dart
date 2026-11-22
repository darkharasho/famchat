// Riverpod wiring for the chat layer: one ChatSync per signed-in device, and streams of the
// local database for the screens.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../session/session_controller.dart';
import 'chat_sync.dart';
import 'db/chat_db.dart';
import 'directory.dart';
import 'http_chat_api.dart';
import 'hub_link.dart';
import 'polls.dart';
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
  final sync = ChatSync(
    db: ref.watch(chatDbProvider),
    api: ref.watch(chatApiProvider),
    hub: ref.watch(hubLinkProvider),
    me: me,
    // stop() runs unawaited on dispose, so an event already in flight may land after it.
    onFamiliesChanged: () {
      if (ref.mounted) ref.invalidate(familiesProvider);
    },
  );
  unawaited(sync.start());
  ref.onDispose(() => unawaited(sync.stop()));
  return sync;
});

/// Disappearing messages: timers may sleep with the app, so expired ones are looked for again each
/// time it comes back to the foreground (ChatsShell watches this).
final disappearSweepProvider = Provider<void>((ref) {
  final sync = ref.watch(chatSyncProvider);
  if (sync == null) return;
  final lifecycle = AppLifecycleListener(onResume: sync.sweepSoon);
  ref.onDispose(lifecycle.dispose);
});

/// This user's families (`GET /families`), any status; empty when signed out. A `family` event
/// invalidates it.
final familiesProvider = AsyncNotifierProvider<Families, List<Family>>(Families.new);

class Families extends AsyncNotifier<List<Family>> {
  List<Family>? _seen;
  final _approved = StreamController<Family>.broadcast();

  /// A family I asked for that the operator has approved since the last fetch.
  Stream<Family> get approvals => _approved.stream;

  @override
  Future<List<Family>> build() async {
    if (ref.watch(myUserIdProvider) == null) {
      // A new session starts fresh, not diffed against the last one.
      _seen = null;
      return const [];
    }
    final now = await ref.watch(apiClientProvider).families();
    final before = _seen;
    _seen = now;
    if (before != null && ref.mounted) {
      for (final f in now) {
        final was = before.where((p) => p.id == f.id).firstOrNull;
        if (f.owner && f.status == 'approved' && was != null && was.status == 'pending') _approved.add(f);
      }
    }
    return now;
  }

  /// Fetches the list again (after creating, joining, renaming or leaving a family).
  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

/// Families of mine the operator approved (seen on a refresh); the shell shows a note for each.
final familyApprovalsProvider = StreamProvider<Family>((ref) => ref.watch(familiesProvider.notifier).approvals);

/// The approved families: the ones a chat or an invite can be for (pickers).
final myFamiliesProvider = FutureProvider<List<Family>>(
  (ref) async => [for (final f in await ref.watch(familiesProvider.future)) if (f.status == 'approved') f],
);

final chatListProvider = StreamProvider<List<ChatListItem>>((ref) {
  final me = ref.watch(myUserIdProvider);
  if (me == null) return Stream.value(const []);
  return ref.watch(chatDbProvider).watchChatList(me);
});

final chatProvider = StreamProvider.family<ChatRow?, String>((ref, id) => ref.watch(chatDbProvider).watchChat(id));

/// My starred messages in a chat (or every chat, for null), newest star first.
final starsProvider =
    StreamProvider.family<List<StarRow>, String?>((ref, chatId) => ref.watch(chatDbProvider).watchStars(chatId: chatId));

/// My starred messages that are on this device (in a chat, or all for null), newest star first.
final starredMessagesProvider = StreamProvider.family<List<MessageRow>, String?>(
    (ref, chatId) => ref.watch(chatDbProvider).watchStarredMessages(chatId: chatId));

/// My scheduled messages in a chat, soonest first (docs/protocol.md "Scheduled messages").
final scheduledProvider =
    StreamProvider.family<List<ScheduledRow>, String>((ref, chatId) => ref.watch(chatDbProvider).watchScheduled(chatId));

/// My reminders in a chat: message id → when (Unix ms). Only I see them.
final remindersProvider =
    StreamProvider.family<Map<String, int>, String>((ref, chatId) => ref.watch(chatDbProvider).watchReminders(chatId));

final messagesProvider =
    StreamProvider.family<List<MessageRow>, String>((ref, id) => ref.watch(chatDbProvider).watchMessages(id));

/// A chat's polls (poll id → state), folded from its messages; empty while they load.
final pollsProvider = Provider.family<Map<String, PollState>, String>((ref, chatId) {
  final rows = ref.watch(messagesProvider(chatId)).value;
  return rows == null ? const {} : pollStates(rows);
});

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
  // The other person deleted their account (and so left the chat).
  if (other == null && members.isNotEmpty) return 'Deleted user';
  return users[other?.userId]?.name ?? 'Chat';
}

/// How many are in a group: "Only you" for a chat with just yourself (a note to self).
String membersLabel(int n) => n <= 1 ? 'Only you' : '$n members';

/// For a 1:1, the other member's id.
String? otherMember(ChatRow chat, List<MemberRow> members, String? me) =>
    chat.kind == 'direct' ? members.where((m) => m.userId != me).firstOrNull?.userId : null;

/// A chat's title as the chat list shows it, or null while it loads.
final chatTitleProvider = Provider.family<String?, String>((ref, chatId) {
  final chat = ref.watch(chatProvider(chatId)).value;
  if (chat == null) return null;
  return chatTitle(
    chat,
    ref.watch(membersProvider(chatId)).value ?? const [],
    ref.watch(usersProvider).value ?? const {},
    ref.watch(myUserIdProvider),
  );
});
