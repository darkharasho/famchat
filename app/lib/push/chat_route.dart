final _ulid = RegExp(r'^[0-9A-HJKMNP-TV-Z]{26}$');

/// The route for a chat id from outside (a push, a link), or null if it isn't a chat id.
String? chatRoute(String? chatId) => chatId != null && _ulid.hasMatch(chatId) ? '/chats/$chatId' : null;

/// Whether [route] is exactly a chat route (from a notification payload).
bool isChatRoute(String? route) =>
    route != null && route.startsWith('/chats/') && chatRoute(route.substring('/chats/'.length)) == route;
