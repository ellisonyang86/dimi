import 'dart:async';
import 'dart:convert';

import 'package:dimi/api/client.dart';
import 'package:dimi/screens/friends.dart';
import 'package:dimi/state/session.dart';
import 'package:dimi/theme.dart';
import 'package:dimi/widgets/common/dimi_swipe_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

http.Response friendsResponse(bool unlocked) => http.Response(
    jsonEncode({
      'code': 0,
      'data': {
        'items': unlocked
            ? [
                {'user_id': 2, 'nickname': '隐私好友', 'relation': 'friend'}
              ]
            : <Map<String, dynamic>>[],
        'unlocked': unlocked,
        'locked_count': unlocked ? 0 : 1,
        'next_cursor': null
      },
    }),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'});

Widget host(Session session, MockClient transport) => MultiProvider(
      providers: [
        ChangeNotifierProvider<Session>.value(value: session),
        Provider<DimiApi>(
            create: (_) => DimiApi(ApiClient(
                  accessTokenProvider: () => 'test',
                  refreshTokenProvider: () => 'refresh',
                  onTokenRefreshed: (_, __, ___) async {},
                  onAuthExpired: () {},
                  httpClient: transport,
                ))),
      ],
      child: MaterialApp(theme: buildDimiTheme(), home: const FriendsScreen()),
    );

void main() {
  testWidgets('好友左滑备注取消不写入，保存仅提交一次且退场无异常', (tester) async {
    final session = Session();
    addTearDown(session.dispose);
    final writes = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      if (request.method == 'PUT') {
        writes.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response('{"code":0}', 200);
      }
      return friendsResponse(true);
    });
    await tester.pumpWidget(host(session, client));
    await tester.pumpAndSettle();
    for (final save in [false, true]) {
      await tester.drag(find.byType(DimiSwipeRow), const Offset(-300, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('备注'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '测试备注');
      await tester.tap(find.text(save ? '保存' : '取消'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('我的好友'), findsOneWidget);
      expect(writes.length, save ? 1 : 0);
    }
    expect(writes.single['remark_name'], '测试备注');
  });

  testWidgets('旧请求被服务端锁定时不能清除刚更新的解锁凭证', (tester) async {
    final session = Session();
    addTearDown(session.dispose);
    session.setGroupUnlockToken('old');
    final pending = Completer<http.Response>();
    final client = MockClient((request) async =>
        request.headers['X-Group-Unlock'] == 'old'
            ? await pending.future
            : friendsResponse(true));
    await tester.pumpWidget(host(session, client));
    await tester.pump();
    session.setGroupUnlockToken('new');
    pending.complete(friendsResponse(false));
    await tester.pumpAndSettle();
    expect(session.groupUnlockToken, 'new');
    expect(find.text('隐私好友'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    session.clearGroupUnlockToken();
  });

  testWidgets('凭证到期立即移除已加载的隐私好友，刷新失败也不继续暴露', (tester) async {
    final session = Session();
    addTearDown(session.dispose);
    session.setGroupUnlockToken('secret', lifetime: const Duration(seconds: 2));
    final client = MockClient((request) async {
      if (request.headers['X-Group-Unlock'] == 'secret') {
        return friendsResponse(true);
      }
      throw http.ClientException('offline');
    });
    await tester.pumpWidget(host(session, client));
    await tester.pumpAndSettle();
    expect(find.text('隐私好友'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(session.groupUnlockToken, isNull);
    expect(find.text('隐私好友'), findsNothing);
    expect(find.textContaining('网络连接失败'), findsOneWidget);
  });

  testWidgets('锁定前发出的慢请求不能把隐私好友重新填回列表', (tester) async {
    final session = Session();
    addTearDown(session.dispose);
    session.setGroupUnlockToken('secret');
    final pending = Completer<http.Response>();
    final client = MockClient((request) async =>
        request.headers['X-Group-Unlock'] == 'secret'
            ? await pending.future
            : friendsResponse(false));
    await tester.pumpWidget(host(session, client));
    await tester.pump();
    session.clearGroupUnlockToken();
    await tester.pumpAndSettle();
    pending.complete(friendsResponse(true));
    await tester.pumpAndSettle();
    expect(find.text('隐私好友'), findsNothing);
    expect(session.groupUnlockToken, isNull);
    expect(tester.takeException(), isNull);
  });
}
