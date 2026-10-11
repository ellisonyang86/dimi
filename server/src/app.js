import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { openDb } from './db.js';
import { Router } from './http/router.js';
import { ok, fail, HttpError, E } from './http/respond.js';
import { serveStatic } from './http/static.js';
import { uuid, hashToken, now } from './util.js';
import { q1, run, getUser } from './repo.js';
import { getSmsProvider } from './providers/sms.js';
import { getStorage } from './storage.js';
import { registerAuthRoutes } from './routes/auth.js';
import { registerUserRoutes } from './routes/users.js';
import { registerHometownRoutes } from './routes/hometown.js';
import { registerPrivacyRoutes } from './routes/privacy.js';
import { registerDiscoverRoutes } from './routes/discover.js';
import { registerFriendRoutes } from './routes/friends.js';
import { registerMessageRoutes } from './routes/messages.js';
import { registerClassGroupRoutes } from './routes/classGroups.js';
import { registerHometownGroupRoutes } from './routes/hometownGroups.js';
import { registerHometownPagesRoutes } from './routes/hometownPages.js';
import { registerHometownInteractions } from './routes/hometownInteractions.js';
import { registerMiscRoutes, registerAdminRoutes } from './routes/misc.js';
import { registerGroupRoutes, hasGroupUnlock, needsGroupUnlock } from './routes/groups.js';
import { registerMomentRoutes } from './routes/moments.js';
import { registerCaptchaRoutes } from './routes/captcha.js';
import { registerWalletRoutes } from './routes/wallet.js';

const SRC_DIR = path.dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = path.resolve(SRC_DIR, '..', '..');

