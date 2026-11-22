import 'dart:typed_data';

import '../api/api_client.dart';
import '../api/models.dart' show ApiException;
import '../crypto/wrap.dart';
import 'wire.dart';

/// [ChatApi] over the authed [ApiClient] (token refresh and retry-after-401 included).
class HttpChatApi implements ChatApi {
  HttpChatApi(this._api);

  final ApiClient _api;

  Future<Map<String, Object?>> _get(String path, [Map<String, String>? query]) async =>
      await _api.authedJson('GET', path, query: query) ?? (throw const FormatException('empty body'));

  Future<Map<String, Object?>?> _call(String method, String path, [Object? body]) =>
      _api.authedJson(method, path, body: body);

  static List<Map<String, Object?>> _items(Map<String, Object?> j, String k) {
    final v = j[k];
    if (v is! List) throw FormatException('bad $k');
    return v.cast<Map<String, Object?>>();
  }

  static String _seg(String s) => Uri.encodeComponent(s);

  @override
  Future<String> setAvatar(Uint8List jpeg) async {
    final j = await _api.authedUpload('/me/avatar', bytes: jpeg, method: 'PUT', contentType: 'image/jpeg');
    final key = j?['avatarKey'];
    if (key is! String) throw const FormatException('bad avatarKey');
    return key;
  }

