import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/screens/chats/chat_list.dart';
import 'package:flutter_test/flutter_test.dart';

MessageRow row(String kind, String sender) => MessageRow(
      id: 'M',
      chatId: 'C',
      seq: 1,
      senderUserId: sender,
      senderDeviceId: 'D',
      kind: kind,
      body: '{}',
      targetId: null,
      envelope: null,
      createdAt: 0,
      state: 'sent',
    );

void main() {
  test('voice messages preview as Voice message', () {
    expect(preview(row('voice', 'bob'), const {}, 'me'), '🎤 Voice message');
    expect(preview(row('voice', 'me'), const {}, 'me'), 'You: 🎤 Voice message');
  });
}
