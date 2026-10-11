# DIMI · 围城 — Flutter Android APP

「走出通讯录的围城，找回走散的人」。当前版本 `1.0.0+2`，中文界面，Material 3。
视觉统一为黛绿 `#47685C`、米白 `#F5F3EE`、白色表面；纯色、细分割线、无装饰投影。

## 本地运行

本次验证使用 Flutter 3.47.5、OpenJDK 17 和 Android SDK 36。工程使用较新的 Flutter 组件 API，建议使用同版本或兼容版本。

```sh
cd server
npm run seed
# 设置 DIMI_SMS_DEV=true 后 npm start；开发验证码仅用于本地测试。
```

```sh
cd app
flutter pub get
flutter run
# 默认模拟器访问宿主机 http://10.0.2.2:8080/v1。
# 真机与自定义端口必须指定 API/H5 两个地址：
flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8080/v1 --dart-define=H5_BASE_URL=http://192.168.1.10:8080/h5/
```

Debug 默认尝试以种子账号 `13800000001` 自动登录，需后端开发短信模式。
使用 `--dart-define=DEV_AUTO_LOGIN=false` 可关闭。Release 强制关闭自动登录与默认验证码绕过。
正式构建使用 `tool/build_release.ps1` 或 `tool/build_release.sh` 注入 API、H5 与备案信息。

## 关键行为

- 左滑聊天/好友行展开可点击操作按钮，一次仅展开一行。右滑、点击行内容/外部或纵向滚动收起。删除必须确认，接口成功后更新列表。
- 「不显示该聊天」只隐藏本机列表，保留消息；「删除该聊天」清除本人历史可见位点并隐藏，新消息恢复会话，不影响对方、好友或群成员关系。
- 输入弹窗等待退场完成后释放控制器，避免备注、分组及隐私密码等弹窗取消/保存时访问已释放资源。
- token 优先存储于 `flutter_secure_storage`，旧 SharedPreferences token 在读取时迁移；平台存储异常时仍有回退路径。
- 401 刷新单飞去重，重试保留幂等键。暂时断网不会强制登出；明确认证失效会清导航栈回登录。
- 聊天使用 REST 轮询，增量消息去重合并，定期对账保留已翻阅历史；失败文本重试沿用消息标识，避免重复发送。
- 高隐私分组门禁在服务端执行，本地凭证到期或应用进入后台时立即重锁，清除页面中的解锁缓存；用户真名由服务端渐显规则决定。
- 首页经历、群入口、推荐独立加载，切回「城外」刷新；关闭个性化推荐后停止返回推荐，主动检索仍可用。
- 家乡投稿支持分类浏览、投稿、点赞、作者删除及举报。修改教育经历/家乡后会同步移出不再符合资格的群。

## 品牌资源

运行 `python tool/gen_launcher_icons.py`（需 Pillow）可从同一几何定义生成 Android 各尺寸图标、自适应/单色图标、应用内 PNG 和 H5 SVG。

- [预览](assets/brand/brand_preview.png)
- [1024px 图标](assets/brand/dimi_icon_1024.png)
- [可缩放 SVG](assets/brand/dimi_icon.svg)

图形为开放圆环与双人重逢，所有品牌入口共用同一母图。
功能图标沿用 Material 图标，默认轮廓、选中态填充；它们与品牌 logo 分工不同。

## 验证与边界

```sh
flutter analyze --no-pub
flutter test --no-pub
flutter build apk --debug
cd ../server
npm test
npm run test:scenarios
```

详见 [2026-09-26 全量检查报告](../docs/全量检查报告_2026-09-26.md)。报告分别记录已修复项、实际验证结果和未闭环的产品能力。
通过单元测试与构建不代表生产短信、对象存储、离线推送及摄像/录音等设备能力已经完成真机验收。

## 2026-09-27 浅色体验版

最新体验版 1.0.1+4：[图标加深、字号与长文阅读优化](../docs/长文阅读与图标优化_2026-09-27.md)，包含家乡文章评论和觅豆打赏，以及个人主页“写文章”入口。

[页面调整与验证记录](../docs/浅色设计与体验优化_2026-09-27.md) · [真机 APK 安装说明](../dist/浅色版真机安装说明_2026-09-27.md)。支持自定义 DIMI 号，统一找同学/找老乡页面与浅色操作样式。
