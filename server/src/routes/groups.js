import { q, q1, run, audit } from '../repo.js';
import { ok, E } from '../http/respond.js';
import { now, hashPassword, verifyPassword, randomToken, hashToken } from '../util.js';
import { hitRate } from '../rate.js';

// 联系人分组 + 高隐私分组门禁（信任分层设计）：
// - 分组为本人视角的「加密文件夹」：高隐私分组的联系人在本人好友列表/资料卡中默认隐藏
// - 解锁 = 独立隐私密码换 5 分钟短时凭证（X-Group-Unlock 头），服务端把守而非客户端锁
// - 解锁尝试防爆：5 次失败锁 30 分钟；设置/解锁/查看全程审计
const UNLOCK_TTL_SEC = 300;
const UNLOCK_MAX_FAIL = 5;
const UNLOCK_LOCK_SEC = 1800;

export function hasGroupUnlock(db, ctx) {
  const token = ctx.req.headers['x-group-unlock'];
  if (!token) return false;
  const row = q1(
    db,
    'SELECT * FROM group_unlocks WHERE user_id=? AND token_hash=?',
    ctx.user.id, hashToken(String(token))
  );
  return !!row && row.expires_at > now();
}

// 目标用户在本人（viewer）的高隐私分组中且未解锁 → 需门禁
export function needsGroupUnlock(db, viewer, ownerId) {
  const rel = q1(
    db,
    `SELECT g.privacy_level FROM friendships f
     JOIN contact_groups g ON g.id = f.group_id
     WHERE f.user_id=? AND f.friend_id=? AND f.group_id IS NOT NULL`,
    viewer.id, ownerId
  );
  return rel?.privacy_level === 'high';
}

