/// API 全局配置。
/// 环境分流：通过 --dart-define 注入，缺省为 Android 模拟器访问宿主机：
///   flutter run   --dart-define=API_BASE_URL=http://192.168.1.10:8080/v1
///   flutter build --dart-define=API_BASE_URL=https://api.dimi.example.com/v1
/// - Android 模拟器访问宿主机后端用 http://10.0.2.2:8080/v1（默认）
/// - 真机联调改为局域网 IP，如 http://192.168.1.10:8080/v1
/// - 正式环境 https://api.dimi.example.com/v1（同时移除 Manifest 中 cleartext 配置）
/// 发布构建统一走 tool/build_release.sh（Windows 用 build_release.ps1），
/// 由脚本校验并注入 API_BASE_URL / H5_BASE_URL / ICP_NUMBER。
class ApiConfig {
  ApiConfig._();

  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8080/v1',
  );

  /// 召集令 H5 落地页地址（见 V0.9 计划书 §3.2 主链路最后一环），
  /// 可用 --dart-define=H5_BASE_URL=... 覆盖
  static const String h5BaseUrl = String.fromEnvironment(
    'H5_BASE_URL',
    defaultValue: 'http://10.0.2.2:8080/h5/',
  );

  /// App/ICP 备案号（「关于」页展示），发布构建经
  /// --dart-define=ICP_NUMBER=... 注入，缺省为空不展示
  static const String icpNumber =
      String.fromEnvironment('ICP_NUMBER', defaultValue: '');

  /// 媒体路径转完整 URL：
  /// - 已是 http(s) 绝对地址（如 OSS 直链）原样返回
  /// - 以 / 开头（如 /media/<id>.jpg）拼 baseUrl 去掉尾部 /v1 的 host 部分
  static String resolveMediaUrl(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    if (path.startsWith('/')) {
      final host = baseUrl.endsWith('/v1')
          ? baseUrl.substring(0, baseUrl.length - 3)
          : baseUrl;
      return '$host$path';
    }
    return path;
  }
}
