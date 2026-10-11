import { now, decryptField, blindIndex } from './util.js';

export const q = (db, sql, ...params) => db.prepare(sql).all(...params);
export const q1 = (db, sql, ...params) => db.prepare(sql).get(...params);
export const run = (db, sql, ...params) => db.prepare(sql).run(...params);

// 用户行读取出口：手机号字段解密（存储层 AES-256-GCM，见 util.js）
const withDecryptedPhone = (row) =>
  row ? { ...row, phone: decryptField(row.phone) } : row;

export const getUser = (db, id) => withDecryptedPhone(q1(db, 'SELECT * FROM users WHERE id=?', id));
export const getUserByPhone = (db, phone) =>
  withDecryptedPhone(q1(db, 'SELECT * FROM users WHERE phone_idx=?', blindIndex('phone', String(phone))));

const ADD_VIA_DEFAULTS = {
  dimi_no: true, phone: true, school_search: true, hometown_search: true,
  group: true, business_card: true, contact_match: true,
};

export function getPrivacy(db, user) {
  const row = q1(db, 'SELECT * FROM privacy_settings WHERE user_id=?', user.id);
  const base = {
    friend_verify_required: 1,
    name_mode: 'balanced',
    add_me_via: { ...ADD_VIA_DEFAULTS },
    hometown_visibility: 'public',
    current_city_visible: 1,
    stranger_moments_10: 0,
    friend_moments_range: 'all',
    read_receipt: 0,
    typing_visible: 1,
    group_temp_chat: 0,
    notify_when_searched: 0,
    personalized_recommend: 1,
    female_protect: user.gender === 2 || user.is_minor ? 1 : 0,
  };
  if (!row) return base;
  return {
    ...base,
    ...row,
    add_me_via: { ...ADD_VIA_DEFAULTS, ...JSON.parse(row.add_me_via || '{}') },
    female_protect: row.female_protect ?? base.female_protect,
  };
}

export const isFriend = (db, viewerId, ownerId) =>
  !!q1(db, 'SELECT 1 x FROM friendships WHERE user_id=? AND friend_id=?', viewerId, ownerId);

export const isBlockedBetween = (db, a, b) =>
  !!q1(
    db,
    'SELECT 1 x FROM blocks WHERE (user_id=? AND blocked_id=?) OR (user_id=? AND blocked_id=?)',
    a, b, b, a
  );

export const countMutualFriends = (db, a, b) =>
  q1(
    db,
    `SELECT COUNT(*) c FROM friendships f1
     JOIN friendships f2 ON f1.friend_id = f2.friend_id
     WHERE f1.user_id=? AND f2.user_id=?`,
    a, b
  ).c;

export function relationBetween(db, viewerId, ownerId) {
  if (isBlockedBetween(db, viewerId, ownerId)) return 'blocked';
  if (isFriend(db, viewerId, ownerId)) return 'friend';
  const out = q1(
    db,
    "SELECT 1 x FROM friend_requests WHERE from_user=? AND to_user=? AND status='pending'",
    viewerId, ownerId
  );
  if (out) return 'pending_out';
  const inn = q1(
    db,
    "SELECT 1 x FROM friend_requests WHERE from_user=? AND to_user=? AND status='pending'",
    ownerId, viewerId
  );
  if (inn) return 'pending_in';
  return 'none';
}

// 行政区划祖先链（含自身），level 1=省 2=市 3=区县 4=乡镇
export function regionChain(db, code) {
  const chain = [];
  let cur = q1(db, 'SELECT * FROM regions WHERE code=?', code);
  let guard = 0;
  while (cur && guard++ < 6) {
    chain.unshift(cur);
    cur = cur.parent_code ? q1(db, 'SELECT * FROM regions WHERE code=?', cur.parent_code) : null;
  }
  return chain;
}

export function audit(db, { userId = null, event, targetId = null, scene = null, input = null, rule = null, output = null, ip = null }) {
  run(
    db,
    'INSERT INTO audit_logs(user_id,event,target_id,scene,input_json,rule_json,output_json,ip,created_at) VALUES(?,?,?,?,?,?,?,?,?)',
    userId, event, targetId, scene,
    input == null ? null : JSON.stringify(input),
    rule == null ? null : JSON.stringify(rule),
    output == null ? null : JSON.stringify(output),
    ip, now()
  );
}
