import 'dart:convert';

import 'package:dimi/api/client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('刷新时暂时断网不清除登录态', () async {
    var expired = false;
    final client = ApiClient(
        accessTokenProvider: () => 'old',
        refreshTokenProvider: () => 'refresh',
        onTokenRefreshed: (_, __, ___) async {},
        onAuthExpired: () => expired = true,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/auth/refresh')) {
            throw http.ClientException('offline');
          }
          return http.Response('{"code":40101}', 401);
        }));
    await expectLater(client.get('/users/me'),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', -1)));
    expect(expired, isFalse);
  });

  test('刷新重试保留原幂等键且使用新 token', () async {
    var access = 'old';
    final keys = <String?>[];
    final client = ApiClient(
        accessTokenProvider: () => access,
        refreshTokenProvider: () => 'refresh',
        onTokenRefreshed: (a, _, __) async => access = a,
        onAuthExpired: () => fail('不应退出'),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/auth/refresh')) {
            return http.Response(
                jsonEncode({
                  'code': 0,
                  'data': {
                    'access_token': 'new',
                    'refresh_token': 'new-refresh',
                    'expires_in': 3600
                  }
                }),
                200);
          }
          keys.add(request.headers['Idempotency-Key']);
          return http.Response(
              request.headers['Authorization'] == 'Bearer old'
                  ? '{"code":40101}'
                  : '{"code":0,"data":true}',
              200);
        }));
    expect(
        await client.post('/red-packets',
            body: {'total_amount': 10}, idempotent: true),
        isTrue);
    expect(keys.length, 2);
    expect(keys.first, isNotEmpty);
    expect(keys.last, keys.first);
  });

  test('刷新期间切换账号，旧凭证失效响应不能登出新账号', () async {
    var refresh = 'old-refresh';
    var expired = false;
    final client = ApiClient(
      accessTokenProvider: () => 'access',
      refreshTokenProvider: () => refresh,
      onTokenRefreshed: (_, __, ___) async => fail('旧账号不可更新新会话'),
      onAuthExpired: () => expired = true,
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/auth/refresh')) {
          refresh = 'new-account-refresh';
        }
        return http.Response('{"code":40101}', 401);
      }),
    );
    await expectLater(client.get('/users/me'), throwsA(isA<ApiException>()));
    expect(expired, isFalse);
    expect(refresh, 'new-account-refresh');
  });
}
