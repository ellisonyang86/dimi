import { q1, run } from './repo.js';

// 简单固定窗口计数器（存 rate_counters 表）。key 已含窗口语义（如 sms:min:xxx / search:user:hour）。
export function hitRate(db, key, limit, windowSec) {
  const nowMs = Date.now();
  const row = q1(db, 'SELECT * FROM rate_counters WHERE key=?', key);
  if (!row || row.reset_at <= nowMs) {
    run(
      db,
      'INSERT INTO rate_counters(key,count,reset_at) VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET count=1, reset_at=?',
      key, 1, nowMs + windowSec * 1000, nowMs + windowSec * 1000
    );
    return { allowed: true, count: 1 };
  }
  const count = row.count + 1;
  run(db, 'UPDATE rate_counters SET count=? WHERE key=?', count, key);
  return { allowed: count <= limit, count };
}

// 重置计数窗口：captcha_token 验证通过后放行并重置（42901 need_captcha 消费点）
export function resetRate(db, key) {
  run(db, 'DELETE FROM rate_counters WHERE key=?', key);
}
