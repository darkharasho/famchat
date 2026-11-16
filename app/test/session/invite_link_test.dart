import 'package:famchat/session/invite_link.dart';
import 'package:flutter_test/flutter_test.dart';

const t = 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcde';

void main() {
  test('accepts full links, scheme-less links, fragments and bare tokens', () {
    for (final input in [
      'https://famchat.dev/join#$t',
      'famchat.dev/join#$t',
      '#$t',
      '  $t\n',
      '\thttps://famchat.dev/join#$t  \n',
      'http://localhost:8787/join#$t',
    ]) {
      expect(parseInviteToken(input), t, reason: input);
    }
  });

  test('rejects anything that is not a token', () {
    for (final input in [
      '',
      '   ',
      'https://famchat.dev/join',
      'https://famchat.dev/join#',
      'hello world',
      'short',
      '${t.substring(0, 30)}+abc',
      '${t.substring(0, 30)}/abc',
      'a' * 129,
    ]) {
      expect(parseInviteToken(input), isNull, reason: input);
    }
  });

  test('reads the token from an opened /join link', () {
    expect(inviteTokenFromUri(Uri.parse('https://famchat.dev/join#$t')), t);
    expect(inviteTokenFromUri(Uri.parse('https://famchat.dev/chats#$t')), isNull);
    expect(inviteTokenFromUri(Uri.parse('https://famchat.dev/join')), isNull);
    expect(inviteTokenFromUri(Uri.parse('https://famchat.dev/join#nope')), isNull);
  });
}
