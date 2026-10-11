import 'dart:async';
import 'dart:convert';

import 'package:dimi/api/client.dart';
import 'package:dimi/screens/home.dart';
import 'package:dimi/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

http.Response response(Object data) => http.Response(
    jsonEncode({
      'code': 0,
      'data': data is List ? {'items': data} : data
    }),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'});

DimiApi apiFor(MockClient transport) => DimiApi(ApiClient(
      accessTokenProvider: () => 'test',
      refreshTokenProvider: () => 'refresh',
      onTokenRefreshed: (_, __, ___) async {},
      onAuthExpired: () {},
      httpClient: transport,
    ));

Widget host(DimiApi api, {bool active = true}) => Provider<DimiApi>.value(
      value: api,
      child:
          MaterialApp(theme: buildDimiTheme(), home: HomeTab(active: active)),
    );

void main() {
  testWidgets('慢推荐与计数失败不阻塞教育经历，群失败不误报未设家乡', (tester) async {
    final recommendations = Completer<http.Response>();
    var hometownAvailable = false;
    final api = apiFor(MockClient((request) async {
      switch (request.url.path) {
        case '/v1/discover/recommendations':
          return recommendations.future;
        case '/v1/users/me/educations':
          return response([
            {
              'id': 1,
              'school_id': 1,
              'school_name': '测试小学',
              'enroll_year': 2000
            }
          ]);
        case '/v1/discover/classmates/mine':
          throw http.ClientException('offline');
        case '/v1/hometown-groups/mine':
          if (!hometownAvailable) throw http.ClientException('offline');
          return response(<Object>[]);
        default:
          return response(<Object>[]);
      }
    }));
    await tester.pumpWidget(host(api));
    await tester.pumpAndSettle();
    expect(find.textContaining('测试小学'), findsOneWidget);
    expect(find.text('点击查看同班名录'), findsOneWidget);
    expect(find.text('老乡群暂时未能加载'), findsOneWidget);
    expect(find.textContaining('设置家乡'), findsNothing);

    hometownAvailable = true;
    await tester.tap(find.text('点击重试'));
    await tester.pumpAndSettle();
    expect(find.textContaining('设置家乡'), findsOneWidget);

    recommendations.complete(response({'items': <Object>[]}));
    await tester.pumpAndSettle();
    expect(find.textContaining('测试小学'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切回城外刷新经历且忽略较早的慢响应', (tester) async {
    final oldEducations = Completer<http.Response>();
    var educationCalls = 0;
    final api = apiFor(MockClient((request) async {
      if (request.url.path == '/v1/users/me/educations') {
        if (++educationCalls == 1) return oldEducations.future;
        return response([
          {'school_name': '新学校', 'enroll_year': 2005}
        ]);
      }
      if (request.url.path == '/v1/discover/recommendations') {
        throw http.ClientException('offline');
      }
      return response(<Object>[]);
    }));
    await tester.pumpWidget(host(api));
    await tester.pump();
    await tester.pumpWidget(host(api, active: false));
    await tester.pumpWidget(host(api));
    await tester.pumpAndSettle();
    expect(find.textContaining('新学校'), findsOneWidget);

    oldEducations.complete(response([
      {'school_name': '旧学校', 'enroll_year': 2000}
    ]));
    await tester.pumpAndSettle();
    expect(find.textContaining('新学校'), findsOneWidget);
    expect(find.textContaining('旧学校'), findsNothing);
    expect(educationCalls, 2);
    expect(tester.takeException(), isNull);
  });
}