export function registerGroupRoutes(router, { db }) {
  // 设置/修改隐私密码（独立于登录体系；修改须验旧密码）
  router.put('/v1/privacy/password', { auth: true }, (ctx) => {
    const { password, old_password } = ctx.body || {};
    const cur = q1(db, 'SELECT privacy_password_hash FROM users WHERE id=?', ctx.user.id).privacy_password_hash;
    if (cur && !verifyPassword(old_password ?? '', cur)) throw E.param('原隐私密码错误');
    const pw = String(password ?? '');
    if (pw.length < 6 || pw.length > 64) throw E.param('隐私密码须 6–64 位');
    run(db, 'UPDATE users SET privacy_password_hash=?, updated_at=? WHERE id=?', hashPassword(pw), now(), ctx.user.id);
    run(db, 'DELETE FROM group_unlocks WHERE user_id=?', ctx.user.id);
    audit(db, { userId: ctx.user.id, event: 'privacy_password_set', input: { changed: !!cur } });
    return ok(ctx);
  });

  // 解锁高隐私分组：密码换短时凭证；5 次失败锁 30 分钟，成功清零计数
  router.post('/v1/privacy/groups/unlock', { auth: true }, (ctx) => {
    const failKey = `unlock_fail:${ctx.user.id}`;
    const fails = q1(db, 'SELECT count, reset_at FROM rate_counters WHERE key=?', failKey);
    if (fails && fails.reset_at > Date.now() && fails.count >= UNLOCK_MAX_FAIL) {
      throw E.rate('失败次数过多，已锁定 30 分钟');
    }
    const cur = q1(db, 'SELECT privacy_password_hash FROM users WHERE id=?', ctx.user.id).privacy_password_hash;
    if (!cur) throw E.param('尚未设置隐私密码');
    if (!verifyPassword(String(ctx.body?.password ?? ''), cur)) {
      hitRate(db, failKey, 9999, UNLOCK_LOCK_SEC);
      audit(db, { userId: ctx.user.id, event: 'group_unlock_fail' });
      throw E.param('隐私密码错误');
    }
    run(db, 'DELETE FROM rate_counters WHERE key=?', failKey);
    const token = randomToken(24);
    run(db, 'INSERT INTO group_unlocks(user_id,token_hash,expires_at,created_at) VALUES(?,?,?,?)',
      ctx.user.id, hashToken(token), new Date(Date.now() + UNLOCK_TTL_SEC * 1000).toISOString(), now());
    audit(db, { userId: ctx.user.id, event: 'group_unlock', output: { ttl_sec: UNLOCK_TTL_SEC } });
    return ok(ctx, { unlock_token: token, expires_in: UNLOCK_TTL_SEC });
  });

  // 主动锁定（立即作废全部解锁凭证）
  router.post('/v1/privacy/groups/lock', { auth: true }, (ctx) => {
    run(db, 'DELETE FROM group_unlocks WHERE user_id=?', ctx.user.id);
    audit(db, { userId: ctx.user.id, event: 'group_lock' });
    return ok(ctx);
  });

  // 分组 CRUD
  router.get('/v1/contact-groups', { auth: true }, (ctx) => {
    const rows = q(
      db,
      `SELECT g.*, (SELECT COUNT(*) FROM friendships f WHERE f.group_id=g.id) member_count
       FROM contact_groups g WHERE g.user_id=? ORDER BY g.sort, g.id`,
      ctx.user.id
    );
    return ok(ctx, {
      unlocked: hasGroupUnlock(db, ctx),
      items: rows.map((g) => ({
        group_id: g.id, name: g.name, privacy_level: g.privacy_level,
        // 未解锁时不暴露高隐私分组的成员数（防侧推）
        member_count: g.privacy_level === 'high' && !hasGroupUnlock(db, ctx) ? null : g.member_count,
      })),
    });
  });

  router.post('/v1/contact-groups', { auth: true }, (ctx) => {
    const { name, privacy_level = 'normal' } = ctx.body || {};
    if (!name || [...String(name)].length > 16) throw E.param('分组名必填且不超过 16 字');
    if (!['normal', 'high'].includes(privacy_level)) throw E.param('privacy_level 仅支持 normal / high');
    if (privacy_level === 'high') {
      const cur = q1(db, 'SELECT privacy_password_hash FROM users WHERE id=?', ctx.user.id).privacy_password_hash;
      if (!cur) throw E.param('请先在隐私设置中设置隐私密码');
    }
    if (q1(db, 'SELECT 1 x FROM contact_groups WHERE user_id=? AND name=?', ctx.user.id, String(name))) {
      throw E.param('分组名已存在');
    }
    const info = run(db, 'INSERT INTO contact_groups(user_id,name,privacy_level,created_at) VALUES(?,?,?,?)',
      ctx.user.id, String(name), privacy_level, now());
    audit(db, { userId: ctx.user.id, event: 'group_create', input: { name: String(name), privacy_level } });
    return ok(ctx, { group_id: Number(info.lastInsertRowid) });
  });

  router.put('/v1/contact-groups/:group_id', { auth: true }, (ctx) => {
    const g = q1(db, 'SELECT * FROM contact_groups WHERE id=? AND user_id=?', Number(ctx.params.group_id), ctx.user.id);
    if (!g) throw E.notFound('分组不存在');
    const { name, privacy_level } = ctx.body || {};
    if (g.privacy_level === 'high' && !hasGroupUnlock(db, ctx)) {
      throw E.privacy('高隐私分组须先解锁再操作', { locked: true });
    }
    if (name !== undefined && (typeof name !== 'string' || !name.trim() || [...name].length > 16)) {
      throw E.param('分组名必填且不超过 16 字');
    }
    if (privacy_level !== undefined && !['normal', 'high'].includes(privacy_level)) throw E.param('privacy_level 仅支持 normal / high');
    if (name !== undefined && q1(db, 'SELECT 1 x FROM contact_groups WHERE user_id=? AND name=? AND id!=?', ctx.user.id, name.trim(), g.id)) {
      throw E.param('分组名已存在');
    }
    if (privacy_level === 'high' && g.privacy_level !== 'high') {
      const cur = q1(db, 'SELECT privacy_password_hash FROM users WHERE id=?', ctx.user.id).privacy_password_hash;
      if (!cur) throw E.param('请先在隐私设置中设置隐私密码');
    }
    run(db, 'UPDATE contact_groups SET name=?, privacy_level=? WHERE id=?',
      name === undefined ? g.name : name.trim(),
      ['normal', 'high'].includes(privacy_level) ? privacy_level : g.privacy_level,
      g.id);
    audit(db, { userId: ctx.user.id, event: 'group_update', targetId: g.id });
    return ok(ctx);
  });

  router.delete('/v1/contact-groups/:group_id', { auth: true }, (ctx) => {
    const g = q1(db, 'SELECT * FROM contact_groups WHERE id=? AND user_id=?', Number(ctx.params.group_id), ctx.user.id);
    if (!g) throw E.notFound('分组不存在');
    // 高隐私分组删除需持有效解锁凭证（防他人拿手机直接删组曝光名单）
    if (g.privacy_level === 'high' && !hasGroupUnlock(db, ctx)) {
      throw E.privacy('高隐私分组须先解锁再操作', { locked: true });
    }
    run(db, 'UPDATE friendships SET group_id=NULL WHERE group_id=?', g.id);
    run(db, 'DELETE FROM contact_groups WHERE id=?', g.id);
    audit(db, { userId: ctx.user.id, event: 'group_delete', targetId: g.id });
    return ok(ctx);
  });

  // 好友移入/移出分组
  router.put('/v1/friends/:friend_id/group', { auth: true }, (ctx) => {
    const fid = Number(ctx.params.friend_id);
    const rel = q1(db, 'SELECT * FROM friendships WHERE user_id=? AND friend_id=?', ctx.user.id, fid);
    if (!rel) throw E.notFound('好友关系不存在');
    if (needsGroupUnlock(db, ctx.user, fid) && !hasGroupUnlock(db, ctx)) {
      throw E.privacy('高隐私分组须先解锁再操作', { locked: true });
    }
    const { group_id } = ctx.body || {};
    if (group_id === null) {
      run(db, 'UPDATE friendships SET group_id=NULL WHERE user_id=? AND friend_id=?', ctx.user.id, fid);
    } else {
      const g = q1(db, 'SELECT * FROM contact_groups WHERE id=? AND user_id=?', Number(group_id), ctx.user.id);
      if (!g) throw E.notFound('分组不存在');
      run(db, 'UPDATE friendships SET group_id=? WHERE user_id=? AND friend_id=?', g.id, ctx.user.id, fid);
    }
    audit(db, { userId: ctx.user.id, event: 'friend_group_move', targetId: fid, input: { group_id: group_id ?? null } });
    return ok(ctx);
  });
}
