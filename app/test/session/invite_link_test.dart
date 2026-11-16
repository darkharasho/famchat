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

  test('a reset link keeps its claim seed, which only the device sees', () {
    final seed = 'A' * 43;
    expect(parseInviteToken('https://famchat.dev/join#$t.$seed'), '$t.$seed');
    final parts = splitInvite('$t.$seed');
    expect(parts.token, t);
    expect(parts.claimSeed, hasLength(32));
    expect(splitInvite(t).claimSeed, isNull);
    expect(parseInviteToken('$t.short'), isNull);
    expect(inviteTokenFromUri(Uri.parse('https://famchat.dev/join#$t.$seed')), '$t.$seed');
  });

  test('a reviewer link is marked, and the marker never reaches the server', () {
    expect(parseInviteToken('https://famchat.dev/join#review.$t'), 'review.$t');
    expect(inviteTokenFromUri(Uri.parse('https://famchat.dev/join#review.$t')), 'review.$t');
    final parts = splitInvite('review.$t');
    expect((parts.token, parts.reviewer, parts.claimSeed), (t, true, null));
    expect(splitInvite(t).reviewer, isFalse);
    expect(isReviewerInvite('review.$t'), isTrue);
    expect(isReviewerInvite(t), isFalse);
    expect(parseInviteToken('review.short'), isNull);
    expect(parseInviteToken('review.$t.${'A' * 43}'), isNull, reason: 'reviewer links carry no claim seed');
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
