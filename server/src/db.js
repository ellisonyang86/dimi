import fs from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { encryptField, blindIndex } from './util.js';

const SCHEMA = `
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  dimi_no TEXT UNIQUE,
  phone TEXT UNIQUE NOT NULL,
  nickname TEXT NOT NULL,
  real_name TEXT,
  gender INTEGER DEFAULT 0,
  birth_year INTEGER,
  avatar_url TEXT,
  signature TEXT,
  password_hash TEXT,
  status INTEGER DEFAULT 1,
  is_minor INTEGER DEFAULT 0,
  credit_score INTEGER DEFAULT 100,
  real_name_changed_at TEXT,
  invite_channel TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS privacy_settings (
  user_id INTEGER PRIMARY KEY,
  friend_verify_required INTEGER DEFAULT 1,
  name_mode TEXT DEFAULT 'balanced',
  add_me_via TEXT DEFAULT '{}',
  hometown_visibility TEXT DEFAULT 'public',
  current_city_visible INTEGER DEFAULT 1,
  stranger_moments_10 INTEGER DEFAULT 0,
  friend_moments_range TEXT DEFAULT 'all',
  read_receipt INTEGER DEFAULT 0,
  typing_visible INTEGER DEFAULT 1,
  group_temp_chat INTEGER DEFAULT 0,
  notify_when_searched INTEGER DEFAULT 0,
  personalized_recommend INTEGER DEFAULT 1,
  female_protect INTEGER
);
CREATE TABLE IF NOT EXISTS dimi_no_claims (
  dimi_no TEXT PRIMARY KEY COLLATE NOCASE,
  user_id INTEGER NOT NULL,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS sms_codes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  phone TEXT NOT NULL, code TEXT NOT NULL, scene TEXT, used INTEGER DEFAULT 0, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS tokens (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL,
  access_token TEXT UNIQUE NOT NULL,
  refresh_token TEXT UNIQUE NOT NULL,
  access_expires_at TEXT NOT NULL,
  refresh_expires_at TEXT NOT NULL,
  device_info TEXT,
  revoked INTEGER DEFAULT 0,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS schools (
  school_id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  former_names TEXT DEFAULT '[]',
  region_code TEXT,
  stage TEXT,
  status TEXT DEFAULT 'active'
);
CREATE TABLE IF NOT EXISTS school_applications (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER, name TEXT, region_code TEXT, evidence_urls TEXT,
  status TEXT DEFAULT 'pending', created_at TEXT
);
CREATE TABLE IF NOT EXISTS education_experiences (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL,
  stage TEXT NOT NULL,
  school_id INTEGER NOT NULL,
  school_name_snapshot TEXT,
  enroll_year INTEGER NOT NULL,
  class_name_raw TEXT,
  class_name_norm TEXT NOT NULL DEFAULT '',
  department TEXT, major TEXT,
  visibility TEXT DEFAULT 'public',
  verification_level INTEGER NOT NULL DEFAULT 0,
  verified_at TEXT,
  verification_source TEXT,
  created_at TEXT NOT NULL,
  UNIQUE(user_id, school_id, enroll_year, stage, class_name_norm)
);
CREATE TABLE IF NOT EXISTS regions (
  code TEXT PRIMARY KEY, name TEXT NOT NULL, level INTEGER NOT NULL,
  parent_code TEXT, is_active INTEGER DEFAULT 1
);
CREATE TABLE IF NOT EXISTS user_hometowns (
  user_id INTEGER NOT NULL, type INTEGER NOT NULL, region_code TEXT NOT NULL,
  visibility TEXT DEFAULT 'public', PRIMARY KEY(user_id, type)
);
CREATE TABLE IF NOT EXISTS friendships (
  user_id INTEGER NOT NULL, friend_id INTEGER NOT NULL,
  remark_name TEXT, tags TEXT DEFAULT '[]', source TEXT, is_starred INTEGER DEFAULT 0, created_at TEXT,
  PRIMARY KEY(user_id, friend_id)
);
CREATE TABLE IF NOT EXISTS friend_requests (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  from_user INTEGER NOT NULL, to_user INTEGER NOT NULL,
  verify_msg TEXT NOT NULL, attach_real_name INTEGER DEFAULT 1, attach_education INTEGER DEFAULT 0,
  source TEXT, intersection_snapshot TEXT,
  status TEXT DEFAULT 'pending', expire_at TEXT, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS blocks (
  user_id INTEGER NOT NULL, blocked_id INTEGER NOT NULL, created_at TEXT,
  PRIMARY KEY(user_id, blocked_id)
);
CREATE TABLE IF NOT EXISTS conversations (
  conv_id INTEGER PRIMARY KEY AUTOINCREMENT,
  conv_type TEXT NOT NULL DEFAULT 'single',
  user_a INTEGER, user_b INTEGER, title TEXT, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS conversation_members (
  conv_id INTEGER NOT NULL, user_id INTEGER NOT NULL,
  last_read_msg_id INTEGER DEFAULT 0, is_pinned INTEGER DEFAULT 0, is_muted INTEGER DEFAULT 0,
  PRIMARY KEY(conv_id, user_id)
);
CREATE TABLE IF NOT EXISTS class_groups (
  group_id INTEGER PRIMARY KEY AUTOINCREMENT,
  conv_id INTEGER NOT NULL,
  school_id INTEGER NOT NULL,
  enroll_year INTEGER NOT NULL,
  class_name_norm TEXT NOT NULL,
  announcement TEXT DEFAULT '',
  created_by INTEGER,
  created_at TEXT NOT NULL,
  UNIQUE(school_id, enroll_year, class_name_norm)
);
CREATE TABLE IF NOT EXISTS hometown_groups (
  group_id INTEGER PRIMARY KEY AUTOINCREMENT,
  conv_id INTEGER NOT NULL,
  region_prefix TEXT NOT NULL UNIQUE,
  announcement TEXT DEFAULT '',
  created_by INTEGER,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS messages (
  msg_id INTEGER PRIMARY KEY AUTOINCREMENT,
  conv_id INTEGER NOT NULL, sender_id INTEGER NOT NULL,
  msg_type TEXT NOT NULL DEFAULT 'text', content TEXT,
  client_msg_id TEXT NOT NULL, status TEXT DEFAULT 'delivered', created_at TEXT NOT NULL,
  UNIQUE(conv_id, sender_id, client_msg_id)
);
CREATE TABLE IF NOT EXISTS placeholders (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  school_id INTEGER NOT NULL, enroll_year INTEGER NOT NULL, class_norm TEXT NOT NULL, name TEXT NOT NULL,
  lit_by INTEGER, created_at TEXT,
  UNIQUE(school_id, enroll_year, class_norm, name)
);
CREATE TABLE IF NOT EXISTS invites (
  code TEXT PRIMARY KEY, school_id INTEGER NOT NULL, enroll_year INTEGER NOT NULL,
  class_norm TEXT NOT NULL, class_name TEXT, created_by INTEGER, created_at TEXT
);
CREATE TABLE IF NOT EXISTS reports (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  reporter_id INTEGER NOT NULL, target_type TEXT NOT NULL, target_id INTEGER NOT NULL,
  reason TEXT NOT NULL, detail TEXT, status TEXT DEFAULT 'pending', sla_deadline TEXT, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS feedback (
  id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER, content TEXT NOT NULL, contact TEXT, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS audit_logs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER, event TEXT NOT NULL, target_id INTEGER, scene TEXT,
  input_json TEXT, rule_json TEXT, output_json TEXT, ip TEXT, created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_user ON audit_logs(user_id, created_at);
CREATE INDEX IF NOT EXISTS idx_audit_event ON audit_logs(event, created_at);
CREATE TABLE IF NOT EXISTS rate_counters (
  key TEXT PRIMARY KEY, count INTEGER NOT NULL, reset_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS contact_groups (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL, name TEXT NOT NULL, privacy_level TEXT NOT NULL DEFAULT 'normal',
  sort INTEGER DEFAULT 0, created_at TEXT NOT NULL,
  UNIQUE(user_id, name)
);
CREATE TABLE IF NOT EXISTS group_unlocks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL, token_hash TEXT NOT NULL, expires_at TEXT NOT NULL, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS recommendation_feedback (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL, target_user_id INTEGER NOT NULL, action TEXT NOT NULL, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS moments (
  moment_id INTEGER PRIMARY KEY AUTOINCREMENT,
  author_id INTEGER NOT NULL,
  content_type TEXT NOT NULL DEFAULT 'text',
  content TEXT,
  media TEXT DEFAULT '[]',
  visibility TEXT NOT NULL DEFAULT 'public',
  visible_tag_ids TEXT DEFAULT '[]',
  excluded_user_ids TEXT DEFAULT '[]',
  location_poi TEXT,
  deleted INTEGER DEFAULT 0,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS moment_likes (
  moment_id INTEGER NOT NULL, user_id INTEGER NOT NULL, created_at TEXT NOT NULL,
  PRIMARY KEY(moment_id, user_id)
);
CREATE TABLE IF NOT EXISTS moment_comments (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  moment_id INTEGER NOT NULL, from_user INTEGER NOT NULL, reply_to_user_id INTEGER,
  content TEXT NOT NULL, deleted INTEGER DEFAULT 0, created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_moments_author ON moments(author_id, created_at);
CREATE TABLE IF NOT EXISTS appeals (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL, type TEXT NOT NULL, content TEXT NOT NULL,
  status TEXT DEFAULT 'pending', sla_deadline TEXT, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS idempotency_keys (
  key TEXT NOT NULL, user_id INTEGER NOT NULL, endpoint TEXT NOT NULL,
  response_json TEXT, created_at TEXT NOT NULL,
  PRIMARY KEY(key, user_id, endpoint)
);
CREATE TABLE IF NOT EXISTS captcha_challenges (
  captcha_id TEXT PRIMARY KEY,
  target_x INTEGER NOT NULL,
  notch_y INTEGER NOT NULL,
  bg_seed TEXT NOT NULL,
  used INTEGER DEFAULT 0,
  expires_at INTEGER NOT NULL,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS captcha_tokens (
  token_hash TEXT PRIMARY KEY,
  expires_at INTEGER NOT NULL,
  used INTEGER DEFAULT 0,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_edu_unit ON education_experiences(school_id, enroll_year, class_name_norm);
CREATE INDEX IF NOT EXISTS idx_msgs_conv ON messages(conv_id, msg_id);
CREATE INDEX IF NOT EXISTS idx_class_groups_conv ON class_groups(conv_id);
CREATE INDEX IF NOT EXISTS idx_hometown_groups_conv ON hometown_groups(conv_id);
CREATE INDEX IF NOT EXISTS idx_req_to ON friend_requests(to_user, status);
CREATE INDEX IF NOT EXISTS idx_req_pair ON friend_requests(from_user, to_user, created_at);
-- ============ 觅豆（P0 纯赠送体系，《DIMI围城_虚拟币与打赏体系设计_V1.md》§1.3/§8.2） ============
-- 红线约束（V3.1 A8）：币只能任务/活跃获得，无充值、无提现、不产生现金价值。
-- 表结构与 P1+ 真金方案同构：充值/提现字段（transaction_id/amount_fen 等）后续以
-- addColumn 幂等迁移追加，本层不改既有列。
CREATE TABLE IF NOT EXISTS coin_accounts (
  user_id INTEGER PRIMARY KEY,
  balance INTEGER NOT NULL DEFAULT 0,
  total_earned INTEGER NOT NULL DEFAULT 0,
  total_spent INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS coin_transactions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  biz_type TEXT NOT NULL,
  biz_id TEXT NOT NULL,
  user_id INTEGER NOT NULL,
  direction TEXT NOT NULL,
  amount INTEGER NOT NULL,
  balance_after INTEGER NOT NULL,
  remark TEXT,
  created_at TEXT NOT NULL,
  UNIQUE(biz_type, biz_id, user_id, direction)
);
CREATE INDEX IF NOT EXISTS idx_coin_txn_user ON coin_transactions(user_id, created_at);
CREATE TABLE IF NOT EXISTS red_packets (
  packet_id TEXT PRIMARY KEY,
  conv_id INTEGER NOT NULL,
  msg_id INTEGER,
  sender_id INTEGER NOT NULL,
  type TEXT NOT NULL,
  total_amount INTEGER NOT NULL,
  count INTEGER NOT NULL,
  claimed_amount INTEGER NOT NULL DEFAULT 0,
  claimed_count INTEGER NOT NULL DEFAULT 0,
  greeting TEXT,
  status TEXT NOT NULL DEFAULT 'active',
  expire_at TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_packet_expire ON red_packets(status, expire_at);
CREATE TABLE IF NOT EXISTS red_packet_claims (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  packet_id TEXT NOT NULL,
  user_id INTEGER NOT NULL,
  amount INTEGER NOT NULL,
  is_best INTEGER DEFAULT 0,
  created_at TEXT NOT NULL,
  UNIQUE(packet_id, user_id)
);
CREATE TABLE IF NOT EXISTS gift_orders (
  order_id TEXT PRIMARY KEY,
  from_user INTEGER NOT NULL,
  to_user INTEGER NOT NULL,
  moment_id INTEGER,
  coin_amount INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'confirmed',
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_gift_moment ON gift_orders(moment_id);
-- ============ 家乡页（《DIMI围城_家乡页与共建体系设计_V1》§9，M1 范围） ============
-- M1 只消费最新区/投稿/浏览/点赞/关注；pinned_by/pinned_at/heat/gift_coins 四字段
-- 按 §9 DDL 保留（M2 热度榜/置顶/打赏再消费），守护人表 hometown_guardians 属 M2 不建。
CREATE TABLE IF NOT EXISTS hometown_pages (
  page_id INTEGER PRIMARY KEY AUTOINCREMENT,
  region_code TEXT NOT NULL UNIQUE,        -- 镇级行政区划码（regions level=4）
  cover_media TEXT,                        -- 封面图（/media/ 路径）
  intro TEXT DEFAULT '',                   -- 集体简介（守护人/平台可编辑，M2）
  follower_count INTEGER DEFAULT 0,
  content_count INTEGER DEFAULT 0,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS hometown_contents (
  content_id INTEGER PRIMARY KEY AUTOINCREMENT,
  region_code TEXT NOT NULL,               -- 归属镇
  author_id INTEGER NOT NULL,              -- 服务端校验其籍贯匹配（市级前缀）
  category TEXT NOT NULL,                  -- scenery 风光 / product 特产 / craft 手艺 / story 故事
  title TEXT NOT NULL,                     -- ≤30 字
  body TEXT,                               -- ≤500 字
  media TEXT DEFAULT '[]',                 -- JSON 数组，≤9 图
  status TEXT NOT NULL DEFAULT 'pending',  -- pending/published/pinned/rejected/removed（M1 直接 published）
  view_count INTEGER DEFAULT 0,
  like_count INTEGER DEFAULT 0,
  gift_coins INTEGER DEFAULT 0,            -- M2 打赏热度折算用，M1 恒 0
  heat REAL DEFAULT 0,                     -- M2 热度分（janitor 周任务重算），M1 恒 0
  pinned_by INTEGER, pinned_at TEXT,       -- M2 置顶者（守护人/平台）
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_hc_region_heat ON hometown_contents(region_code, status, heat DESC);
-- 浏览去重（24h 同人同内容计 1 次；janitor 清理超 48h 记录）
CREATE TABLE IF NOT EXISTS hometown_views (
  content_id INTEGER NOT NULL, viewer_id INTEGER NOT NULL, viewed_at TEXT NOT NULL,
  PRIMARY KEY(content_id, viewer_id)
);
-- 关注家乡
CREATE TABLE IF NOT EXISTS hometown_follows (
  user_id INTEGER NOT NULL, region_code TEXT NOT NULL, created_at TEXT NOT NULL,
  PRIMARY KEY(user_id, region_code)
);
-- 内容点赞明细（§9 未单列：点赞幂等与 liked 标记需要落明细，参照 moment_likes 同构）
CREATE TABLE IF NOT EXISTS hometown_content_likes (
  content_id INTEGER NOT NULL, user_id INTEGER NOT NULL, created_at TEXT NOT NULL,
  PRIMARY KEY(content_id, user_id)
);
CREATE TABLE IF NOT EXISTS hometown_comments (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  content_id INTEGER NOT NULL,
  from_user INTEGER NOT NULL,
  content TEXT NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_hometown_comments ON hometown_comments(content_id, deleted, id DESC);
`;

