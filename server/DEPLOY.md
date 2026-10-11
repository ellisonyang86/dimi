# DIMI·围城 V0.9 后端部署指南

零依赖 Node.js（≥24，`node:sqlite`）单进程服务。本文覆盖生产部署的环境变量、启动方式与上线前检查清单。

## 1. 环境变量全表

| 变量 | 缺省 | 说明 | 生产要求 |
|---|---|---|---|
| `DIMI_ENV` | `development` | 运行环境。`production` 时启用启动强制检查（fail-fast） | 必须设为 `production` |
| `DIMI_FIELD_KEY` | 内置开发密钥 | 字段级加密密钥（AES-256-GCM + HMAC 盲索引），64 位 hex（32 字节）。生成：`node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"` | **必须显式设置且不得用开发缺省值，否则拒绝启动**。一旦启用不可更换（历史密文将无法解密） |
| `DIMI_SMS_DEV` | `false` | dev 短信后门：验证码随响应返回（`X-Dev-Sms-Code` 头） | 必须不为 `true`；与 `production` 同设将拒绝启动 |
| `DIMI_SMS_PROVIDER` | 未设置 | 短信供应商：`aliyun`（已接入，dysmsapi RPC 自签调用）/ `tencent`（仍为 stub，生产选用将拒绝启动）。未配置时 `/v1/auth/sms/send` 明确报错 | **必须显式设置，否则拒绝启动** |
| `DIMI_ALIYUN_AK_ID` / `DIMI_ALIYUN_AK_SECRET` | 未设置 | 阿里云 AccessKey（短信与 OSS 共用） | `DIMI_SMS_PROVIDER=aliyun` 或 `DIMI_STORAGE_PROVIDER=oss` 时**必需，缺失拒绝启动** |
| `DIMI_SMS_SIGN` / `DIMI_SMS_TEMPLATE` | 未设置 | 阿里云短信签名 / 模板 CODE（模板变量 `{"code":"..."}`），需在阿里云控制台过审 | `aliyun` 时**必需，缺失拒绝启动** |
| `DIMI_STORAGE_PROVIDER` | `local` | 媒体存储：`local`（写 `server/data/uploads/`，URL 为 `/media/...` 相对路径）/ `oss`（阿里云 OSS，URL 为绝对公网地址） | 按需 |
| `DIMI_OSS_BUCKET` / `DIMI_OSS_ENDPOINT` | 未设置 | OSS bucket 名 / endpoint（如 `oss-cn-hangzhou.aliyuncs.com`） | `oss` 时**必需，缺失拒绝启动** |
| `DIMI_OSS_PUBLIC_BASE` | `https://<bucket>.<endpoint>` | OSS 公网访问 base（可配 CDN/自定义域名），上传返回与入库的 URL 即 `<base>/<key>` | 一般留空 |
| `ADMIN_TOKEN` | 未设置 | 管理接口 `/admin-api/*` 凭证（`X-Admin-Token` 头）。未设置时管理接口整体禁用（保持现状，仅告警） | 建议设置强随机值 |
| `DIMI_CORS_ORIGINS` | 空（不输出 ACAO） | 跨域白名单，逗号分隔（如 `https://example.com,https://www.example.com`）。h5/admin/legal 均为服务端同源托管、App 为 Native，通常无需设置 | 一般留空 |
| `PORT` | `8080` | 监听端口 | 按需 |
| `DIMI_DB_PATH` | `server/data/dimi.db` | SQLite 库文件路径 | 建议挂持久卷 |
| `DIMI_IM_PROVIDER` | `local` | IM 通道（V0.9 本地极简实现） | 接入腾讯 IM 后切换 |
| `TENCENT_SECRET_ID` / `TENCENT_SECRET_KEY` / `TENCENT_SMS_SDK_APP_ID` / `TENCENT_SMS_SIGN_NAME` / `TENCENT_SMS_TEMPLATE_ID` | 未设置 | 腾讯云短信（`DIMI_SMS_PROVIDER=tencent` 时读取，stub 未接入） | 接入后配置 |

