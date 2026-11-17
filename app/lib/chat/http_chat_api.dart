import '../api/api_client.dart';
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
  }) async {
    final j = (await _call('POST', '/chats', {
      'id': id,
      'kind': kind,
      if (kind == 'direct') 'userId': userIds.single else ...{'title': title, 'userIds': userIds},
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
