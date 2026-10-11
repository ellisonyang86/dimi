import 'dart:convert';
import 'package:dimi/api/client.dart';
import 'package:dimi/api/models.dart';
import 'package:dimi/screens/hometown_content_detail.dart';
import 'package:dimi/screens/moment_compose.dart';
import 'package:dimi/state/session.dart';
import 'package:dimi/theme.dart';
import 'package:dimi/widgets/article_reader.dart';
import 'package:dimi/widgets/gift_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response reply(Object? data, {int code = 0}) => http.Response(
    jsonEncode({
      'code': code,
      'message': code == 0 ? 'ok' : '网络暂时不可用',
      'data': data,
    }),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'});

Widget host(Widget child, Session session, MockClient client,
        {double scale = 1.3}) =>
    MultiProvider(
        providers: [
          ChangeNotifierProvider<Session>.value(value: session),
          Provider<DimiApi>(
              create: (_) => DimiApi(ApiClient(
                  accessTokenProvider: () => 'test',
                  refreshTokenProvider: () => 'refresh',
                  onTokenRefreshed: (_, __, ___) async {},
                  onAuthExpired: () {},
                  httpClient: client))),
        ],
        child: MaterialApp(
            theme: buildDimiTheme(),
            builder: (ctx, child) => MediaQuery(
                data: MediaQuery.of(ctx)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!),
            home: child));

void narrow(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 740);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('长文原生排版保留标题引用与图文顺序，大字小屏无溢出', (tester) async {
    narrow(tester);
    const text =
        '## 故乡的清晨\n\n第一段，**记忆里的味道**。\n\n[图片2]\n\n> 一碗热汤，一份乡愁。\n\n最后一段。';
    await tester.pumpWidget(MaterialApp(
        theme: buildDimiTheme(),
        home: Scaffold(
            body: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
                child: SingleChildScrollView(
                    child: ArticleContent(
                        title: '那条总也走不完的老街',
                        body: text,
                        imageCount: 2,
                        imageBuilder: (i) => SizedBox(
                            key: ValueKey('photo-$i'),
                            height: 120,
                            child: Text('配图 $i'))))))));
    await tester.pumpAndSettle();
    expect(find.text('故乡的清晨'), findsOneWidget);
    expect(find.textContaining('## '), findsNothing);
    expect(find.byKey(const ValueKey('photo-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('photo-1')), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const ValueKey('photo-1'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('photo-0'))).dy));
    expect(removeArticleImage('[图片1]\n[图片2]\n[图片3]', 1), '[图片1]\n\n[图片2]');
    expect(tester.takeException(), isNull);
  });

  testWidgets('家乡评论失败保留草稿，重试沿用幂等键，成功刷新评论', (tester) async {
    narrow(tester);
    final session = Session();
    addTearDown(session.dispose);
    await session.updateCurrentUser(UserSelf(userId: 1, nickname: '读者'));
    final keys = <String?>[];
    var sent = false;
    await tester.pumpWidget(
        host(const HometownContentDetailScreen(contentId: 9), session,
            MockClient((r) async {
      if (r.url.path.endsWith('/comments')) {
        if (r.method == 'POST') {
          keys.add(r.headers['Idempotency-Key']);
          if (keys.length == 1) throw http.ClientException('offline');
          sent = true;
          return reply({'comment_id': 1});
        }
        return reply({
          'items': sent
              ? [
                  {
                    'id': 1,
                    'content': '我也记得这条街',
                    'from_user': {'user_id': 1, 'nickname': '读者'},
                    'can_delete': true
                  }
                ]
              : <Object>[],
          'total_count': sent ? 1 : 0,
          'next_cursor': null
        });
      }
      if (r.url.path.endsWith('/gifts')) {
        return reply({'total_count': 0, 'total_coins': 0, 'items': <Object>[]});
      }
      return reply({
        'content_id': 9,
        'title': '老街的故事',
        'body': '巷口的树还在。',
        'author': {'user_id': 2, 'nickname': '一位名字很长很长的家乡作者'},
        'like_count': 0
      });
    })));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '我也记得这条街');
    await tester.tap(find.widgetWithText(FilledButton, '发送'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '我也记得这条街');
    await tester.tap(find.widgetWithText(FilledButton, '发送'));
    await tester.pumpAndSettle();
    expect(keys.length, 2);
    expect(keys[0], isNotEmpty);
    expect(keys[1], keys[0]);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    await tester.scrollUntilVisible(find.text('评论 1'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('评论 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('打赏先选面额再确认，失败重试不换单据，小屏可操作', (tester) async {
    narrow(tester);
    final session = Session();
    addTearDown(session.dispose);
    final keys = <String?>[];
    var success = 0;
    await tester.pumpWidget(host(
        Scaffold(
            body: Builder(
                builder: (context) => Center(
                    child: TextButton(
                        onPressed: () => showHometownGiftSheet(context, 9,
                            onSuccess: () => success++),
                        child: const Text('打开打赏'))))),
        session, MockClient((r) async {
      if (r.url.path.endsWith('/wallet')) return reply({'balance': 10});
      keys.add(r.headers['Idempotency-Key']);
      expect(jsonDecode(r.body)['coin_amount'], 5);
      if (keys.length == 1) throw http.ClientException('response lost');
      return reply({'order_id': 'H1', 'balance': 5});
    })));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开打赏'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '52 觅豆'))
            .onSelected,
        isNull);
    await tester.tap(find.widgetWithText(ChoiceChip, '5 觅豆'));
    await tester.pumpAndSettle();
    expect(keys, isEmpty);
    await tester.tap(find.text('确认打赏 5 觅豆'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试确认'));
    await tester.pumpAndSettle();
    expect(keys.length, 2);
    expect(keys[1], keys[0]);
    expect(success, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('个人长文支持预览并按文章类型发布真实标题和正文', (tester) async {
    narrow(tester);
    final session = Session();
    addTearDown(session.dispose);
    Map<String, dynamic>? posted;
    await tester.pumpWidget(
        host(const MomentComposeScreen(articleMode: true), session,
            MockClient((r) async {
      posted = jsonDecode(r.body) as Map<String, dynamic>;
      return reply({'moment_id': 9, ...posted!});
    })));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '回家的路');
    await tester.enterText(find.byType(TextField).at(1), '## 清晨\n\n家门口的树。');
    await tester.ensureVisible(find.text('预览'));
    await tester.tap(find.text('预览'));
    await tester.pumpAndSettle();
    expect(find.text('阅读预览'), findsOneWidget);
    expect(find.text('回家的路'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '发布'));
    await tester.pumpAndSettle();
    expect(posted?['content_type'], 'article');
    expect(posted?['content'], '# 回家的路\n\n## 清晨\n\n家门口的树。');
    expect(tester.takeException(), isNull);
  });
}