生产 fail-fast 逻辑见 `src/index.js`：① `DIMI_FIELD_KEY` 缺失/非法/等于开发缺省 → 拒绝启动；② `DIMI_SMS_DEV=true` → 拒绝启动；③ `DIMI_SMS_PROVIDER` 未设置/取值非法/选 tencent（stub）→ 拒绝启动，选 `aliyun` 时 `DIMI_ALIYUN_AK_ID`/`DIMI_ALIYUN_AK_SECRET`/`DIMI_SMS_SIGN`/`DIMI_SMS_TEMPLATE` 缺失 → 拒绝启动；④ `DIMI_STORAGE_PROVIDER=oss` 时 `DIMI_OSS_BUCKET`/`DIMI_OSS_ENDPOINT`/阿里云 AK 缺失 → 拒绝启动；⑤ `ADMIN_TOKEN` 未设 → 告警（admin-api 禁用）。

## 2. 生产启动

```bash
cd server
npm run seed   # 首次部署可选（demo 数据，生产请跳过或自行裁剪）

export DIMI_ENV=production
export DIMI_FIELD_KEY=<64 位 hex>
export DIMI_SMS_PROVIDER=aliyun
export DIMI_ALIYUN_AK_ID=<AccessKeyId>
export DIMI_ALIYUN_AK_SECRET=<AccessKeySecret>
export DIMI_SMS_SIGN=<已过审短信签名>
export DIMI_SMS_TEMPLATE=<已过审模板 CODE>
# 可选：媒体走阿里云 OSS（缺省 local，写 server/data/uploads/）
# export DIMI_STORAGE_PROVIDER=oss
# export DIMI_OSS_BUCKET=<bucket>
# export DIMI_OSS_ENDPOINT=oss-cn-hangzhou.aliyuncs.com
# export DIMI_OSS_PUBLIC_BASE=https://cdn.example.com   # 可选，CDN/自定义域名
export ADMIN_TOKEN=<强随机值>
export PORT=8080
npm start                              # 前台；生产建议 systemd / pm2 / docker 托管
```

进程内自动执行：过期数据清理（启动时 + 每 6 小时，见 `src/janitor.js`）。

备份（建议 crontab 每日）：

```bash
# crontab 示例：每天 03:17 备份，VACUUM INTO 一致性快照，保留最近 30 份
17 3 * * * cd /opt/dimi/server && /usr/bin/node scripts/backup.mjs >> data/backups/backup.log 2>&1
```

## 2.1 部署文件（deploy/）

`deploy/` 目录提供生产部署模板，开箱即用（替换占位值后）：

| 文件 | 用途 |
|---|---|
| `deploy/Caddyfile` | Caddy 反向代理，自动 HTTPS；占位域名 `api.dimi.example.com`（替换为真实域名）；`/media/*` 长缓存（immutable）、请求体上限 40MB（上传路由 bodyLimit 28MB，见 `src/routes/misc.js`）、`encode zstd gzip`；安全头由后端输出，不重复 |
| `deploy/dimi.service` | systemd unit：`dimi` 用户运行、`Restart=on-failure`、`EnvironmentFile=/etc/dimi/dimi.env`、`ProtectSystem=strict` 加固 |
| `deploy/dimi-backup.cron` | 每日 03:17 `npm run backup`，日志到 `/var/log/dimi-backup.log` |

安装步骤：

```bash
sudo useradd --system --create-home --shell /usr/sbin/nologin dimi
sudo mkdir -p /opt/dimi && sudo cp -r server /opt/dimi/server && sudo chown -R dimi:dimi /opt/dimi
sudo cp -r h5 admin /opt/dimi/   # /h5/ /admin/ 静态托管根在 PROJECT_ROOT（server 的上一级），不拷会 404
sudo mkdir -p /etc/dimi
# 编辑 /etc/dimi/dimi.env（内容见 dimi.service 注释 / 上文环境变量全表），权限收紧：
sudo vi /etc/dimi/dimi.env && sudo chmod 600 /etc/dimi/dimi.env
sudo cp deploy/dimi.service /etc/systemd/system/dimi.service
sudo systemctl daemon-reload && sudo systemctl enable --now dimi
# HTTPS 反代：
sudo cp deploy/Caddyfile /etc/caddy/Caddyfile   # 先替换真实域名
sudo systemctl reload caddy
# 备份 cron（以 dimi 用户）：crontab -e -u dimi，粘贴 deploy/dimi-backup.cron 中的行
```

## 3. 上线前检查清单

