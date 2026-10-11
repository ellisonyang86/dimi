import { q, q1, run, audit, getUserByPhone, getUser, getPrivacy } from '../repo.js';
import { ok, E } from '../http/respond.js';
import { randomToken, randomCode, hashPassword, verifyPassword, now, ageOf, maskPhone, hashToken, encryptField, blindIndex } from '../util.js';
import { rules } from '../engine/index.js';
import { hitRate } from '../rate.js';
import { passWithCaptcha } from './captcha.js';

function createTokens(db, userId, deviceInfo = null) {
  const access = randomToken(32);
  const refresh = randomToken(32);
  const nowMs = Date.now();
  // 落库仅存 SHA-256 哈希，原始 token 只随响应下发（防库文件泄露后会话失守）
  run(
    db,
    'INSERT INTO tokens(user_id,access_token,refresh_token,access_expires_at,refresh_expires_at,device_info,created_at) VALUES(?,?,?,?,?,?,?)',
    userId, hashToken(access), hashToken(refresh),
    new Date(nowMs + rules.token.access_ttl_sec * 1000).toISOString(),
    new Date(nowMs + rules.token.refresh_ttl_sec * 1000).toISOString(),
    deviceInfo,
    now()
  );
  return { access_token: access, refresh_token: refresh, expires_in: rules.token.access_ttl_sec };
}

// 设备标识：优先 body.device_info，退化到 User-Agent（截断防注入超长串）
function deviceInfoOf(ctx) {
  const raw = ctx.body?.device_info ?? ctx.req.headers['user-agent'] ?? null;
  return raw ? String(raw).slice(0, 128) : null;
}

export function selfView(db, user) {
  const p = getPrivacy(db, user);
  return {
    user_id: user.id,
    dimi_no: user.dimi_no,
    dimi_no_changed_at: user.dimi_no_changed_at ?? null,
    phone: maskPhone(user.phone),
    nickname: user.nickname,
    real_name: user.real_name ?? null,
    gender: user.gender,
    birth_year: user.birth_year ?? null,
    avatar_url: user.avatar_url ?? null,
    moment_cover: user.moment_cover ?? null,
    signature: user.signature ?? null,
    is_minor: !!user.is_minor,
    credit_score: user.credit_score,
    privacy: {
      friend_verify_required: !!p.friend_verify_required,
      name_mode: p.name_mode,
      add_me_via: p.add_me_via,
      hometown_visibility: p.hometown_visibility,
      current_city_visible: !!p.current_city_visible,
      stranger_moments_10: !!p.stranger_moments_10,
      friend_moments_range: p.friend_moments_range,
      read_receipt: !!p.read_receipt,
      typing_visible: !!p.typing_visible,
      group_temp_chat: !!p.group_temp_chat,
      notify_when_searched: !!p.notify_when_searched,
      personalized_recommend: !!p.personalized_recommend,
      female_protect: !!p.female_protect,
    },
  };
}

const SMS_CODE_MAX_ATTEMPTS = 5; // 每码最多试 5 次，防 6 位码爆破

// 登录失败频控（防凭证爆破）：phone + IP 双维度失败计数，各 10 次/小时，
// 超限抛 42901 need_captcha，复用 hitRate 计数 + passWithCaptcha 滑块放行（重置对应窗口）
const LOGIN_FAIL_LIMIT = 10;

function loginFailOver(db, key) {
  const row = q1(db, 'SELECT count, reset_at FROM rate_counters WHERE key=?', key);
  return !!row && row.reset_at > Date.now() && row.count >= LOGIN_FAIL_LIMIT;
}

function verifySmsCode(db, phone, code) {
  const row = q1(
    db,
    'SELECT * FROM sms_codes WHERE phone_idx=? AND used=0 ORDER BY id DESC LIMIT 1',
    blindIndex('phone', String(phone))
  );
  if (!row) return false;
  if (Date.now() - Date.parse(row.created_at) > 10 * 60 * 1000) return false;
  if (row.attempts >= SMS_CODE_MAX_ATTEMPTS) return false;
  if (row.code !== String(code ?? '')) {
    run(db, 'UPDATE sms_codes SET attempts=attempts+1 WHERE id=?', row.id);
    return false;
  }
  return row;
}

function authPayload(db, user, deviceInfo = null) {
  return { ...createTokens(db, user.id, deviceInfo), need_verify: 0, user: selfView(db, user) };
}

