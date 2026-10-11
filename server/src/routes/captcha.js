import crypto from 'node:crypto';
import { q1, run } from '../repo.js';
import { ok, E } from '../http/respond.js';
import { randomToken, hashToken, now } from '../util.js';
import { hitRate, resetRate } from '../rate.js';

// 滑块验证码（契约 Captcha 域）：
// GET /v1/captcha/slider 签发挑战（免鉴权，30 次/小时/IP）；缺口坐标 target_x 只落库不下发，
// bg_seed 供客户端画确定性背景；挑战一次性（无论成败标记已用，防暴力试 x）。
// POST /v1/captcha/verify 校验 |x - target_x| <= 3，通过签发一次性 captcha_token（5 分钟有效），
// 供 42901 need_captcha 场景消费（见 discover.js / passWithCaptcha）；
// verify 按 IP 计失败次数（10 次/小时 → 42901），防跨挑战暴力枚举。
const SLIDER = {
  width: 280, height: 160,
  xMin: 40, xMax: 230, // 缺口 x 坐标范围
  yMin: 20, yMax: 140,
  expiresSec: 300,
  tolerance: 3, // |x - target_x| 容差
};
const TOKEN_TTL_SEC = 300; // captcha_token 5 分钟有效

export function registerCaptchaRoutes(router, { db }) {
  router.get('/v1/captcha/slider', (ctx) => {
    const ip = ctx.req.socket.remoteAddress || 'unknown';
    // 签发限流响应不带 captcha_required（验证码接口自身要求验证码是鸡生蛋）
    if (!hitRate(db, `captcha:slider:${ip}:hour`, 30, 3600).allowed) throw E.rate('验证码请求过于频繁，请稍后再试', null);
    const captchaId = randomToken(16);
    const targetX = crypto.randomInt(SLIDER.xMin, SLIDER.xMax + 1);
    const notchY = crypto.randomInt(SLIDER.yMin, SLIDER.yMax + 1);
    const bgSeed = randomToken(8);
    run(
      db,
      'INSERT INTO captcha_challenges(captcha_id,target_x,notch_y,bg_seed,used,expires_at,created_at) VALUES(?,?,?,?,0,?,?)',
      captchaId, targetX, notchY, bgSeed, Date.now() + SLIDER.expiresSec * 1000, now()
    );
    return ok(ctx, {
      captcha_id: captchaId,
      width: SLIDER.width,
      height: SLIDER.height,
      notch_y: notchY,
      bg_seed: bgSeed,
      expires_in: SLIDER.expiresSec,
    });
  });

  router.post('/v1/captcha/verify', (ctx) => {
    const { captcha_id, x } = ctx.body || {};
    const row = captcha_id
      ? q1(db, 'SELECT * FROM captcha_challenges WHERE captcha_id=?', String(captcha_id))
      : null;
    const xNum = Number(x);
    let pass = false;
    if (row && !row.used && row.expires_at > Date.now() && Number.isFinite(xNum)) {
      pass = Math.abs(xNum - row.target_x) <= SLIDER.tolerance;
    }
    // 挑战无论成败都标记已用（一次性，防暴力枚举 x）
    if (row) run(db, 'UPDATE captcha_challenges SET used=1 WHERE captcha_id=?', row.captcha_id);
    if (!pass) {
      // 按 IP 计失败次数：10 次/小时 → 42901（同样不带 captcha_required）
      const ip = ctx.req.socket.remoteAddress || 'unknown';
      if (!hitRate(db, `captcha:verify_fail:${ip}:hour`, 10, 3600).allowed) {
        throw E.rate('滑块验证失败次数过多，请稍后再试', null);
      }
      throw E.param('滑块验证失败，请重新获取验证码');
    }
    const token = randomToken(24);
    run(
      db,
      'INSERT INTO captcha_tokens(token_hash,expires_at,used,created_at) VALUES(?,?,0,?)',
      hashToken(token), Date.now() + TOKEN_TTL_SEC * 1000, now()
    );
    return ok(ctx, { captcha_token: token, expires_in: TOKEN_TTL_SEC });
  });
}

// 消费 captcha_token（真实有效、一次性、用后作废）。
// 开发模式（DIMI_SMS_DEV=true）继续接受 dev_bypass；生产拒绝。
export function consumeCaptchaToken(db, config, token) {
  if (!token) return false;
  if (config.smsDev && token === 'dev_bypass') return true;
  const h = hashToken(String(token));
  const row = q1(db, 'SELECT * FROM captcha_tokens WHERE token_hash=?', h);
  if (!row || row.used || row.expires_at <= Date.now()) return false;
  run(db, 'UPDATE captcha_tokens SET used=1 WHERE token_hash=?', h);
  return true;
}

// 42901 need_captcha 消费点的放行闸门：取 query.captcha_token / body.captcha_token /
// X-Captcha-Token 头，验证通过则消费之；附带 rateKey 时同时重置该计数窗口。
// rateKey 支持数组：一次请求串联多道闸门（间隔/日限/IP 限）时，
// 一枚 token 应同时复位所有超限窗口，否则 token 被第一道消费后后续闸门仍拦截。
export function passWithCaptcha(ctx, rateKey = null) {
  const token = ctx.query.captcha_token ?? ctx.body?.captcha_token ?? ctx.req.headers['x-captcha-token'];
  if (!consumeCaptchaToken(ctx.db, ctx.config, token)) return false;
  if (Array.isArray(rateKey)) {
    for (const k of rateKey) resetRate(ctx.db, k);
  } else if (rateKey) {
    resetRate(ctx.db, rateKey);
  }
  return true;
}
