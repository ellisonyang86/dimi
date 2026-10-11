import { q, q1, run } from '../repo.js';
import { now } from '../util.js';

/**
 * IM Provider 接口层（计划书 §5.3「SDK 可替换」）。
 * 消息收发全部经此接口，路由层不直接操作消息表。
 * 通过环境变量 DIMI_IM_PROVIDER 切换实现：local（默认，自研极简 IM 落 SQLite）/ tencent（预留）。
 */
export class LocalIMProvider {
  constructor(db) {
    this.db = db;
  }

  getOrCreateSingleConversation(a, b) {
    const [lo, hi] = [Math.min(a, b), Math.max(a, b)];
    let conv = q1(this.db, "SELECT * FROM conversations WHERE conv_type='single' AND user_a=? AND user_b=?", lo, hi);
    if (!conv) {
      const info = run(
        this.db,
        "INSERT INTO conversations(conv_type,user_a,user_b,created_at) VALUES('single',?,?,?)",
        lo, hi, now()
      );
      const convId = Number(info.lastInsertRowid);
      run(this.db, 'INSERT OR IGNORE INTO conversation_members(conv_id,user_id) VALUES(?,?)', convId, lo);
      run(this.db, 'INSERT OR IGNORE INTO conversation_members(conv_id,user_id) VALUES(?,?)', convId, hi);
      conv = q1(this.db, 'SELECT * FROM conversations WHERE conv_id=?', convId);
    }
    return conv;
  }

  isMember(convId, userId) {
    return this.isConvMember(convId, userId);
  }

  isConvMember(convId, userId) {
    return !!q1(this.db, 'SELECT 1 x FROM conversation_members WHERE conv_id=? AND user_id=?', convId, userId);
  }

  // 班级群：班级单元（school_id+enroll_year+class_name_norm）一一对应一个群会话。
  // 已存在则直接返回；并发建群撞 UNIQUE 时回滚本会话、重查返回（幂等）。
  getOrCreateClassGroup({ schoolId, enrollYear, classNameNorm, title = null, creatorId = null }) {
    const find = () => q1(
      this.db,
      'SELECT * FROM class_groups WHERE school_id=? AND enroll_year=? AND class_name_norm=?',
      schoolId, enrollYear, classNameNorm
    );
    let group = find();
    if (group) {
      return { group, conv: q1(this.db, 'SELECT * FROM conversations WHERE conv_id=?', group.conv_id), created: false };
    }
    const info = run(
      this.db,
      "INSERT INTO conversations(conv_type,title,created_at) VALUES('group',?,?)",
      title, now()
    );
    const convId = Number(info.lastInsertRowid);
    try {
      run(
        this.db,
        'INSERT INTO class_groups(conv_id,school_id,enroll_year,class_name_norm,created_by,created_at) VALUES(?,?,?,?,?,?)',
        convId, schoolId, enrollYear, classNameNorm, creatorId, now()
      );
    } catch {
      run(this.db, 'DELETE FROM conversations WHERE conv_id=?', convId);
      group = find();
      return { group, conv: q1(this.db, 'SELECT * FROM conversations WHERE conv_id=?', group.conv_id), created: false };
    }
    if (creatorId != null) {
      run(this.db, 'INSERT OR IGNORE INTO conversation_members(conv_id,user_id) VALUES(?,?)', convId, creatorId);
    }
    group = q1(this.db, 'SELECT * FROM class_groups WHERE conv_id=?', convId);
    return { group, conv: q1(this.db, 'SELECT * FROM conversations WHERE conv_id=?', convId), created: true };
  }

  // 老乡群：家乡同市单元（user_hometowns type=1 的 region_code 前 4 位）一一对应一个群会话。
  // 已存在则直接返回；并发建群撞 UNIQUE 时回滚本会话、重查返回（幂等）。
  getOrCreateHometownGroup({ regionPrefix, title = null, creatorId = null }) {
    const find = () => q1(this.db, 'SELECT * FROM hometown_groups WHERE region_prefix=?', regionPrefix);
    let group = find();
    if (group) {
      return { group, conv: q1(this.db, 'SELECT * FROM conversations WHERE conv_id=?', group.conv_id), created: false };
    }
    const info = run(
      this.db,
      "INSERT INTO conversations(conv_type,title,created_at) VALUES('group',?,?)",
      title, now()
    );
    const convId = Number(info.lastInsertRowid);
    try {
      run(
        this.db,
        'INSERT INTO hometown_groups(conv_id,region_prefix,created_by,created_at) VALUES(?,?,?,?)',
        convId, regionPrefix, creatorId, now()
      );
    } catch {
      run(this.db, 'DELETE FROM conversations WHERE conv_id=?', convId);
      group = find();
      return { group, conv: q1(this.db, 'SELECT * FROM conversations WHERE conv_id=?', group.conv_id), created: false };
    }
    if (creatorId != null) {
      run(this.db, 'INSERT OR IGNORE INTO conversation_members(conv_id,user_id) VALUES(?,?)', convId, creatorId);
    }
    group = q1(this.db, 'SELECT * FROM hometown_groups WHERE conv_id=?', convId);
    return { group, conv: q1(this.db, 'SELECT * FROM conversations WHERE conv_id=?', convId), created: true };
  }