export async function createApp(options = {}) {
  const config = {
    env: options.env ?? process.env.DIMI_ENV ?? 'development',
    port: options.port ?? (Number(process.env.PORT) || 8080),
    dbPath: options.dbPath ?? process.env.DIMI_DB_PATH ?? path.join(PROJECT_ROOT, 'server', 'data', 'dimi.db'),
    adminToken: options.adminToken ?? process.env.ADMIN_TOKEN ?? null,
    smsDev: options.smsDev ?? (process.env.DIMI_SMS_DEV === 'true'),
    smsProvider: options.smsProvider ?? process.env.DIMI_SMS_PROVIDER ?? null,
    // 媒体存储：local（默认，/media/ 相对路径）/ oss（阿里云 OSS，绝对公网 URL）
    storageProvider: options.storageProvider ?? process.env.DIMI_STORAGE_PROVIDER ?? 'local',
    imProvider: options.imProvider ?? process.env.DIMI_IM_PROVIDER ?? 'local',
    // CORS 白名单（DIMI_CORS_ORIGINS，逗号分隔）。默认空：不输出 Access-Control-Allow-Origin
    //（h5/admin 均服务端同源托管，Native App 无 Origin，无需放开）
    corsOrigins: options.corsOrigins
      ?? (process.env.DIMI_CORS_ORIGINS || '').split(',').map((s) => s.trim()).filter(Boolean),
    staticRoots: {
      '/h5': path.join(PROJECT_ROOT, 'h5'),
      '/admin': path.join(PROJECT_ROOT, 'admin'),
      '/media': path.join(PROJECT_ROOT, 'server', 'data', 'uploads'),
      '/legal': path.join(PROJECT_ROOT, 'server', 'legal'),
    },
  };
  const db = openDb(config.dbPath);
  const router = new Router();
  // 短信通道分层：dev（DIMI_SMS_DEV=true）/ 供应商（aliyun 已接入；tencent 仍为 stub）/ 未配置（生产 fail-fast，见 index.js）
  const sms = getSmsProvider(config);
  // 媒体存储分层：local（/media/）/ oss（阿里云 OSS，绝对 URL）
  const storage = getStorage(config);
  const deps = { db, config, sms, storage };
  registerAuthRoutes(router, deps);
  registerUserRoutes(router, deps);
  registerHometownRoutes(router, deps);
  registerPrivacyRoutes(router, deps);
  registerDiscoverRoutes(router, deps);
  registerFriendRoutes(router, deps);
  registerGroupRoutes(router, deps);
  registerMomentRoutes(router, deps);
  registerMessageRoutes(router, deps);
  registerClassGroupRoutes(router, deps);
  registerHometownGroupRoutes(router, deps);
  registerHometownPagesRoutes(router, deps);
  registerHometownInteractions(router, deps);
  registerMiscRoutes(router, deps);
  registerCaptchaRoutes(router, deps);
  registerWalletRoutes(router, deps);
  if (config.adminToken) {
    registerAdminRoutes(router, deps);
  } else {
    console.warn('[WARN] ADMIN_TOKEN 未配置，管理接口 /admin-api/* 已整体禁用');
  }
  if (sms.name === 'missing') {
    console.warn('[WARN] 短信服务未配置：DIMI_SMS_DEV!=true 且 DIMI_SMS_PROVIDER 未设置，/v1/auth/sms/send 将明确报错（生产必须配置）');
  } else if (sms.name === 'dev') {
    console.warn('[WARN][dev-only] 短信开发模式：验证码随响应返回（DIMI_SMS_DEV=true），生产环境必须关闭');
  }

  // 请求体上限：默认 1MB；个别路由（如 /v1/misc/upload 视频消息）经路由 opts.bodyLimit 放大
  async function readBody(req, maxBytes = 1024 * 1024) {
    const chunks = [];
    let size = 0;
    for await (const chunk of req) {
      size += chunk.length;
      if (size > maxBytes) throw E.param('请求体过大');
      chunks.push(chunk);
    }
    if (!chunks.length) return {};
    try {
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      if (!body || typeof body !== 'object' || Array.isArray(body)) throw E.param('请求体须为 JSON 对象');
      return body;
    } catch {
      throw E.param('请求体不是合法 JSON');
    }
  }

  function authenticate(ctx) {
    const header = ctx.req.headers.authorization || '';
    const m = /^Bearer\s+(.+)$/.exec(header);
    if (!m) return false;
    const row = q1(db, 'SELECT * FROM tokens WHERE access_token=? AND revoked=0', hashToken(m[1]));
    if (!row || row.access_expires_at <= new Date().toISOString()) return false;
    const user = getUser(db, row.user_id);
    if (!user || user.status !== 1) return false;
    ctx.user = user;
    ctx.tokenRow = row;
    return true;
  }

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    const pathname = url.pathname;
    const ctx = {
      req, res, db, config,
      params: {},
      query: Object.fromEntries(url.searchParams),
      body: null,
      user: null,
      tokenRow: null,
      traceId: uuid(),
    };
    res.setHeader('X-Trace-Id', ctx.traceId);
    // 安全响应头基线（API 与静态统一）；Cache-Control: no-store 仅 /v1 API 响应，
    // 静态资源（/media /h5 /admin /legal）由 serveStatic 给合理缓存
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('Referrer-Policy', 'no-referrer');
    if (pathname.startsWith('/v1/')) res.setHeader('Cache-Control', 'no-store');
    // CORS：默认不输出 Access-Control-Allow-Origin；白名单命中 Origin 才输出并处理预检
    const origin = req.headers.origin;
    const corsAllowed = !!(origin && config.corsOrigins.includes(origin));
    if (corsAllowed) {
      res.setHeader('Access-Control-Allow-Origin', origin);
      res.setHeader('Vary', 'Origin');
    }
    if (req.method === 'OPTIONS') {
      if (corsAllowed && pathname.startsWith('/v1/')) {
        res.writeHead(204, {
          'Access-Control-Allow-Methods': 'GET,POST,PUT,DELETE,OPTIONS',
          'Access-Control-Allow-Headers': 'Content-Type,Authorization,Idempotency-Key,X-Captcha-Token,X-Group-Unlock,X-Admin-Token',
          'Access-Control-Max-Age': '600',
        });
        res.end();
        return;
      }
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('not found');
      return;
    }
    try {
      const matched = router.match(req.method, pathname);
      if (matched) {
        ctx.params = matched.params;
        if (['POST', 'PUT', 'PATCH'].includes(req.method)) ctx.body = await readBody(req, matched.route.opts.bodyLimit);
        if (matched.route.opts.auth && !authenticate(ctx)) throw E.unauth();
        if (matched.route.opts.admin && req.headers['x-admin-token'] !== config.adminToken) throw E.unauth('管理端凭证无效');
        // 通用幂等层：带 Idempotency-Key 的写请求（POST/PUT/DELETE，需登录，键按用户隔离）。
        // 命中 → 重放缓存响应（状态码+body，message 标记 ok(idempotent)）；未命中 → 执行并把 200 响应落库。
        const idemKey = req.headers['idempotency-key'];
        const idemEndpoint = `${req.method} ${pathname}`;
        const idemCapable = !!(idemKey && ctx.user && ['POST', 'PUT', 'DELETE'].includes(req.method));
        if (idemCapable) {
          const hit = q1(
            db,
            'SELECT response_json FROM idempotency_keys WHERE key=? AND user_id=? AND endpoint=?',
            String(idemKey), ctx.user.id, idemEndpoint
          );
          if (hit) {
            const cached = JSON.parse(hit.response_json);
            const body = JSON.stringify({ ...cached.payload, message: 'ok(idempotent)', trace_id: ctx.traceId });
            res.writeHead(cached.httpStatus, { 'Content-Type': 'application/json; charset=utf-8' });
            res.end(body);
            return;
          }
        }
        await matched.route.handler(ctx);
        if (idemCapable && ctx._sent && ctx._sent.httpStatus === 200) {
          run(
            db,
            'INSERT OR IGNORE INTO idempotency_keys(key,user_id,endpoint,response_json,created_at) VALUES(?,?,?,?,?)',
            String(idemKey), ctx.user.id, idemEndpoint, JSON.stringify(ctx._sent), now()
          );
        }
        return;
      }
      // 静态托管 /h5/ 与 /admin/（目录由并行方开发；不存在则 404）
      if (req.method === 'GET') {
        // 家乡页 H5 深链回落：/h5/hometown/<code>（code 为纯段落、不含扩展名的非文件路径）
        // 统一回落到 h5/hometown/index.html，region_code 由页面 JS 从路径自取
        if (/^\/h5\/hometown\/[^/.]+$/.test(pathname)) {
          return serveStatic(ctx, config.staticRoots['/h5'], 'hometown/index.html');
        }
        for (const [prefix, root] of Object.entries(config.staticRoots)) {
          if (pathname === prefix || pathname.startsWith(prefix + '/')) {
            return serveStatic(ctx, root, pathname.slice(prefix.length) || '/');
          }
        }
      }
      throw E.notFound('接口不存在');
    } catch (err) {
      if (res.headersSent) {
        console.error('[ERROR] 响应已发送后出错', err);
        return;
      }
      if (err instanceof HttpError) {
        fail(ctx, err.code, err.message, err.httpStatus, err.data);
      } else {
        console.error('[ERROR]', err);
        fail(ctx, 50000, '系统错误', 500);
      }
    }
  });

  return { server, db, config, router };
}