export function openDb(dbPath) {
  if (dbPath !== ':memory:') {
    fs.mkdirSync(path.dirname(dbPath), { recursive: true });
  }
  const db = new DatabaseSync(dbPath);
  db.exec('PRAGMA journal_mode = WAL;');
  db.exec('PRAGMA foreign_keys = ON;');
  db.exec(SCHEMA);
  migrateFieldEncryption(db);
  return db;
}

// 敏感字段加密迁移：users.phone / sms_codes.phone 明文 → AES-256-GCM 密文 + HMAC 盲索引。
// 幂等：已加密行（enc:v1: 前缀）跳过；盲索引列存在性通过 PRAGMA 检测。
function migrateFieldEncryption(db) {
  const addColumn = (table, ddl) => {
    const cols = db.prepare(`PRAGMA table_info(${table})`).all().map((c) => c.name);
    if (!cols.includes(ddl.split(' ')[0])) db.exec(`ALTER TABLE ${table} ADD COLUMN ${ddl}`);
  };
  addColumn('users', 'phone_idx TEXT');
  addColumn('gift_orders', 'hometown_content_id INTEGER');
  db.exec('CREATE INDEX IF NOT EXISTS idx_gift_hometown ON gift_orders(hometown_content_id)');
  addColumn('users', 'deactivated_at TEXT');
  addColumn('users', 'privacy_password_hash TEXT');
  addColumn('users', 'moment_cover TEXT');
  addColumn('users', 'dimi_no_changed_at TEXT');
  addColumn('friendships', 'group_id INTEGER');
  addColumn('sms_codes', 'phone_idx TEXT');
  addColumn('privacy_settings', "contacts_visibility TEXT DEFAULT '{}'");
  addColumn('sms_codes', 'attempts INTEGER DEFAULT 0');
  addColumn('conversation_members', 'cleared_before_msg_id INTEGER NOT NULL DEFAULT 0');
  addColumn('conversation_members', 'hidden_until_msg_id INTEGER');

  const plainUsers = db.prepare("SELECT id, phone FROM users WHERE phone NOT LIKE 'enc:v1:%'").all();
  for (const u of plainUsers) {
    db.prepare('UPDATE users SET phone=?, phone_idx=? WHERE id=?')
      .run(encryptField(u.phone), blindIndex('phone', u.phone), u.id);
  }
  const plainSms = db.prepare("SELECT id, phone FROM sms_codes WHERE phone NOT LIKE 'enc:v1:%'").all();
  for (const s of plainSms) {
    db.prepare('UPDATE sms_codes SET phone=?, phone_idx=? WHERE id=?')
      .run(encryptField(s.phone), blindIndex('phone', s.phone), s.id);
  }
  db.exec('CREATE UNIQUE INDEX IF NOT EXISTS idx_users_phone_idx ON users(phone_idx)');
  db.exec('CREATE INDEX IF NOT EXISTS idx_sms_phone_idx ON sms_codes(phone_idx)');
}
