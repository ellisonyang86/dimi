import { q1, run, audit } from './repo.js';
import { now } from './util.js';
import { rules } from './engine/index.js';
import { E } from './http/respond.js';

// ============ 觅豆账本原语（P0 纯赠送体系，《虚拟币与打赏体系设计_V1》§1.3/§8） ============
// 红线（V3.1 A8）：币只能经任务/活跃赠送获得，无充值、无提现、无现金价值。
// 全部币变动只经 creditCoins/debitCoins，禁止业务代码直接 UPDATE coin_accounts；
// 余额为缓存，以 coin_transactions 流水为准；收入天然幂等
// （UNIQUE(biz_type,biz_id,user_id,direction)，重放 INSERT OR IGNORE 落空）。

// 多步写事务：BEGIN IMMEDIATE 保证单写者，失败回滚（node:sqlite 同步驱动内串行执行）
export function withTx(db, fn) {
  db.exec('BEGIN IMMEDIATE');
  try {
    const result = fn();
    db.exec('COMMIT');
    return result;
  } catch (err) {
    try { db.exec('ROLLBACK'); } catch { /* 已回滚 */ }
    throw err;
  }
}

export function ensureCoinAccount(db, userId) {
  run(
    db,
    'INSERT OR IGNORE INTO coin_accounts(user_id,balance,total_earned,total_spent,updated_at) VALUES(?,0,0,0,?)',
    userId, now()
  );
  return q1(db, 'SELECT * FROM coin_accounts WHERE user_id=?', userId);
}

export function coinBalance(db, userId) {
  return ensureCoinAccount(db, userId).balance;
}

// 入账（收入）：同一 biz 单据同一方向只入账一次；重复调用返回 duplicated:true 不加币
export function creditCoins(db, { userId, bizType, bizId, amount, remark = null }) {
  ensureCoinAccount(db, userId);
  const bizKey = String(bizId);
  const info = run(
    db,
    `INSERT OR IGNORE INTO coin_transactions(biz_type,biz_id,user_id,direction,amount,balance_after,remark,created_at)
     VALUES(?,?,?,'in',?,0,?,?)`,
    bizType, bizKey, userId, amount, remark, now()
  );
  if (!Number(info.changes)) return { duplicated: true, balance: coinBalance(db, userId) };
  run(
    db,
    'UPDATE coin_accounts SET balance=balance+?, total_earned=total_earned+?, updated_at=? WHERE user_id=?',
    amount, amount, now(), userId
  );
  const balance = coinBalance(db, userId);
  run(
    db,
    "UPDATE coin_transactions SET balance_after=? WHERE biz_type=? AND biz_id=? AND user_id=? AND direction='in'",
    balance, bizType, bizKey, userId
  );
  return { duplicated: false, balance };
}

// 扣减（支出）：条件更新保证不透支；余额不足抛 40001
export function debitCoins(db, { userId, bizType, bizId, amount, remark = null }) {
  ensureCoinAccount(db, userId);
  const info = run(
    db,
    'UPDATE coin_accounts SET balance=balance-?, total_spent=total_spent+?, updated_at=? WHERE user_id=? AND balance>=?',
    amount, amount, now(), userId, amount
  );
  if (!Number(info.changes)) throw E.param('觅豆余额不足');
  const balance = coinBalance(db, userId);
  run(
    db,
    `INSERT INTO coin_transactions(biz_type,biz_id,user_id,direction,amount,balance_after,remark,created_at)
     VALUES(?,?,?,'out',?,?,?,?)`,
    bizType, String(bizId), userId, amount, balance, remark, now()
  );
  return { balance };
}

// 任务赠送（规则在 rules.json coin_tasks）：
//   period=day        每日一次（period_key=YYYY-MM-DD）
//   period=once       成就类一次性
//   period=per_target 每目标一次（如每成功添加一位好友，targetId 为被添加者）
// 幂等：biz_id=`${code}:${periodKey}` 撞流水唯一键，同一成就只发一次
export function grantTask(db, userId, code, { periodKey = null, targetId = null } = {}) {
  const conf = rules.coin_tasks?.[code];
  if (!conf) return { granted: false, amount: 0 };
  let key;
  if (conf.period === 'day') key = periodKey ?? now().slice(0, 10);
  else if (conf.period === 'once') key = 'all';
  else if (conf.period === 'per_target') key = String(targetId);
  else return { granted: false, amount: 0 };
  const r = creditCoins(db, {
    userId, bizType: 'grant_task', bizId: `${code}:${key}`, amount: conf.amount, remark: conf.remark,
  });
  if (!r.duplicated) {
    audit(db, { userId, event: 'coin_grant', input: { task: code, amount: conf.amount, period_key: key } });
    return { granted: true, amount: conf.amount, balance: r.balance };
  }
  return { granted: false, amount: 0, balance: r.balance };
}
