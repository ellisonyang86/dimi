import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { randomToken } from './util.js';

const SRC_DIR = path.dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = path.resolve(SRC_DIR, '..', '..');

// 媒体存储分层（DIMI_STORAGE_PROVIDER 选择）：
// - LocalStorage（默认 local）：写 server/data/uploads/，URL 为相对路径 /media/<file>（app.js 静态托管）；
// - OssStorage（oss）：PUT 到阿里云 OSS（V1 头部签名），URL 为绝对公网地址
//   （DIMI_OSS_PUBLIC_BASE，缺省 https://<bucket>.<endpoint>）。
// URL 契约：本层是媒体 URL 的唯一构造点；路由层（moments/users）经 isValidMediaUrl
// 校验客户端回传的 URL，存储方案切换不影响上层校验逻辑。
// 媒体文件扩展名：isValidMediaUrl 默认仅认图片（头像/动态/家乡页投稿场景）；
// 聊天语音/视频消息由调用方传入 exts 放行（与 /misc/upload scene 白名单一致：voice=m4a/aac，video=mp4/mov）
const IMAGE_EXTS = ['jpg', 'jpeg', 'png', 'webp'];
const fileNameRe = (exts) => new RegExp(`^[\\w-]+\\.(${exts.join('|')})$`);
const CONTENT_TYPES = { jpg: 'image/jpeg', png: 'image/png', webp: 'image/webp', m4a: 'audio/mp4', aac: 'audio/aac', mp4: 'video/mp4', mov: 'video/quicktime' };

class LocalStorage {
  constructor() {
    this.name = 'local';
    this.dir = path.join(PROJECT_ROOT, 'server', 'data', 'uploads');
  }
  async put({ buf, ext }) {
    fs.mkdirSync(this.dir, { recursive: true });
    const mediaId = randomToken(8);
    const file = `${mediaId}.${ext}`;
    fs.writeFileSync(path.join(this.dir, file), buf);
    return { media_id: mediaId, url: `/media/${file}` };
  }
  isValidMediaUrl(url, exts = IMAGE_EXTS) {
    return new RegExp(`^/media/[\\w-]+\\.(${exts.join('|')})$`).test(String(url ?? ''));
  }
}

// 导出供 scripts/verify_aliyun.mjs 复用（凭证端到端验证），路由层仍经 getStorage 取实例
export class OssStorage {
  constructor() {
    this.name = 'oss';
    this.accessKeyId = process.env.DIMI_ALIYUN_AK_ID ?? null;
    this.accessKeySecret = process.env.DIMI_ALIYUN_AK_SECRET ?? null;
    this.bucket = process.env.DIMI_OSS_BUCKET ?? null;
    this.endpoint = process.env.DIMI_OSS_ENDPOINT ?? null;
    const dft = this.bucket && this.endpoint ? `https://${this.bucket}.${this.endpoint}` : null;
    this.publicBase = (process.env.DIMI_OSS_PUBLIC_BASE ?? dft ?? '').replace(/\/+$/, '') || null;
  }
  missingEnv() {
    const missing = [];
    if (!this.accessKeyId) missing.push('DIMI_ALIYUN_AK_ID');
    if (!this.accessKeySecret) missing.push('DIMI_ALIYUN_AK_SECRET');
    if (!this.bucket) missing.push('DIMI_OSS_BUCKET');
    if (!this.endpoint) missing.push('DIMI_OSS_ENDPOINT');
    return missing;
  }
  // V1 头部签名：StringToSign = VERB + "\n" + Content-MD5 + "\n" + Content-Type + "\n"
  //   + Date + "\n" + CanonicalizedOSSHeaders（无）+ CanonicalizedResource("/bucket/key")
  async put({ buf, ext }) {
    const missing = this.missingEnv();
    if (missing.length) throw new Error(`OSS 存储配置缺失：${missing.join('、')}`);
    const mediaId = randomToken(8);
    const key = `${mediaId}.${ext}`;
    const contentType = CONTENT_TYPES[ext] ?? 'application/octet-stream';
    const date = new Date().toUTCString();
    const stringToSign = `PUT\n\n${contentType}\n${date}\n/${this.bucket}/${key}`;
    const signature = crypto.createHmac('sha1', this.accessKeySecret).update(stringToSign).digest('base64');
    const res = await fetch(`https://${this.bucket}.${this.endpoint}/${key}`, {
      method: 'PUT',
      headers: {
        'Content-Type': contentType,
        Date: date,
        Authorization: `OSS ${this.accessKeyId}:${signature}`,
      },
      body: buf,
      signal: AbortSignal.timeout(15000),
    });
    if (!res.ok) {
      const text = (await res.text().catch(() => '')).slice(0, 200);
      throw new Error(`OSS 上传失败：HTTP ${res.status} ${text}`);
    }
    return { media_id: mediaId, url: `${this.publicBase}/${key}` };
  }
  isValidMediaUrl(url, exts = IMAGE_EXTS) {
    const s = String(url ?? '');
    const prefix = `${this.publicBase}/`;
    return !!this.publicBase && s.startsWith(prefix) && fileNameRe(exts).test(s.slice(prefix.length));
  }
}

export function getStorage(config) {
  if (config.storageProvider === 'oss') return new OssStorage();
  return new LocalStorage();
}