  joinConversation(convId, userId) {
    run(this.db, 'INSERT OR IGNORE INTO conversation_members(conv_id,user_id) VALUES(?,?)', convId, userId);
  }

  leaveConversation(convId, userId) {
    run(this.db, 'DELETE FROM conversation_members WHERE conv_id=? AND user_id=?', convId, userId);
    const next = q1(this.db, `SELECT m.user_id FROM conversation_members m JOIN users u ON u.id=m.user_id
      WHERE m.conv_id=? AND u.status=1 ORDER BY m.rowid LIMIT 1`, convId);
    for (const table of ['class_groups', 'hometown_groups']) {
      run(this.db, `UPDATE ${table} SET created_by=? WHERE conv_id=? AND created_by=?`, next?.user_id ?? null, convId, userId);
    }
  }

  syncClassMemberships(userId) {
    const invalid = q(this.db, `SELECT g.conv_id FROM class_groups g
      JOIN conversation_members m ON m.conv_id=g.conv_id AND m.user_id=?
      WHERE NOT EXISTS (SELECT 1 FROM education_experiences e WHERE e.user_id=m.user_id
        AND e.school_id=g.school_id AND e.enroll_year=g.enroll_year AND e.class_name_norm=g.class_name_norm)`, userId);
    for (const group of invalid) this.leaveConversation(group.conv_id, userId);
  }

  convMemberCount(convId) {
    return q1(this.db, 'SELECT COUNT(*) c FROM conversation_members WHERE conv_id=?', convId).c;
  }

  listConvMembers(convId) {
    return q(this.db, 'SELECT * FROM conversation_members WHERE conv_id=? ORDER BY rowid', convId);
  }

  otherMember(conv, userId) {
    return conv.user_a === userId ? conv.user_b : conv.user_a;
  }

  listConversations(userId) {
    return q(
      this.db,
      `SELECT c.*, m.last_read_msg_id, m.is_pinned, m.is_muted
       FROM conversation_members m JOIN conversations c ON c.conv_id = m.conv_id
       WHERE m.user_id=? AND (m.hidden_until_msg_id IS NULL OR EXISTS (
         SELECT 1 FROM messages msg WHERE msg.conv_id=c.conv_id AND msg.msg_id>m.hidden_until_msg_id
       )) ORDER BY m.is_pinned DESC,
       COALESCE((SELECT MAX(msg_id) FROM messages WHERE conv_id=c.conv_id),0) DESC, c.conv_id DESC`,
      userId
    );
  }

  clearedBefore(convId, userId) {
    if (userId == null) return 0;
    return q1(this.db, 'SELECT cleared_before_msg_id FROM conversation_members WHERE conv_id=? AND user_id=?', convId, userId)?.cleared_before_msg_id ?? 0;
  }

  lastMessage(convId, userId = null) {
    return q1(this.db, 'SELECT * FROM messages WHERE conv_id=? AND msg_id>? ORDER BY msg_id DESC LIMIT 1', convId, this.clearedBefore(convId, userId));
  }

  clearConversation(convId, userId) {
    const lastId = this.lastMessage(convId)?.msg_id ?? 0;
    run(this.db, `UPDATE conversation_members SET cleared_before_msg_id=?, hidden_until_msg_id=?,
      last_read_msg_id=MAX(last_read_msg_id,?) WHERE conv_id=? AND user_id=?`, lastId, lastId, lastId, convId, userId);
  }

  showConversation(convId, userId) {
    run(this.db, 'UPDATE conversation_members SET hidden_until_msg_id=NULL WHERE conv_id=? AND user_id=?', convId, userId);
  }

  unreadCount(convId, userId) {
    const member = q1(this.db, 'SELECT last_read_msg_id FROM conversation_members WHERE conv_id=? AND user_id=?', convId, userId);
    const lastRead = member?.last_read_msg_id ?? 0;
    return q1(
      this.db,
      'SELECT COUNT(*) c FROM messages WHERE conv_id=? AND msg_id>? AND sender_id!=?',
      convId, lastRead, userId
    ).c;
  }

