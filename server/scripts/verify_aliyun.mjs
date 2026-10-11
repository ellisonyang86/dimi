// 阿里云真实凭证端到端验证：复用 src/providers/sms.js 与 src/storage.js 的手写签名实现，
// 短信发一条真实验证码 + OSS 上传一个 1x1 PNG 并回读公网 URL，确认签名/配置正确。
// 用法：
//   node scripts/verify_aliyun.mjs --phone 13800000000 [--oss]
// env：DIMI_ALIYUN_AK_ID / DIMI_ALIYUN_AK_SECRET / DIMI_SMS_SIGN / DIMI_SMS_TEMPLATE
//      （--oss 追加 DIMI_OSS_BUCKET / DIMI_OSS_ENDPOINT，可选 DIMI_OSS_PUBLIC_BASE）
import crypto from 'node:crypto';
import { AliyunSmsProvider } from '../src/providers/sms.js';
import { OssStorage } from '../src/storage.js';

const step = (name, ok, extra = '') => console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${extra ? '  → ' + extra : ''}`);

function usage() {
  console.log('用法: node scripts/verify_aliyun.mjs --phone <手机号> [--oss]');
  console.log('  --phone  发送一条真实短信验证码到该手机号（必选）');
  console.log('  --oss    追加验证 OSS 上传 + 公网回读（可选）');
}

// 解析参数
const args = process.argv.slice(2);
let phone = null;
let withOss = false;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--phone') phone = args[++i] ?? null;
  else if (args[i] === '--oss') withOss = true;
  else { console.error(`未知参数: ${args[i]}`); usage(); process.exit(1); }
}
if (!phone || !/^1[3-9]\d{9}$/.test(phone)) {
  if (phone) console.error(`手机号格式不正确: ${phone}`);
  usage();
  process.exit(1);
}

console.log('============================================================');
console.log('  ⚠  本脚本将使用真实阿里云凭证发起真实调用');
console.log('     短信会产生真实扣费，OSS 会产生真实存储/流量（极小）');
console.log('============================================================');

const sms = new AliyunSmsProvider();
const smsMissing = sms.missingEnv();
if (smsMissing.length) {
  step('短信 env 检查', false, `缺少 ${smsMissing.join('、')}`);
  process.exit(1);
}
step('短信 env 检查', true, `sign=${sms.signName} template=${sms.templateCode}`);

const code = String(crypto.randomInt(0, 1000000)).padStart(6, '0');
try {
  const result = await sms.sendSms(phone, code);
  step('短信发送（SendSms）', true, `BizId=${result.biz_id ?? 'N/A'}（验证码已发出，请查收）`);
} catch (err) {
  step('短信发送（SendSms）', false, err.message);
  console.log('排查提示：');
  console.log('  - Code=InvalidAccessKeyId / SignatureDoesNotMatch → 检查 DIMI_ALIYUN_AK_ID / DIMI_ALIYUN_AK_SECRET');
  console.log('  - Code=isv.SIGN_* / TEMPLATE_* → 签名或模板未审核通过（DIMI_SMS_SIGN / DIMI_SMS_TEMPLATE）');
  console.log('  - Code=NoPermission / Forbidden.RAM → 子账号 AK 缺少 AliyunDysmsFullAccess 权限');
  console.log('  - Code=isv.AMOUNT_NOT_ENOUGH → 账户余额不足');
  process.exit(1);
}

if (withOss) {
  const oss = new OssStorage();
  const ossMissing = oss.missingEnv();
  if (ossMissing.length) {
    step('OSS env 检查', false, `缺少 ${ossMissing.join('、')}`);
    process.exit(1);
  }
  step('OSS env 检查', true, `bucket=${oss.bucket} endpoint=${oss.endpoint} publicBase=${oss.publicBase}`);

  // 1x1 透明 PNG（67 字节）
  const PNG_1X1 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
  const buf = Buffer.from(PNG_1X1, 'base64');
  let url;
  try {
    const up = await oss.put({ buf, ext: 'png' });
    url = up.url;
    step('OSS 上传（PUT）', true, url);
  } catch (err) {
    step('OSS 上传（PUT）', false, err.message);
    console.log('排查提示：');
    console.log('  - SignatureDoesNotMatch → 检查 DIMI_ALIYUN_AK_SECRET');
    console.log('  - AccessDenied → 子账号 AK 缺少该 bucket 的 PutObject 权限（AliyunOSSFullAccess 或自定义策略）');
    console.log('  - NoSuchBucket → DIMI_OSS_BUCKET 与 DIMI_OSS_ENDPOINT 区域不匹配');
    process.exit(1);
  }
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(10000) });
    const ct = res.headers.get('content-type') ?? '';
    step('OSS 公网回读（GET）', res.status === 200 && ct.startsWith('image/'), `HTTP ${res.status} Content-Type=${ct}`);
    if (res.status !== 200) {
      console.log('排查提示：');
      console.log('  - 403 AccessDenied → bucket 未开启公共读，或未配置 CDN 回源鉴权（DIMI_OSS_PUBLIC_BASE）');
      console.log('  - Content-Type 不对 → 上传签名实现异常（不应发生，请提 issue）');
      process.exit(1);
    }
  } catch (err) {
    step('OSS 公网回读（GET）', false, err.message);
    process.exit(1);
  }
  const key = url.slice(oss.publicBase.length + 1);
  console.log(`提醒：验证对象 ${key} 仍保留在 bucket 中，请手动删除（控制台 → ${oss.bucket} → 文件管理）。`);
}

console.log('verify-aliyun done');