  @override
  Future<FetchedPreview?> preview(String url) async {
    try {
      final j = await _api.authedJson('GET', '/preview', query: {'url': url});
      return j == null ? null : FetchedPreview.fromJson(j);
    } on ApiException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  @override
  Future<void> removeAvatar() => _call('DELETE', '/me/avatar');

  @override
  Future<void> setName(String name) => _call('PUT', '/me/name', {'name': name});

  @override
  Future<Uint8List> avatar(String userId, String key) =>
      _api.authedBytes('/users/${_seg(userId)}/avatar', query: {'v': key}, maxBytes: 512 * 1024);

  @override
  Future<List<UserDto>> users() async => [for (final u in _items(await _get('/users'), 'users')) UserDto.fromJson(u)];

  @override
  Future<List<ChatDto>> chats() async => [for (final c in _items(await _get('/chats'), 'chats')) ChatDto.fromJson(c)];

  @override
  Future<ChatDto> chat(String id) async =>
      ChatDto.fromJson((await _get('/chats/${_seg(id)}'))['chat'] as Map<String, Object?>);

  @override
  Future<({ChatDto chat, bool created})> createChat({
    required String id,
    required String kind,
    String? title,
    required List<String> userIds,
    required List<ChatKeyWrap> wraps,
    int? familyId,
  }) async {
    final j = (await _call('POST', '/chats', {
      'id': id,
      'kind': kind,
      if (kind == 'direct') 'userId': userIds.single else ...{'title': title, 'userIds': userIds},
      'familyId': ?familyId,
      'wraps': [for (final w in wraps) w.toJson()],
    }))!;
    return (chat: ChatDto.fromJson(j['chat'] as Map<String, Object?>), created: j['created'] == true);
  }

  @override
  Future<ChatDto> addMembers(String chatId, List<String> userIds, List<ChatKeyWrap> wraps) async {
    final j = (await _call('POST', '/chats/${_seg(chatId)}/members', {
      'userIds': userIds,
      'wraps': [for (final w in wraps) w.toJson()],
    }))!;
    return ChatDto.fromJson(j['chat'] as Map<String, Object?>);
  }

  @override
  Future<void> removeMember(String chatId, String userId) =>
      _call('DELETE', '/chats/${_seg(chatId)}/members/${_seg(userId)}');

  @override
  Future<void> muteChat(String chatId, int? until) => _call('PUT', '/chats/${_seg(chatId)}/mute', {'until': until});

  @override
  Future<void> setStar(String chatId, String messageId, bool starred) =>
      _call(starred ? 'PUT' : 'DELETE', '/chats/${_seg(chatId)}/messages/${_seg(messageId)}/star');

  @override
  Future<List<StarDto>> stars() async => [
        for (final j in (await _call('GET', '/me/stars'))!['stars'] as List)
          StarDto.fromJson(j as Map<String, Object?>),
      ];

  @override
  Future<void> setChatState(String chatId, {bool? pinned, bool? archived, bool? unread}) =>
      _call('PATCH', '/chats/${_seg(chatId)}/me', {
        'pinned': ?pinned,
        'archived': ?archived,
        'unread': ?unread,
      });

  @override
  Future<ChatDto> renameChat(String chatId, String title) async =>
      ChatDto.fromJson((await _call('PATCH', '/chats/${_seg(chatId)}', {'title': title}))!['chat'] as Map<String, Object?>);

  @override
  Future<ChatDto> setDisappearing(String chatId, int? secs) async => ChatDto.fromJson(
      (await _call('PATCH', '/chats/${_seg(chatId)}', {'disappearSecs': secs}))!['chat'] as Map<String, Object?>);

  @override
  Future<void> setReminder(String chatId, String messageId, int at) =>
      _call('PUT', '/chats/${_seg(chatId)}/messages/${_seg(messageId)}/reminder', {'at': at});

  @override
  Future<void> clearReminder(String chatId, String messageId) =>
      _call('DELETE', '/chats/${_seg(chatId)}/messages/${_seg(messageId)}/reminder');

  @override
  Future<List<ReminderDto>> reminders() async =>
      [for (final r in _items(await _get('/me/reminders'), 'reminders')) ReminderDto.fromJson(r)];

  @override
  Future<ScheduledDto> putScheduled(
    String id, {
    required String chatId,
    required Map<String, Object?> envelope,
    required int deliverAt,
    bool silent = false,
    List<String> mentions = const [],
  }) async {
    final j = (await _call('PUT', '/me/scheduled/${_seg(id)}', {
      'chatId': chatId,
      'envelope': envelope,
      'deliverAt': deliverAt,
      if (silent) 'silent': true,
      if (mentions.isNotEmpty) 'mentions': mentions,
    }))!;
    return ScheduledDto.fromJson(j['scheduled'] as Map<String, Object?>);
  }

  @override
  Future<List<ScheduledDto>> scheduled() async =>
      [for (final s in _items(await _get('/me/scheduled'), 'scheduled')) ScheduledDto.fromJson(s)];

  @override
  Future<void> deleteScheduled(String id) => _call('DELETE', '/me/scheduled/${_seg(id)}');

  @override
  Future<void> sendScheduled(String id) => _call('POST', '/me/scheduled/${_seg(id)}/send');

  @override
  Future<({List<GoneDto> gone, int cursor})> gone({required int after, int limit = 500}) async {
    final j = await _get('/me/gone', {'after': '$after', 'limit': '$limit'});
    final cursor = j['cursor'];
    if (cursor is! int) throw const FormatException('bad cursor');
    return (gone: [for (final g in _items(j, 'gone')) GoneDto.fromJson(g)], cursor: cursor);
  }

  @override
  Future<String> setChatAvatar(String chatId, Uint8List jpeg) async {
    final j = await _api.authedUpload('/chats/${_seg(chatId)}/avatar', bytes: jpeg, method: 'PUT', contentType: 'image/jpeg');
    final key = j?['avatarKey'];
    if (key is! String) throw const FormatException('bad avatarKey');
    return key;
  }

  @override
  Future<void> removeChatAvatar(String chatId) => _call('DELETE', '/chats/${_seg(chatId)}/avatar');

  @override
  Future<Uint8List> chatAvatar(String chatId, String key) =>
      _api.authedBytes('/chats/${_seg(chatId)}/avatar', query: {'v': key}, maxBytes: 512 * 1024);

  @override
  Future<void> createEpoch(String chatId, int epoch, List<ChatKeyWrap> wraps) => _call('POST', '/chats/${_seg(chatId)}/epochs', {
        'epoch': epoch,
        'wraps': [for (final w in wraps) w.toJson()],
      });

  @override
  Future<List<MessageDto>> messages(String chatId, {int? after, int? before, int limit = 100}) async {
    final j = await _get('/chats/${_seg(chatId)}/messages', {
      if (after != null) 'after': '$after',
      if (before != null) 'before': '$before',
      'limit': '$limit',
    });
    return [for (final m in _items(j, 'messages')) MessageDto.fromJson(m)];
  }

  @override
  Future<List<ChatKeyWrap>> wraps({String? chatId}) async {
    final j = await _get('/keys/wraps', chatId == null ? null : {'chatId': chatId});
    return [for (final w in _items(j, 'wraps')) ChatKeyWrap.fromJson(w)];
  }

  @override
  Future<int> putWraps(List<ChatKeyWrap> wraps) async {
    final j = (await _call('PUT', '/keys/wraps', {
      'wraps': [for (final w in wraps) w.toJson()],
    }))!;
    return j['added'] as int;
  }

  @override
  Future<List<MissingWrap>> missingWraps() async =>
      [for (final m in _items(await _get('/keys/missing'), 'missing')) MissingWrap.fromJson(m)];

  @override
  Future<String> wsTicket() async => (await _call('POST', '/ws/ticket'))!['ticket'] as String;
}
