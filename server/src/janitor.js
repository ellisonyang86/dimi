import { run, q } from './repo.js';
import { expirePacket } from './routes/wallet.js';

// 过期数据清理任务：启动时执行一次 + 每 6 小时一次（setInterval.unref，不阻止进程退出）。
// 清理对象与口径：
//  - sms_codes：已用或超过验证码有效期（10 分钟，与 auth.js verifySmsCode 一致）；
//  - captcha_challenges / captcha_tokens：已用或过期（expires_at 为毫秒时间戳）；
//  - idempotency_keys：创建满 7 天（幂等重放窗口之外）；
//  - tokens：已撤销或 refresh 过期（access/refresh 均失效的行无保留价值）；
//  - group_unlocks：过期解锁凭证（主动锁定/重新解锁时已即时删除，这里兜底过期行）；
//  - hometown_views：浏览去重位点超 48h（去重窗口 24h，留一倍余量兜底，见 hometownPages.js）。
// 另：红包 24h 未领完退回（《虚拟币与打赏体系设计_V1》§6.2）——active 且过 expire_at 的红包
// 在此批量结算（剩余觅豆原路退回发出者币账户）；领取路径上另有惰性过期兜底，本扫描为兜底。
export function refundExpiredRedPackets(db) {
  const rows = q(db, "SELECT * FROM red_packets WHERE status='active' AND expire_at<=?", new Date().toISOString());
  for (const p of rows) expirePacket(db, p);
  return rows.length;
}

export function runJanitor(db) {
  const nowIso = new Date().toISOString();
  const nowMs = Date.now();
  const smsExpireIso = new Date(nowMs - 10 * 60 * 1000).toISOString();
  const idemExpireIso = new Date(nowMs - 7 * 24 * 3600 * 1000).toISOString();
  const viewExpireIso = new Date(nowMs - 48 * 3600 * 1000).toISOString();
  const jobs = [
    ['sms_codes', 'DELETE FROM sms_codes WHERE used=1 OR created_at<?', [smsExpireIso]],
    ['captcha_challenges', 'DELETE FROM captcha_challenges WHERE used=1 OR expires_at<?', [nowMs]],
    ['captcha_tokens', 'DELETE FROM captcha_tokens WHERE used=1 OR expires_at<?', [nowMs]],
    ['idempotency_keys', 'DELETE FROM idempotency_keys WHERE created_at<?', [idemExpireIso]],
    ['tokens', 'DELETE FROM tokens WHERE revoked=1 OR refresh_expires_at<?', [nowIso]],
    ['group_unlocks', 'DELETE FROM group_unlocks WHERE expires_at<?', [nowIso]],
    ['hometown_views', 'DELETE FROM hometown_views WHERE viewed_at<?', [viewExpireIso]],
  ];
  const deleted = [];
  for (const [table, sql, params] of jobs) {
    const info = run(db, sql, ...params);
    const n = Number(info.changes);
    if (n > 0) deleted.push(`${table}=${n}`);
  }
  const refunded = refundExpiredRedPackets(db);
  if (refunded > 0) deleted.push(`red_packets_refund=${refunded}`);
  console.log(`[janitor] 过期数据清理完成：${deleted.length ? deleted.join(', ') : '无待清理数据'}`);
}

export function startJanitor(db, intervalMs = 6 * 3600 * 1000) {
  runJanitor(db);
  const timer = setInterval(() => {
    try {
      runJanitor(db);
    } catch (err) {
      console.error('[janitor] 清理失败', err);
    }
  }, intervalMs);
  timer.unref();
  return timer;
}
