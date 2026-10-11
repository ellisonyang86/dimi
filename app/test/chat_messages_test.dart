import 'package:dimi/api/models.dart';
import 'package:dimi/state/chat_messages.dart';
import 'package:flutter_test/flutter_test.dart';

Message msg(int id, {bool recalled = false}) => Message(
    msgId: id,
    content: recalled ? '' : '消息$id',
    status: recalled ? 'recalled' : 'delivered');

void main() {
  test('已加载 120 条历史后对账最新 50 条，旧记录保留且撤回同步', () {
    final history = List.generate(120, (i) => msg(i + 1));
    final latest = List.generate(50, (i) => msg(i + 71, recalled: i == 20));
    final result = mergeChatMessages(history, latest.reversed);
    expect(result.length, 120);
    expect(result.first.msgId, 1);
    expect(result.last.msgId, 120);
    expect(result.singleWhere((m) => m.msgId == 91).status, 'recalled');
  });

  test('历史分页与轮询重叠、重复或乱序返回时，消息保持唯一且按时间位点排序', () {
    final result = mergeChatMessages([msg(10), msg(11), msg(12)],
        [msg(13), msg(10), msg(9), msg(8), msg(12), msg(13)]);
    expect(result.map((m) => m.msgId), [8, 9, 10, 11, 12, 13]);
  });

  test('撤回后的旧响应不能把正文重新带回页面', () {
    final result = mergeChatMessages([msg(1, recalled: true)], [msg(1)]);
    expect(result.single.status, 'recalled');
    expect(result.single.content, isEmpty);
  });
}