- [ ] `DIMI_FIELD_KEY` 已生成并安全托管（KMS/密钥管理系统），**备份密钥本身**（丢失=历史密文不可解密）
- [ ] `DIMI_SMS_DEV` 确认非 `true`；生产启动日志无 `[FATAL]`
- [ ] 短信供应商已签约：阿里云短信（`DIMI_SMS_PROVIDER=aliyun`，代码已接入 `src/providers/sms.js`），AccessKey 已按最小权限（仅 SMS/OSS）创建，签名 `DIMI_SMS_SIGN` 与模板 `DIMI_SMS_TEMPLATE` 已在控制台过审
- [ ] 媒体存储确认：缺省 local（`server/data/uploads/`，需挂持久卷）；如启用 OSS，bucket 已创建、公共读（或 CDN 回源）已配置，生产启动日志无 `[FATAL]`
- [ ] 备份 cron 已配置并恢复演练过（`npm run backup` → `data/backups/`）
- [ ] ICP 备案 + App 备案（工信部）完成
- [ ] 等级保护三级备案与测评（云平台等保）
- [ ] 法务文档定稿：`server/legal/user-agreement.md`、`server/legal/privacy-policy.md`（当前为 V0.9 草稿，占位信息需补全：运营主体、联系方式、SDK 清单）；App 以 `{host}/legal/user-agreement.md`、`{host}/legal/privacy-policy.md` 拉取
- [ ] 腾讯 IM SDK 接入（替换 `src/im/provider.js` local 实现）
- [ ] 真实滑块验证码供应商（可选；当前为自研滑块，见 `src/routes/captcha.js`）
- [ ] 全链路 TLS（反向代理层终止 HTTPS，配置见 `deploy/Caddyfile`；`X-Frame-Options` 等安全头服务端已内置）
- [ ] 反诈/内容安全运营排班就绪（举报 24h SLA）

## 4. 目录结构

```
server/
├── src/
│   ├── index.js          # 启动入口：生产 fail-fast 检查 + janitor 启动
│   ├── app.js            # 应用装配：config、安全响应头、CORS、幂等层、路由注册
│   ├── db.js             # SQLite schema + 字段加密迁移
│   ├── janitor.js        # 过期数据清理（sms_codes/captcha/idempotency/tokens/group_unlocks）
│   ├── repo.js           # 查询助手、审计写入
│   ├── util.js           # AES-256-GCM 字段加密、HMAC 盲索引、token 哈希
│   ├── rate.js           # 固定窗口频控
│   ├── storage.js        # 媒体存储分层（local /media/ · 阿里云 OSS 绝对 URL）
│   ├── engine/           # 可见性决策引擎（rules.json 配置化）
│   ├── http/             # 零依赖 HTTP 层：router / respond / static
│   ├── providers/        # 短信供应商分层（dev / aliyun 已接入 / tencent stub / missing）
│   ├── im/               # IM 接口层（local 实现，V1 替换云 SDK）
│   └── routes/           # 业务路由（auth/users/discover/friends/messages/...）
├── legal/                # 法务文档（/legal 静态托管，text/markdown）
├── deploy/               # 部署模板：Caddyfile / dimi.service / dimi-backup.cron
├── scripts/
│   ├── backup.mjs        # SQLite 备份（VACUUM INTO，保留 30 份）
│   ├── verify_aliyun.mjs # 阿里云凭证端到端验证（短信 + OSS，真实扣费）
│   └── smoke.mjs 等      # 冒烟脚本
├── test/                 # node --test 端到端/规则测试
└── data/                 # SQLite 库、上传文件（/media）、backups/（均不入库）
```

## 5. 运维要点

- 静态托管：`/h5/`（召集令落地页）、`/admin/`（密度看板）、`/media/`（用户上传）、`/legal/`（法务文档）；`/v1` API 响应带 `Cache-Control: no-store` 与安全头，静态资源带合理缓存
- CORS 默认关闭（同源 + Native App 场景），仅在设置 `DIMI_CORS_ORIGINS` 后对白名单 Origin 输出并处理预检
- 日志关注：`[FATAL]`（启动拒绝）、`[WARN]`（配置缺失）、`[janitor]`（清理行数）、`[DEV-SMS]`（出现即说明 dev 后门泄漏到非开发环境）