export function registerAuthRoutes(router, { db, config, sms }) {
  router.post('/v1/auth/sms/send', async (ctx) => {
    const { phone, scene = 'register' } = ctx.body || {};
    if (!/^1[3-9]\d{9}$/.test(String(phone ?? ''))) throw E.param('手机号格式不正确');
    const rl = rules.rate_limit;
    // 图形验证（captcha_token）由滑块验证码体系承载（/v1/captcha/slider + /v1/captcha/verify）：
    // 默认不加门槛；触发频控上限时抛 42901 need_captcha，携带有效 captcha_token
    // （query/body/X-Captcha-Token 头）可放行并重置全部超限窗口；dev 模式接受 dev_bypass。
    // 三道闸门串联（间隔/号日限/IP 日限）：先收集全部超限窗口再一次放行，
    // 避免 token 被第一道闸门消费后仍被后续闸门拦截
    const intervalKey = `sms:interval:${phone}`;
    const day = new Date().toISOString().slice(0, 10);
    const dailyKey = `sms:daily:${phone}:${day}`;
    // per-IP 日总量上限（防批量换号轰炸短信通道）：50 条/日/IP
    const ip = ctx.req.socket.remoteAddress || 'unknown';
    const ipDailyKey = `sms:ip_daily:${ip}:${day}`;
    const overKeys = [];
    if (!hitRate(db, intervalKey, 1, rl.sms_interval_sec).allowed) overKeys.push(intervalKey);
    if (!hitRate(db, dailyKey, rl.sms_daily, 86400).allowed) overKeys.push(dailyKey);
    if (!hitRate(db, ipDailyKey, 50, 86400).allowed) overKeys.push(ipDailyKey);
    if (overKeys.length > 0 && !passWithCaptcha(ctx, overKeys)) {
      const msg = overKeys[0] === intervalKey
          ? '发送过于频繁，请完成验证'
          : overKeys[0] === dailyKey
              ? '今日验证码发送次数已达上限，请完成验证'
              : '当前网络环境今日发送次数已达上限，请完成验证';
      throw E.rate(msg, { captcha_required: true, need_captcha: true });
    }
    const code = randomCode();
    run(db, 'INSERT INTO sms_codes(phone,phone_idx,code,scene,created_at) VALUES(?,?,?,?,?)',
      encryptField(phone), blindIndex('phone', String(phone)), code, scene, now());
    // 经 Provider 分层发送：dev 模式随响应返回；未配置供应商时明确报错「短信服务未配置」
    let result;
    try {
      result = await sms.sendSms(phone, code);
    } catch (err) {
      audit(db, { userId: null, event: 'sms_send_failed', input: { phone: maskPhone(String(phone)), provider: sms.name } });
      throw E.system(err.message || '短信服务未配置');
    }
    if (result?.dev) {
      // dev-only：无短信通道，验证码直接随响应返回并在响应头/日志标注
      ctx.res.setHeader('X-Dev-Sms-Code', code);
      return ok(ctx, { sent: true, dev: true, sms_code: code, notice: 'dev-only：验证码随响应返回（响应头 X-Dev-Sms-Code），生产环境必须关闭' });
    }
    return ok(ctx, { sent: true });
  });

  router.post('/v1/auth/register', (ctx) => {
    const { phone, sms_code, nickname, password, gender = 0, birth_year = null, invite_channel = null, agreement_version = null } = ctx.body || {};
    if (!/^1[3-9]\d{9}$/.test(String(phone ?? ''))) throw E.param('手机号格式不正确');
    if (!nickname || [...String(nickname)].length > 32) throw E.param('昵称必填且不超过 32 字');
    if (birth_year == null) throw E.param('请选择出生年份');
    if (![0, 1, 2].includes(Number(gender))) throw E.param('gender 仅支持 0/1/2');
    if (password != null && (typeof password !== 'string' || password.length < 8 || password.length > 64)) throw E.param('密码为 8–64 位');
    const codeRow = verifySmsCode(db, phone, sms_code);
    if (!codeRow) throw E.param('验证码错误或已过期');
    if (getUserByPhone(db, phone)) throw E.param('该手机号已注册');
    if (birth_year != null) {
      // 未成年人边界（V3.1 A3 / 计划书 §4）：<14 不予注册；14–18 暂不放行（V0.9 不做未成年人模式）
      const age = ageOf(birth_year);
      if (age < rules.register.min_age) throw E.param('未满 14 周岁不予注册');
      if (age < rules.register.minor_max_age) throw E.param('本产品暂不支持 14–18 周岁用户注册（未成年人模式尚未开放）');
      if (!/^\d{4}$/.test(String(birth_year))) throw E.param('birth_year 格式不正确');
    }
    const ts = now();
    const info = run(
      db,
      'INSERT INTO users(phone,phone_idx,nickname,gender,birth_year,password_hash,invite_channel,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)',
      encryptField(phone), blindIndex('phone', String(phone)), String(nickname), Number(gender) || 0, birth_year, password ? hashPassword(password) : null, invite_channel, ts, ts
    );
    const userId = Number(info.lastInsertRowid);
    run(db, 'UPDATE users SET dimi_no=? WHERE id=?', 'DM' + String(10000000 + userId), userId);
    run(db, 'INSERT OR IGNORE INTO privacy_settings(user_id) VALUES(?)', userId);
    run(db, 'UPDATE sms_codes SET used=1 WHERE id=?', codeRow.id);
    const user = getUser(db, userId);
    // 协议版本留痕（合规取证）：客户端勾选《用户服务协议》《隐私政策》的版本号，截断 32 字写入审计
    const agreementVersion = agreement_version != null ? String(agreement_version).slice(0, 32) : null;
    audit(db, { userId, event: 'register', input: { phone: maskPhone(phone), invite_channel, agreement_version: agreementVersion } });
    return ok(ctx, authPayload(db, user, deviceInfoOf(ctx)));
  });

  router.post('/v1/auth/login', (ctx) => {
    const { grant_type, phone, sms_code, password } = ctx.body || {};
    if (!['sms', 'password'].includes(grant_type)) throw E.param('grant_type 仅支持 sms / password（V0.9）');
    // 失败计数闸门：任一维度超限需先过滑块（captcha_token 一次性，放行并重置该窗口）
    // phone 维度仅对合法手机号（/^1[3-9]\d{9}$/）计数：畸形入参不生成计数 key，防垃圾 key 撑爆 rate_counters
    const ip = ctx.req.socket.remoteAddress || 'unknown';
    const phoneRaw = String(phone ?? '');
    const failKeyPhone = /^1[3-9]\d{9}$/.test(phoneRaw) ? `login_fail:phone:${phoneRaw}` : null;
    const failKeyIp = `login_fail:ip:${ip}`;
    const overPhone = failKeyPhone ? loginFailOver(db, failKeyPhone) : false;
    const overIp = loginFailOver(db, failKeyIp);
    if (overPhone || overIp) {
      // 一枚 token 同时复位所有超限窗口（避免下一请求再被另一维度拦截）
      const keys = [];
      if (overPhone) keys.push(failKeyPhone);
      if (overIp) keys.push(failKeyIp);
      if (!passWithCaptcha(ctx, keys)) {
        throw E.rate('登录失败次数过多，请完成人机验证', { captcha_required: true, need_captcha: true });
      }
    }
    // 凭证类失败计数 + 审计（账号状态类提示不计入，防误伤正常用户）
    const noteFail = (userId, reason) => {
      if (failKeyPhone) hitRate(db, failKeyPhone, LOGIN_FAIL_LIMIT, 3600);
      hitRate(db, failKeyIp, LOGIN_FAIL_LIMIT, 3600);
      audit(db, { userId, event: 'login_fail', input: { grant_type, reason, ip } });
    };
    const user = getUserByPhone(db, String(phone ?? ''));
    if (!user) {
      noteFail(null, 'user_not_found');
      throw E.param('手机号或凭证错误');
    }
    if (user.status === 9) {
      // 注销冷静期（§5.1.3）：7 天内登录视为撤销注销，逾期拒绝
      const coolingMs = 7 * 24 * 3600 * 1000;
      if (!user.deactivated_at || Date.now() - Date.parse(user.deactivated_at) > coolingMs) {
        throw E.param('账号已注销，无法恢复');
      }
    } else if (user.status !== 1) {
      throw E.param('账号状态异常，请联系客服');
    }
    if (grant_type === 'sms') {
      const codeRow = verifySmsCode(db, phone, sms_code);
      if (!codeRow) {
        noteFail(user.id, 'sms_code_invalid');
        throw E.param('验证码错误或已过期');
      }
      run(db, 'UPDATE sms_codes SET used=1 WHERE id=?', codeRow.id);
    } else {
      if (!verifyPassword(password ?? '', user.password_hash)) {
        noteFail(user.id, 'password_invalid');
        throw E.param('手机号或密码错误');
      }
    }
    if (user.status === 9) {
      run(db, "UPDATE users SET status=1, deactivated_at=NULL, updated_at=? WHERE id=?", now(), user.id);
      audit(db, { userId: user.id, event: 'deactivate_cancel', scene: 'cooling_login' });
    }
    audit(db, { userId: user.id, event: 'login', input: { grant_type } });
    return ok(ctx, authPayload(db, getUser(db, user.id), deviceInfoOf(ctx)));
  });

  // 设置/修改登录密码（契约 /auth/password）：敏感操作须短信二次验证（设计报告 §5.1）；
  // 注册后补设密码与已有密码改密共用本端点（同样需短信验证），新密码 ≥8 位，scrypt 哈希写入
  router.post('/v1/auth/password', { auth: true }, (ctx) => {
    const { new_password, sms_code } = ctx.body || {};
    if (!new_password || String(new_password).length < 8) throw E.param('密码至少 8 位');
    if (String(new_password).length > 64) throw E.param('密码不超过 64 位');
    const codeRow = verifySmsCode(db, ctx.user.phone, sms_code);
    if (!codeRow) throw E.param('验证码错误或已过期');
    run(db, 'UPDATE sms_codes SET used=1 WHERE id=?', codeRow.id);
    const had = !!ctx.user.password_hash;
    run(db, 'UPDATE users SET password_hash=?, updated_at=? WHERE id=?', hashPassword(String(new_password)), now(), ctx.user.id);
    audit(db, { userId: ctx.user.id, event: had ? 'password_change' : 'password_set', input: { via: 'sms_verify' } });
    return ok(ctx, { password_set: true, changed: had });
  });

  // 注销账号（PIPL 注销权，契约 /auth/deactivate）：短信二次验证 + 7 天冷静期
  router.post('/v1/auth/deactivate', { auth: true }, (ctx) => {
    const { sms_code } = ctx.body || {};
    const codeRow = verifySmsCode(db, ctx.user.phone, sms_code);
    if (!codeRow) throw E.param('验证码错误或已过期');
    run(db, 'UPDATE sms_codes SET used=1 WHERE id=?', codeRow.id);
    run(db, "UPDATE users SET status=9, deactivated_at=?, updated_at=? WHERE id=?", now(), now(), ctx.user.id);
    run(db, 'UPDATE tokens SET revoked=1 WHERE user_id=?', ctx.user.id);
    audit(db, { userId: ctx.user.id, event: 'deactivate', output: { cooling_days: 7 } });
    return ok(ctx, { cooling_until: new Date(Date.now() + 7 * 24 * 3600 * 1000).toISOString() });
  });

  router.post('/v1/auth/refresh', (ctx) => {
    const { refresh_token } = ctx.body || {};
    if (!refresh_token) throw E.param('refresh_token 必填');
    const row = q1(db, 'SELECT * FROM tokens WHERE refresh_token=? AND revoked=0', hashToken(refresh_token));
    if (!row || row.refresh_expires_at <= now()) throw E.unauth('refresh_token 无效或已过期');
    const user = getUser(db, row.user_id);
    if (!user || user.status !== 1) throw E.unauth('账号状态异常');
    run(db, 'UPDATE tokens SET revoked=1 WHERE id=?', row.id);
    return ok(ctx, authPayload(db, user, deviceInfoOf(ctx)));
  });

  router.post('/v1/auth/logout', { auth: true }, (ctx) => {
    run(db, 'UPDATE tokens SET revoked=1 WHERE id=?', ctx.tokenRow.id);
    audit(db, { userId: ctx.user.id, event: 'logout' });
    return ok(ctx);
  });

  // 登录设备管理（契约 /auth/devices）：查看当前账号的活跃会话，可下线指定设备
  router.get('/v1/auth/devices', { auth: true }, (ctx) => {
    const rows = q(
      db,
      'SELECT id, device_info, created_at FROM tokens WHERE user_id=? AND revoked=0 ORDER BY id DESC',
      ctx.user.id
    );
    return ok(ctx, {
      items: rows.map((r) => ({
        device_id: r.id,
        device_info: r.device_info ?? '未知设备',
        current: r.id === ctx.tokenRow.id,
        login_at: r.created_at,
      })),
    });
  });

  router.delete('/v1/auth/devices/:device_id', { auth: true }, (ctx) => {
    const id = Number(ctx.params.device_id);
    if (id === ctx.tokenRow.id) throw E.param('不能下线当前设备，请使用退出登录');
    const info = run(db, 'UPDATE tokens SET revoked=1 WHERE id=? AND user_id=?', id, ctx.user.id);
    if (!info.changes) throw E.notFound('设备不存在');
    audit(db, { userId: ctx.user.id, event: 'device_revoke', targetId: id });
    return ok(ctx);
  });
}
