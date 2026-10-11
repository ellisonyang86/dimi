import fs from 'node:fs';
import path from 'node:path';

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.webp': 'image/webp',
  '.m4a': 'audio/mp4',
  '.aac': 'audio/aac',
  '.mp4': 'video/mp4',
  '.mov': 'video/quicktime',
  '.woff2': 'font/woff2',
  '.txt': 'text/plain; charset=utf-8',
  '.md': 'text/markdown; charset=utf-8',
  '.map': 'application/json',
};

// 静态托管 ../h5 与 ../admin（目录由并行方提供；不存在时返回 404）
export function serveStatic(ctx, rootDir, urlPath) {
  const rel = decodeURIComponent(urlPath).replace(/^\/+/, '');
  const root = path.normalize(rootDir);
  const filePath = path.normalize(path.join(root, rel));
  if (filePath !== root && !filePath.startsWith(root + path.sep)) {
    ctx.res.writeHead(403).end('forbidden');
    return;
  }
  let target = filePath;
  if (fs.existsSync(target) && fs.statSync(target).isDirectory()) {
    target = path.join(target, 'index.html');
  }
  if (!fs.existsSync(target) || !fs.statSync(target).isFile()) {
    ctx.res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' }).end('not found');
    return;
  }
  const ext = path.extname(target).toLowerCase();
  // 静态资源给合理缓存（API 的 no-store 在 app.js 按 /v1 前缀设置，不在此叠加）：
  // 文档类（html/md/txt）短缓存便于更新生效；图片/字体/脚本等按内容指纹以外场景给 1 天
  const cacheControl = ['.html', '.md', '.txt'].includes(ext)
    ? 'public, max-age=300'
    : 'public, max-age=86400';
  ctx.res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream', 'Cache-Control': cacheControl });
  fs.createReadStream(target).pipe(ctx.res);
}
