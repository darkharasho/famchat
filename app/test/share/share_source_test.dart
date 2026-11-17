import 'package:famchat/share/share_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

void main() {
  test("an invite link opening the app isn't a share (it's handled as an invite)", () async {
    final invite = await sharedToIncoming([SharedMediaFile(path: 'https://famchat.dev/join#${'A' * 32}', type: SharedMediaType.url)]);
    expect(invite.isEmpty, isTrue);
    final link = await sharedToIncoming([SharedMediaFile(path: 'https://example.com/x', type: SharedMediaType.url)]);
    expect(link.text, 'https://example.com/x');
  });
}
