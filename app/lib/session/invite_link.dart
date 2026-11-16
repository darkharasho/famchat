// Invite links look like https://famchat.dev/join#<token> (plan 1, POST /api/admin/invites).

final _token = RegExp(r'^[A-Za-z0-9_-]{20,128}$');

/// The invite token from a pasted link, `#token`, or a bare token; null if there isn't one.
/// Accepts any host, since the token is only ever sent to our own API.
String? parseInviteToken(String input) {
  var s = input.trim();
  final hash = s.lastIndexOf('#');
  if (hash >= 0) s = s.substring(hash + 1).trim();
  return _token.hasMatch(s) ? s : null;
}

/// The invite token when the app was opened at `/join#<token>` (web), else null.
String? inviteTokenFromUri(Uri uri) {
  if (!uri.path.endsWith('/join') || uri.fragment.isEmpty) return null;
  return parseInviteToken(uri.fragment);
}
