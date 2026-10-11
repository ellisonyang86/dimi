import '../api/models.dart';

/// 历史分页和轮询共用同一合并规则，撤回是不可逆状态。
List<Message> mergeChatMessages(
    Iterable<Message> current, Iterable<Message> incoming) {
  final byId = {for (final message in current) message.msgId: message};
  for (final message in incoming) {
    if (byId[message.msgId]?.status == 'recalled' &&
        message.status != 'recalled') {
      continue;
    }
    byId[message.msgId] = message;
  }
  return byId.values.toList()..sort((a, b) => a.msgId.compareTo(b.msgId));
}
