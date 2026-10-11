import { q, q1, run, audit, getUser, getPrivacy, isFriend, isBlockedBetween } from '../repo.js';
import { ok, E } from '../http/respond.js';
import { isInt, now } from '../util.js';
import { rules, resolveUserView, containsContactInfo, runPeerVerificationUpgrade } from '../engine/index.js';
import { hitRate } from '../rate.js';
import { toUserBrief } from './users.js';
import { getIMProvider } from '../im/provider.js';
import { hasGroupUnlock } from './groups.js';
import { grantTask, withTx } from '../coins.js';

const SOURCE_TO_ADD_VIA = {
  classmate_search: 'school_search',
  fellow_search: 'hometown_search',
  dimi_no: 'dimi_no',
  phone: 'phone',
  group: 'group',
  business_card: 'business_card',
  contact_match: 'contact_match',
};

// 好友申请处理链（§22.2 写路径）：黑名单互查 → 频控 → 内容安全 → 交集快照冻结 → 落库
// 幂等：Idempotency-Key 已由 app.js 通用幂等层统一处理（键按用户隔离，重放返回缓存响应）
export function registerFriendRoutes(router, { db, config }) {
  router.post('/v1/friends/requests', { auth: true }, (ctx) => {
    const { to_user_id, verify_msg, attach_real_name = true, attach_education = false, source = 'classmate_search' } = ctx.body || {};
    if (!isInt(to_user_id)) throw E.param('to_user_id 必填');
    const target = getUser(db, Number(to_user_id));
    if (!target || target.status !== 1) throw E.notFound('用户不存在');
    if (target.id === ctx.user.id) throw E.param('不能添加自己为好友');
    if (!Object.hasOwn(SOURCE_TO_ADD_VIA, source)) throw E.param('source 不合法');
    run(db, "UPDATE friend_requests SET status='expired' WHERE status='pending' AND expire_at<=? AND from_user=? AND to_user=?", now(), ctx.user.id, target.id);
    // 验证语必填 ≤50 字（§8.2.1）
    if (!verify_msg || ![...String(verify_msg)].length || [...String(verify_msg)].length > 50) {
      throw E.param('验证语必填且不超过 50 字');
    }
    // 内容安全：联系方式模式一律拦截（§20.5）→ 45001
    if (containsContactInfo(verify_msg)) {
      audit(db, { userId: ctx.user.id, event: 'friend_request_blocked', targetId: target.id, input: { verify_msg } });
      throw E.content(rules.content_safety.blocked_message);
    }
    // 黑名单互查：任一方向拉黑 → 静默返回成功防探测（§22.2 [1]）
    if (isBlockedBetween(db, ctx.user.id, target.id)) return ok(ctx, { request_id: null });
    if (isFriend(db, ctx.user.id, target.id)) throw E.param('你们已经是好友');
    const rl = rules.rate_limit;
    const pending = q1(
      db,
      "SELECT id FROM friend_requests WHERE from_user=? AND to_user=? AND status='pending'",
      ctx.user.id, target.id
    );
    if (pending) return ok(ctx, { request_id: pending.id, duplicated: true });
    const rejected = q1(
      db,
      "SELECT created_at FROM friend_requests WHERE from_user=? AND to_user=? AND status='rejected' ORDER BY id DESC LIMIT 1",
      ctx.user.id, target.id
    );
    if (rejected && Date.now() - Date.parse(rejected.created_at) < rl.friend_reject_block_days * 86400 * 1000) {
      throw E.privacy('对方暂未通过你的申请，请 30 天后再试');
    }
    // 频控：日发 ≤30；同人 3 次/30 日（§22.4）
    const day = new Date().toISOString().slice(0, 10);
    if (!hitRate(db, `freq:${ctx.user.id}:${day}`, rl.friend_request_daily, 86400).allowed) {
      throw E.rate('今日申请次数已达上限');
    }
    const sameTarget = q1(
      db,
      'SELECT COUNT(*) c FROM friend_requests WHERE from_user=? AND to_user=? AND created_at>?',
      ctx.user.id, target.id, new Date(Date.now() - 30 * 86400 * 1000).toISOString()
    ).c;
    if (sameTarget >= rl.friend_request_same_target_30d) throw E.rate('对同一用户 30 天内最多申请 3 次');
    // 添加方式开关（§11.2）
    const addViaKey = SOURCE_TO_ADD_VIA[source];
    if (addViaKey && getPrivacy(db, target).add_me_via[addViaKey] === false) throw E.privacy();
    // 交集快照冻结（§22.2 [4]，防通过后改经历伪造同班）
    const view = resolveUserView(db, ctx.user, target, { scene: 'friend_request' });
    const snapshot = view.banner || view.reason || null;
    const expireAt = new Date(Date.now() + rl.friend_request_expire_days * 86400 * 1000).toISOString();
    const info = run(
      db,
      `INSERT INTO friend_requests(from_user,to_user,verify_msg,attach_real_name,attach_education,source,intersection_snapshot,status,expire_at,created_at)
       VALUES(?,?,?,?,?,?,?,'pending',?,?)`,
      ctx.user.id, target.id, String(verify_msg), attach_real_name ? 1 : 0, attach_education ? 1 : 0,
      String(source), snapshot, expireAt, now()
    );
    const data = { request_id: Number(info.lastInsertRowid) };
    audit(db, { userId: ctx.user.id, event: 'friend_request', targetId: target.id, input: { source }, output: data });
    return ok(ctx, data);
  });

  router.get('/v1/friends/requests', { auth: true }, (ctx) => {
    run(db, "UPDATE friend_requests SET status='expired' WHERE status='pending' AND expire_at<=? AND (from_user=? OR to_user=?)", now(), ctx.user.id, ctx.user.id);
    const box = ctx.query.box === 'outbox' ? 'outbox' : 'inbox';
    const cursor = isInt(ctx.query.cursor) ? Number(ctx.query.cursor) : null;
    const limit = 20;
    const rows = box === 'inbox'
      ? q(db, `SELECT * FROM friend_requests WHERE to_user=? ${cursor ? 'AND id<?' : ''} ORDER BY id DESC LIMIT ?`, ...[ctx.user.id, ...(cursor ? [cursor] : []), limit + 1])
      : q(db, `SELECT * FROM friend_requests WHERE from_user=? ${cursor ? 'AND id<?' : ''} ORDER BY id DESC LIMIT ?`, ...[ctx.user.id, ...(cursor ? [cursor] : []), limit + 1]);
    const hasMore = rows.length > limit;
    const items = rows.slice(0, limit).map((r) => {
      const otherId = box === 'inbox' ? r.from_user : r.to_user;
      const other = getUser(db, otherId);
      const brief = other
        ? toUserBrief(db, ctx.user, other, {
            scene: 'friend_request_list',
            // 钥匙式披露（§5.2.6）：收件箱中申请人 attach_real_name=1 → 真名定向披露给被申请人
            forceFullName: box === 'inbox' && !!r.attach_real_name,
          })
        : null;
      return {
        id: r.id,
        from_user: brief,
        from_user_id: r.from_user,
        to_user_id: r.to_user,
        verify_msg: r.verify_msg,
        attach_real_name: !!r.attach_real_name,
        attach_education: !!r.attach_education,
        intersection_snapshot: r.intersection_snapshot,
        status: r.status,
        expire_at: r.expire_at,
      };
    });
    return ok(ctx, { items, next_cursor: hasMore ? String(items[items.length - 1].id) : null });
  });

  router.post('/v1/friends/requests/:request_id/accept', { auth: true }, (ctx) => {
    const req = q1(db, 'SELECT * FROM friend_requests WHERE id=?', Number(ctx.params.request_id));
    if (!req || req.to_user !== ctx.user.id) throw E.notFound('申请不存在');
    if (req.status !== 'pending') throw E.param('申请已处理或已过期');
    const applicant = getUser(db, req.from_user);
    if (!applicant || applicant.status !== 1 || isBlockedBetween(db, req.from_user, req.to_user)) {
      throw E.privacy('当前无法通过该好友申请');
    }
    if (req.expire_at && req.expire_at <= now()) {
      run(db, "UPDATE friend_requests SET status='expired' WHERE id=?", req.id);
      throw E.param('申请已过期');
    }
    // 好友通过多步写打包事务：改状态→双向 friendships→建会话→破冰消息→互证→发币
    // （任一步失败整体回滚，防半开通状态；grantTask 幂等，留在事务内）
    const { conv, upgradedFrom, upgradedTo } = withTx(db, () => {
      run(db, "UPDATE friend_requests SET status='accepted' WHERE id=?", req.id);
      const ts = now();
      run(db, 'INSERT OR IGNORE INTO friendships(user_id,friend_id,source,created_at) VALUES(?,?,?,?)', req.from_user, req.to_user, req.source, ts);
      run(db, 'INSERT OR IGNORE INTO friendships(user_id,friend_id,source,created_at) VALUES(?,?,?,?)', req.to_user, req.from_user, req.source, ts);
      // 自动打开聊天窗 + 破冰系统消息（§8.2 [7]-[9]，用冻结快照）
      const im = getIMProvider(db, config);
      const conv = im.getOrCreateSingleConversation(req.from_user, req.to_user);
      im.sendMessage({
        convId: conv.conv_id, senderId: req.to_user, msgType: 'system',
        content: JSON.stringify({ type: 'ice_breaker', banner: req.intersection_snapshot || '你们已经成为好友，打个招呼吧' }),
        clientMsgId: `icebreaker-${req.id}`,
      });
      // V1 同窗互证自动升级（双方各检查一次）
      const upgradedFrom = runPeerVerificationUpgrade(db, req.from_user);
      const upgradedTo = runPeerVerificationUpgrade(db, req.to_user);
      // 成功添加好友：申请人 +30（P0 纯赠送，每目标一次幂等）
      grantTask(db, req.from_user, 'friend_accept', { targetId: req.to_user });
      return { conv, upgradedFrom, upgradedTo };
    });
    audit(db, { userId: ctx.user.id, event: 'friend_accept', targetId: req.from_user, output: { conversation_id: conv.conv_id, upgraded: { from: upgradedFrom, to: upgradedTo } } });
    return ok(ctx, { conversation_id: conv.conv_id });
  });

  router.post('/v1/friends/requests/:request_id/reject', { auth: true }, (ctx) => {
    const req = q1(db, 'SELECT * FROM friend_requests WHERE id=?', Number(ctx.params.request_id));
    if (!req || req.to_user !== ctx.user.id) throw E.notFound('申请不存在');
    if (req.status !== 'pending') throw E.param('申请已处理');
    // 拒绝不通知对方，30 天内对方不可再申请（§8.2.1）
    run(db, "UPDATE friend_requests SET status='rejected' WHERE id=?", req.id);
    audit(db, { userId: ctx.user.id, event: 'friend_reject', targetId: req.from_user });
    return ok(ctx);
  });

  router.get('/v1/friends', { auth: true }, (ctx) => {
    const cursor = isInt(ctx.query.cursor) ? Number(ctx.query.cursor) : null;
    const limit = 50;
    // 注销/停用好友（u.status!=1）在 SQL 层即剔除，不再占分页窗口与游标位点
    const rows = q(
      db,
      `SELECT f.*, g.privacy_level group_level FROM friendships f
       JOIN users u ON u.id=f.friend_id AND u.status=1
       LEFT JOIN contact_groups g ON g.id=f.group_id
       WHERE f.user_id=? ${cursor ? 'AND f.friend_id<?' : ''} ORDER BY f.friend_id DESC LIMIT ?`,
      ...[ctx.user.id, ...(cursor ? [cursor] : []), limit + 1]
    );
    const hasMore = rows.length > limit;
    // 高隐私分组门禁：未解锁时高隐私分组联系人不出现在列表，仅报锁定数量
    const unlocked = hasGroupUnlock(db, ctx);
    const visible = rows.slice(0, limit);
    const lockedCount = visible.filter((r) => r.group_level === 'high').length;
    let items = visible
      .filter((r) => unlocked || r.group_level !== 'high')
      .map((r) => {
        const owner = getUser(db, r.friend_id);
        const brief = toUserBrief(db, ctx.user, owner, { scene: 'friend_list' });
        return { ...brief, remark_name: r.remark_name, tags: JSON.parse(r.tags || '[]'), is_starred: !!r.is_starred, group_id: r.group_id ?? null };
      });
    // 契约 tag 筛选参数：按好友标签过滤
    const tag = ctx.query.tag ? String(ctx.query.tag) : null;
    if (tag) items = items.filter((i) => i.tags.includes(tag));
    // 游标基于过滤前最后一行（friend_id 递减）：高隐私分组未解锁/tag 过滤会截短 items，
    // 若取过滤后末项作游标会跳过中间数据造成提前 null 截断
    return ok(ctx, {
      items,
      next_cursor: hasMore && visible.length ? String(visible[visible.length - 1].friend_id) : null,
      unlocked,
      locked_count: unlocked ? 0 : lockedCount,
    });
  });

  router.delete('/v1/friends/:friend_id', { auth: true }, (ctx) => {
    // 单向删除，对齐微信（§8.4）
    const info = run(db, 'DELETE FROM friendships WHERE user_id=? AND friend_id=?', ctx.user.id, Number(ctx.params.friend_id));
    if (!info.changes) throw E.notFound('好友关系不存在');
    audit(db, { userId: ctx.user.id, event: 'friend_delete', targetId: Number(ctx.params.friend_id) });
    return ok(ctx);
  });

  // 备注/标签/星标写入（契约 PUT /friends/{friend_id}）
  router.put('/v1/friends/:friend_id', { auth: true }, (ctx) => {
    const fid = Number(ctx.params.friend_id);
    const rel = q1(db, 'SELECT * FROM friendships WHERE user_id=? AND friend_id=?', ctx.user.id, fid);
    if (!rel) throw E.notFound('好友关系不存在');
    const { remark_name, tags, is_starred } = ctx.body || {};
    if (remark_name !== undefined && remark_name !== null && [...String(remark_name)].length > 32) {
      throw E.param('备注名不超过 32 字');
    }
    if (tags !== undefined && (!Array.isArray(tags) || tags.length > 8 || tags.some((t) => [...String(t)].length > 16))) {
      throw E.param('tags 须为不超过 8 个、单个不超 16 字的数组');
    }
    run(
      db,
      'UPDATE friendships SET remark_name=?, tags=?, is_starred=? WHERE user_id=? AND friend_id=?',
      remark_name === undefined ? rel.remark_name : (remark_name === null ? null : String(remark_name)),
      tags === undefined ? rel.tags : JSON.stringify(tags.map(String)),
      is_starred === undefined ? rel.is_starred : (is_starred ? 1 : 0),
      ctx.user.id, fid
    );
    audit(db, { userId: ctx.user.id, event: 'friend_update', targetId: fid });
    return ok(ctx);
  });

  // 拉黑/移出黑名单（§8.1 双向断联：互相不可检索/不可消息，由 isBlockedBetween 全链路施加）
  router.post('/v1/friends/:friend_id/block', { auth: true }, (ctx) => {
    const fid = Number(ctx.params.friend_id);
    if (!getUser(db, fid)) throw E.notFound('用户不存在');
    if (fid === ctx.user.id) throw E.param('不能拉黑自己');
    run(db, 'INSERT OR IGNORE INTO blocks(user_id,blocked_id,created_at) VALUES(?,?,?)', ctx.user.id, fid, now());
    audit(db, { userId: ctx.user.id, event: 'block', targetId: fid });
    return ok(ctx);
  });

  // 黑名单列表（管理闭环：拉黑后可在此查看/解除）
  router.get('/v1/friends/blocks', { auth: true }, (ctx) => {
    const rows = q(
      db,
      'SELECT b.blocked_id, b.created_at FROM blocks b WHERE b.user_id=? ORDER BY b.created_at DESC',
      ctx.user.id
    );
    const items = rows.map((r) => {
      const u = getUser(db, r.blocked_id);
      if (!u) return null;
      return { ...toUserBrief(db, ctx.user, u, { scene: 'brief' }), blocked_at: r.created_at };
    }).filter(Boolean);
    return ok(ctx, { items });
  });

  router.delete('/v1/friends/:friend_id/block', { auth: true }, (ctx) => {
    const fid = Number(ctx.params.friend_id);
    const info = run(db, 'DELETE FROM blocks WHERE user_id=? AND blocked_id=?', ctx.user.id, fid);
    if (!info.changes) throw E.notFound('黑名单记录不存在');
    audit(db, { userId: ctx.user.id, event: 'unblock', targetId: fid });
    return ok(ctx);
  });
}
