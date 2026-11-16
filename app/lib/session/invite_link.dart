// Invite links look like https://famchat.dev/join#<token> (plan 1, POST /api/admin/invites).
// A reset link (plan 10) adds the one-time claim key seed: /join#<token>.<seed>. The seed stays in
// the fragment, so it never reaches the server; only the token is sent.
import 'dart:typed_data';

import '../crypto/encoding.dart';

final _token = RegExp(r'^[A-Za-z0-9_-]{20,128}(\.[A-Za-z0-9_-]{43})?$');

/// The invite (token, or `token.seed` for a reset link) from a pasted link, `#token`, or a bare
/// token; null if there isn't one. Accepts any host, since the token is only ever sent to our own API.
String? parseInviteToken(String input) {
  var s = input.trim();
  final hash = s.lastIndexOf('#');
  if (hash >= 0) s = s.substring(hash + 1).trim();
  return _token.hasMatch(s) ? s : null;
}

/// The invite when the app was opened at `/join#<token>` (web), else null.
String? inviteTokenFromUri(Uri uri) {
  if (!uri.path.endsWith('/join') || uri.fragment.isEmpty) return null;
  return parseInviteToken(uri.fragment);
}

/// Splits a parsed invite into the token the server knows and, for a reset link, the claim key
/// seed (32 bytes) only the new device uses.
({String token, Uint8List? claimSeed}) splitInvite(String invite) {
  final dot = invite.indexOf('.');
  if (dot < 0) return (token: invite, claimSeed: null);
  return (token: invite.substring(0, dot), claimSeed: b64urlDecode(invite.substring(dot + 1)));
}
