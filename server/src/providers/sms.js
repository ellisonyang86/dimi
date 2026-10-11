import crypto from 'node:crypto';
import { maskPhone } from '../util.js';

// 短信通道生产化分层：
// - DevProvider（DIMI_SMS_DEV=true）：无真实通道，验证码随响应返回（现状行为，仅限开发）；
// - 生产模式（未设 DIMI_SMS_DEV）且未配置供应商：明确抛错「短信服务未配置」，启动时告警；
// - AliyunSmsProvider：阿里云 dysmsapi RPC 自签调用（零依赖），env 见下；
// - TencentSmsProvider 预留 stub：读环境变量，sendSms 抛「未接入」+ TODO（接入后替换实现）。
// auth.js 统一经 getSmsProvider(config).sendSms(phone, code) 发送。

class DevSmsProvider {
  constructor() { this.name = 'dev'; }
  // dev-only：验证码直接随响应返回（auth.js 依据 dev:true 附带 sms_code 与 X-Dev-Sms-Code 头）
  async sendSms(phone, code) {
    console.warn(`[DEV-SMS][dev-only] phone=${maskPhone(String(phone))} code=${code}`);
    return { dev: true };
  }
}

class MissingSmsProvider {
  constructor() { this.name = 'missing'; }
  async sendSms() {
    throw new Error('短信服务未配置：请设置 DIMI_SMS_DEV=true（开发）或配置 DIMI_SMS_PROVIDER（aliyun/tencent）');
  }
}

// 阿里云 POP 签名 percentEncode：RFC3986（~ 不转义），+ → %20，* → %2A，%7E → ~
function percentEncode(str) {
  return encodeURIComponent(String(str))
    .replace(/\+/g, '%20')
    .replace(/\*/g, '%2A')
    .replace(/%7E/g, '~');
}

// 导出供 scripts/verify_aliyun.mjs 复用（凭证端到端验证），路由层仍经 getSmsProvider 取实例
export class AliyunSmsProvider {
  constructor() {
    this.name = 'aliyun';
    this.accessKeyId = process.env.DIMI_ALIYUN_AK_ID ?? null;
    this.accessKeySecret = process.env.DIMI_ALIYUN_AK_SECRET ?? null;
    this.signName = process.env.DIMI_SMS_SIGN ?? null;
    this.templateCode = process.env.DIMI_SMS_TEMPLATE ?? null;
  }
  missingEnv() {
    const missing = [];
    if (!this.accessKeyId) missing.push('DIMI_ALIYUN_AK_ID');
    if (!this.accessKeySecret) missing.push('DIMI_ALIYUN_AK_SECRET');
    if (!this.signName) missing.push('DIMI_SMS_SIGN');
    if (!this.templateCode) missing.push('DIMI_SMS_TEMPLATE');
    return missing;
  }
  // dysmsapi RPC（SignatureVersion 1.0，HMAC-SHA1）：GET https://dysmsapi.aliyuncs.com/?Action=SendSms&...
  // StringToSign = HTTPMethod + "&" + percentEncode("/") + "&" + percentEncode(sortedQueryString)
  // Signature = Base64(HMAC-SHA1(secret + "&", StringToSign))
  async sendSms(phone, code) {
    const missing = this.missingEnv();
    if (missing.length) throw new Error(`阿里云短信配置缺失：${missing.join('、')}`);
    const params = {
      AccessKeyId: this.accessKeyId,
      Action: 'SendSms',
      Format: 'JSON',
      PhoneNumbers: String(phone),
      RegionId: 'cn-hangzhou',
      SignName: this.signName,
      SignatureMethod: 'HMAC-SHA1',
      SignatureNonce: crypto.randomUUID(),
      SignatureVersion: '1.0',
      TemplateCode: this.templateCode,
      TemplateParam: JSON.stringify({ code: String(code) }),
      Timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
      Version: '2017-05-25',
    };
    const sortedQuery = Object.keys(params).sort()
      .map((k) => `${percentEncode(k)}=${percentEncode(params[k])}`)
      .join('&');
    const stringToSign = `GET&${percentEncode('/')}&${percentEncode(sortedQuery)}`;
    const signature = crypto
      .createHmac('sha1', this.accessKeySecret + '&')
      .update(stringToSign)
      .digest('base64');
    const url = `https://dysmsapi.aliyuncs.com/?Signature=${percentEncode(signature)}&${sortedQuery}`;
    const res = await fetch(url, { signal: AbortSignal.timeout(10000) });
    const body = await res.json().catch(() => null);
    // 不记录验证码与密钥：错误信息仅携带阿里返回的 Code/Message
    if (!res.ok || body?.Code !== 'OK') {
      throw new Error(`阿里云短信发送失败：HTTP ${res.status} Code=${body?.Code ?? 'N/A'} Message=${body?.Message ?? '无响应体'}`);
    }
    return { sent: true, biz_id: body?.BizId ?? null };
  }
}

class TencentSmsProvider {
  constructor() {
    this.name = 'tencent';
    this.secretId = process.env.TENCENT_SECRET_ID ?? null;
    this.secretKey = process.env.TENCENT_SECRET_KEY ?? null;
    this.sdkAppId = process.env.TENCENT_SMS_SDK_APP_ID ?? null;
    this.signName = process.env.TENCENT_SMS_SIGN_NAME ?? null;
    this.templateId = process.env.TENCENT_SMS_TEMPLATE_ID ?? null;
  }
  // TODO: 接入腾讯云短信（tc3-hmac-sha256 自签），模板变量 {1}=code
  async sendSms() {
    throw new Error('短信供应商 tencent 尚未接入（TODO：实现腾讯云 SMS 发送）');
  }
}

export function getSmsProvider(config) {
  if (config.smsDev) return new DevSmsProvider();
  switch (config.smsProvider) {
    case 'aliyun': return new AliyunSmsProvider();
    case 'tencent': return new TencentSmsProvider();
    default: return new MissingSmsProvider();
  }
}
