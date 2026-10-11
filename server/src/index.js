import { createApp } from './app.js';
import { startJanitor } from './janitor.js';

// ============ 生产环境强制配置检查（fail-fast，DIMI_ENV=production 时生效，缺省 development）============
//  ① DIMI_FIELD_KEY 必须显式设置：字段级加密（AES-256-GCM + HMAC 盲索引）密钥，
//     拒绝回退 util.js 内置开发缺省值（DEV_FIELD_KEY），防止生产数据用公开密钥加密；
//  ② DIMI_SMS_DEV=true 与 production 互斥：dev 短信后门会把验证码随响应返回，禁止上生产；
//  ③ 短信供应商必须显式选择（DIMI_SMS_PROVIDER）且所需环境变量齐全：
//     aliyun 需 DIMI_ALIYUN_AK_ID / DIMI_ALIYUN_AK_SECRET / DIMI_SMS_SIGN / DIMI_SMS_TEMPLATE；
//     tencent 仍为 stub（发送必失败），生产选择即拒绝启动；
//  ④ DIMI_STORAGE_PROVIDER=oss 时 OSS 所需环境变量必须齐全（DIMI_OSS_BUCKET / DIMI_OSS_ENDPOINT / 阿里云 AK）；
//  ⑤ ADMIN_TOKEN 未设置：仅告警（app.js 内 /admin-api/* 未配置时已整体禁用，保持现状）。
const DEV_FIELD_KEY = '0'.repeat(63) + '1'; // 与 util.js 内置开发密钥保持一致，仅用于比对拒绝
if ((process.env.DIMI_ENV ?? 'development') === 'production') {
  const fatal = [];
  const fieldKey = process.env.DIMI_FIELD_KEY;
  if (!fieldKey) {
    fatal.push('DIMI_FIELD_KEY 未设置：生产环境必须显式配置字段级加密密钥（64 位 hex），不得使用内置开发缺省值');
  } else if (!/^[0-9a-f]{64}$/i.test(fieldKey)) {
    fatal.push('DIMI_FIELD_KEY 格式非法：须为 64 位 hex（32 字节）');
  } else if (fieldKey.toLowerCase() === DEV_FIELD_KEY) {
    fatal.push('DIMI_FIELD_KEY 不得使用内置开发缺省值，请生成独立密钥：node -e "console.log(require(\'crypto\').randomBytes(32).toString(\'hex\'))"');
  }
  if (process.env.DIMI_SMS_DEV === 'true') {
    fatal.push('DIMI_SMS_DEV=true 与 DIMI_ENV=production 互斥：dev 短信后门（验证码随响应返回）禁止上生产');
  }
  const smsProvider = process.env.DIMI_SMS_PROVIDER;
  if (!smsProvider) {
    fatal.push('DIMI_SMS_PROVIDER 未设置：生产环境必须显式选择短信供应商（aliyun）');
  } else if (smsProvider === 'aliyun') {
    for (const v of ['DIMI_ALIYUN_AK_ID', 'DIMI_ALIYUN_AK_SECRET', 'DIMI_SMS_SIGN', 'DIMI_SMS_TEMPLATE']) {
      if (!process.env[v]) fatal.push(`${v} 未设置：DIMI_SMS_PROVIDER=aliyun 必需`);
    }
  } else if (smsProvider === 'tencent') {
    fatal.push('DIMI_SMS_PROVIDER=tencent 尚未接入（src/providers/sms.js 为 stub，发送必失败），生产环境请使用 aliyun');
  } else {
    fatal.push(`DIMI_SMS_PROVIDER 取值非法：${smsProvider}（仅支持 aliyun / tencent）`);
  }
  if (process.env.DIMI_STORAGE_PROVIDER === 'oss') {
    for (const v of ['DIMI_OSS_BUCKET', 'DIMI_OSS_ENDPOINT', 'DIMI_ALIYUN_AK_ID', 'DIMI_ALIYUN_AK_SECRET']) {
      if (!process.env[v]) fatal.push(`${v} 未设置：DIMI_STORAGE_PROVIDER=oss 必需`);
    }
  }
  if (fatal.length) {
    for (const msg of fatal) console.error(`[FATAL][production] ${msg}`);
    process.exit(1);
  }
}

const { server, db, config } = await createApp();

// 过期数据清理：启动时跑一次 + 每 6 小时一次（timer 已 unref）
startJanitor(db);

const smsMode = config.smsDev
  ? 'dev-only（验证码随响应返回，DIMI_SMS_DEV=true，生产必须关闭）'
  : config.smsProvider
    ? `provider=${config.smsProvider}`
    : '未配置（生产告警：/v1/auth/sms/send 将明确报错「短信服务未配置」）';

server.listen(config.port, () => {
  console.log(`DIMI · 围城 V0.9 server listening on http://0.0.0.0:${config.port}`);
  console.log(`  环境:    ${config.env}`);
  console.log(`  API:     /v1/...  (db: ${config.dbPath})`);
  console.log(`  管理接口: /admin-api/... (X-Admin-Token)${config.adminToken ? '' : ' [未配置 ADMIN_TOKEN，已禁用]'}`);
  console.log(`  静态托管: /h5/  /admin/  /legal/`);
  console.log(`  CORS:    ${config.corsOrigins.length ? config.corsOrigins.join(', ') : '未放开（同源/Native App）'}`);
  console.log(`  SMS 模式: ${smsMode}`);
  console.log(`  媒体存储: ${config.storageProvider === 'oss' ? 'aliyun-oss（绝对公网 URL）' : 'local（server/data/uploads，/media/）'}`);
});
