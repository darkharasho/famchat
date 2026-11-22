final _ulid = RegExp(r'^[0-9A-HJKMNP-TV-Z]{26}$');

/// The route for a chat id from outside (a push, a link), or null if it isn't a chat id.
String? chatRoute(String? chatId) => chatId != null && _ulid.hasMatch(chatId) ? '/chats/$chatId' : null;

/// The route that opens [chatId] at message [messageId] (a reminder), or null if either isn't an id.
String? messageRoute(String? chatId, String? messageId) {
  final chat = chatRoute(chatId);
  return chat == null || messageId == null || !_ulid.hasMatch(messageId) ? null : '$chat?m=$messageId';
}

/// Whether [route] is exactly a chat route, or one opening a chat at a message (from a
/// notification payload).
bool isChatRoute(String? route) {
  if (route == null || !route.startsWith('/chats/')) return false;
  final rest = route.substring('/chats/'.length);
  final q = rest.indexOf('?m=');
  return q < 0 ? chatRoute(rest) == route : messageRoute(rest.substring(0, q), rest.substring(q + 3)) == route;
}
