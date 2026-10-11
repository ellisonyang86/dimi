import crypto from 'node:crypto';

export const now = () => new Date().toISOString();
export const uuid = () => crypto.randomUUID();
export const randomToken = (bytes = 32) => crypto.randomBytes(bytes).toString('hex');
export const randomCode = () => String(crypto.randomInt(0, 1000000)).padStart(6, '0');

// ============ 字段级加密（数据安全法 L3：手机号/证件等敏感字段加密存储） ============
// AES-256-GCM 加密 + HMAC-SHA256 盲索引（可检索不可逆）。密钥经环境变量
// DIMI_FIELD_KEY（64 位 hex）注入；缺省时用固定开发密钥并告警（仅限开发环境）。
const DEV_FIELD_KEY = '0'.repeat(63) + '1';
let _fieldKey = null;
let _fieldKeyWarned = false;

export function fieldKey() {
  if (_fieldKey) return _fieldKey;
  const hex = process.env.DIMI_FIELD_KEY || DEV_FIELD_KEY;
  if (!/^[0-9a-f]{64}$/i.test(hex)) throw new Error('DIMI_FIELD_KEY 须为 64 位 hex（32 字节）');
  if (!process.env.DIMI_FIELD_KEY && !_fieldKeyWarned) {
    _fieldKeyWarned = true;
    console.warn('[WARN] DIMI_FIELD_KEY 未设置，使用内置开发密钥（仅限开发环境，生产必须配置独立密钥）');
  }
  _fieldKey = Buffer.from(hex, 'hex');
  return _fieldKey;
}

// 密文格式：enc:v1:<iv b64>:<tag b64>:<cipher b64>
export function encryptField(plain) {
  if (plain == null) return null;
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', fieldKey(), iv);
  const enc = Buffer.concat([cipher.update(String(plain), 'utf8'), cipher.final()]);
  return `enc:v1:${iv.toString('base64')}:${cipher.getAuthTag().toString('base64')}:${enc.toString('base64')}`;
}

export function decryptField(stored) {
  if (stored == null) return null;
  const s = String(stored);
  if (!s.startsWith('enc:v1:')) return s; // 兼容未迁移明文
  const [, , ivB64, tagB64, dataB64] = s.split(':');
  const decipher = crypto.createDecipheriv('aes-256-gcm', fieldKey(), Buffer.from(ivB64, 'base64'));
  decipher.setAuthTag(Buffer.from(tagB64, 'base64'));
  return Buffer.concat([decipher.update(Buffer.from(dataB64, 'base64')), decipher.final()]).toString('utf8');
}

export const isEncrypted = (v) => typeof v === 'string' && v.startsWith('enc:v1:');

// 盲索引：HMAC-SHA256（可精确检索、不可逆推出原文）
export const blindIndex = (kind, value) =>
  crypto.createHmac('sha256', fieldKey()).update(`${kind}:${value}`).digest('hex');

// 令牌落库哈希：库文件泄露时原始 token 不失守
export const hashToken = (token) =>
  crypto.createHash('sha256').update(String(token)).digest('hex');

export function hashPassword(pw) {
  const salt = crypto.randomBytes(16).toString('hex');
  const hash = crypto.scryptSync(String(pw), salt, 32).toString('hex');
  return `scrypt:${salt}:${hash}`;
}

export function verifyPassword(pw, stored) {
  if (!stored) return false;
  const [algo, salt, hash] = String(stored).split(':');
  if (algo !== 'scrypt' || !salt || !hash) return false;
  const calc = crypto.scryptSync(String(pw), salt, 32);
  return crypto.timingSafeEqual(Buffer.from(hash, 'hex'), calc);
}

export function maskPhone(phone) {
  if (!phone || phone.length < 7) return phone ?? null;
  return phone.slice(0, 3) + '****' + phone.slice(-4);
}

// 掩码真名（§5.2.4 T2 档）：三字及以上露首尾「李*娟」，两字露姓「李*」
export function maskName(name) {
  if (!name) return null;
  const chars = [...String(name)];
  if (chars.length <= 1) return chars[0];
  if (chars.length === 2) return chars[0] + '*';
  return chars[0] + '*'.repeat(chars.length - 2) + chars[chars.length - 1];
}

// 掩码姓（§5.2.4 T1 档）：仅露姓「李**」
export function maskSurname(name) {
  if (!name) return null;
  return [...String(name)][0] + '**';
}

const CN_DIGITS = { 零: 0, 一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 };

function cnNumeralsToDigits(s) {
  return s
    .replace(/[零一二两三四五六七八九]?十[零一二两三四五六七八九]?/g, (m) => {
      const [t, o] = m.split('十');
      const tens = t ? CN_DIGITS[t] : 1;
      const ones = o ? CN_DIGITS[o] : 0;
      return String(tens * 10 + ones);
    })
    .replace(/[零一二两三四五六七八九]/g, (c) => String(CN_DIGITS[c]));
}

// 班级名归一化（§6.1.2）：「六年级二班」「6年2班」「六(2)班」→「6-2」；「3班」→「3」
export function normalizeClassName(raw) {
  if (!raw) return '';
  const s = cnNumeralsToDigits(String(raw)).replace(/\s+/g, '');
  const canonical = s.match(/^(\d{1,2})-(\d{1,2})$/);
  if (canonical) return `${Number(canonical[1])}-${Number(canonical[2])}`;
  let m = s.match(/(\d{1,2})年(?:级)?(\d{1,2})班?/);
  if (m) return `${Number(m[1])}-${Number(m[2])}`;
  m = s.match(/(\d{1,2})[（(](\d{1,2})[)）]/);
  if (m) return `${Number(m[1])}-${Number(m[2])}`;
  m = s.match(/(\d{1,2})班/);
  if (m) return String(Number(m[1]));
  m = s.match(/\d+/);
  return m ? String(Number(m[0])) : s;
}

export function ageOf(birthYear, at = new Date()) {
  return at.getFullYear() - Number(birthYear);
}

export function isInt(v) {
  return /^-?\d+$/.test(String(v ?? ''));
}