  sendMessage({ convId, senderId, msgType = 'text', content, clientMsgId }) {
    const dup = q1(
      this.db,
      'SELECT * FROM messages WHERE conv_id=? AND sender_id=? AND client_msg_id=?',
      convId, senderId, clientMsgId
    );
    if (dup) return { message: dup, duplicated: true };
    const info = run(
      this.db,
      'INSERT INTO messages(conv_id,sender_id,msg_type,content,client_msg_id,created_at) VALUES(?,?,?,?,?,?)',
      convId, senderId, msgType, content, clientMsgId, now()
    );
    return { message: q1(this.db, 'SELECT * FROM messages WHERE msg_id=?', Number(info.lastInsertRowid)), duplicated: false };
  }

  listMessages({ convId, cursor = null, limit = 20, userId = null }) {
    const cap = Math.trunc(Math.min(Math.max(1, limit), 50));
    const floor = this.clearedBefore(convId, userId);
    const rows = cursor
      ? q(this.db, 'SELECT * FROM messages WHERE conv_id=? AND msg_id>? AND msg_id<? ORDER BY msg_id DESC LIMIT ?', convId, floor, cursor, cap + 1)
      : q(this.db, 'SELECT * FROM messages WHERE conv_id=? AND msg_id>? ORDER BY msg_id DESC LIMIT ?', convId, floor, cap + 1);
    const hasMore = rows.length > cap;
    const items = rows.slice(0, cap);
    return { items, nextCursor: hasMore ? String(items[items.length - 1].msg_id) : null };
  }

  // 增量拉取（since_msg_id）：只返回 msg_id > sinceMsgId 的消息，正序，封顶 50
  listMessagesSince({ convId, sinceMsgId, limit = 50, userId = null }) {
    const cap = Math.trunc(Math.min(Math.max(1, limit), 50));
    return q(this.db, 'SELECT * FROM messages WHERE conv_id=? AND msg_id>? ORDER BY msg_id ASC LIMIT ?', convId, Math.max(sinceMsgId, this.clearedBefore(convId, userId)), cap);
  }

  markRead({ convId, userId, lastReadMsgId }) {
    // 已读位点只能指向当前会话中已经存在的消息，不能吞掉未来消息。
    const latest = this.lastMessage(convId)?.msg_id ?? 0;
    const bounded = Math.max(0, Math.min(lastReadMsgId ?? latest, latest));
    run(
      this.db,
      'UPDATE conversation_members SET last_read_msg_id = MAX(last_read_msg_id, ?) WHERE conv_id=? AND user_id=?',
      bounded, convId, userId
    );
  }

  // 撤回（契约 /messages/{msg_id}/recall）：仅发送者、2 分钟内；撤回即抹除内容
  recallMessage({ msgId, senderId, withinSec = 120 }) {
    const msg = q1(this.db, 'SELECT * FROM messages WHERE msg_id=?', msgId);
    if (!msg || msg.sender_id !== senderId) return null;
    if (msg.status === 'recalled') return msg;
    if (Date.now() - Date.parse(msg.created_at) > withinSec * 1000) return false;
    run(this.db, "UPDATE messages SET status='recalled', content=NULL WHERE msg_id=?", msgId);
    return q1(this.db, 'SELECT * FROM messages WHERE msg_id=?', msgId);
  }

  setConvSettings({ convId, userId, pinned, muted }) {
    const cur = q1(this.db, 'SELECT * FROM conversation_members WHERE conv_id=? AND user_id=?', convId, userId);
    if (!cur) return false;
    run(
      this.db,
      'UPDATE conversation_members SET is_pinned=?, is_muted=? WHERE conv_id=? AND user_id=?',
      pinned ?? cur.is_pinned, muted ?? cur.is_muted, convId, userId
    );
    return true;
  }
}

/**
 * 腾讯云 IM 适配器（预留空壳）。
 * TODO(M1 W2 选型评审)：接入腾讯云 IM 服务端 REST API——
 *   - 会话/消息写入改为调用 IM SDK 的 REST 接口（v4/im_open_login_svc 等）；
 *   - 消息漫游依赖 SDK 能力（会员「漫游时长」权益的底层依赖，V3.0 §11.2）；
 *   - 通信秘密边界（§16.4）：服务端回调只取元数据与端侧特征，不沉淀消息内容；
 *   - 离线推送走厂商通道（华为/小米/OPPO/vivo）。
 * 评审未通过前不得启用（计划书 §9 D3：备选融云双供应商）。
 */
export class TencentIMProvider {
  constructor() {
    throw new Error('TencentIMProvider 未实现：V0.9 使用 LocalIMProvider（DIMI_IM_PROVIDER=local）');
  }
}

export function getIMProvider(db, config = {}) {
  const kind = config.imProvider || process.env.DIMI_IM_PROVIDER || 'local';
  if (kind === 'tencent') return new TencentIMProvider(db, config);
  return new LocalIMProvider(db);
}
