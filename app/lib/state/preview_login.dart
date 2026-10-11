/// 本地调试体验账号。正式构建不会启用，也不绕过服务端鉴权。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../api/models.dart';

const bool kDevAutoLogin =
    kDebugMode && bool.fromEnvironment('DEV_AUTO_LOGIN', defaultValue: true);
const String kDevLoginPhone =
    String.fromEnvironment('DEV_LOGIN_PHONE', defaultValue: '13800000001');
const String _devLoginPassword =
    String.fromEnvironment('DEV_LOGIN_PASSWORD', defaultValue: 'demo1234');

/// 使用预置账号的正常密码登录，避免短信发送频控阻止重复验收。
/// 超时后不写会话；只有调用方仍然有效时才保存返回的 token。
Future<AuthToken> authenticatePreview(DimiApi api) async {
  if (!kDevAutoLogin) throw ApiException(40301, '当前版本未开启体验入口');
  final token = await api
      .loginByPassword(phone: kDevLoginPhone, password: _devLoginPassword)
      .timeout(const Duration(seconds: 8));
  if (token.accessToken.isEmpty ||
      token.refreshToken.isEmpty ||
      token.user == null) {
    throw ApiException(50000, '体验账号登录响应不完整');
  }
  return token;
}

String previewLoginMessage(Object error) {
  if (error is TimeoutException ||
      (error is ApiException && error.code == -1)) {
    return '暂时连接不上体验服务。请让手机与电脑连接同一 Wi-Fi，'
        '并在电脑上启动体验服务，再点击下方按钮重试。无需申请账号。';
  }
  return '体验账号暂时不可用，请检查电脑上的体验服务后重试。无需自行注册。';
}
