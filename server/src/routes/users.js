import { q, q1, run, audit, getUser, getPrivacy, relationBetween, regionChain } from '../repo.js';
import { ok, E } from '../http/respond.js';
import { now, normalizeClassName, isInt, ageOf } from '../util.js';
import { rules, resolveUserView } from '../engine/index.js';
import { selfView } from './auth.js';
import { hasGroupUnlock, needsGroupUnlock } from './groups.js';
import { grantTask } from '../coins.js';
import { getIMProvider } from '../im/provider.js';

const STAGES = ['PRIMARY', 'MIDDLE', 'HIGH', 'VOCATIONAL', 'UNIVERSITY', 'POSTGRADUATE'];
const VISIBILITIES = ['public', 'friends', 'fellows_only', 'private'];

// 与 owner 存在同乡交集（籍贯同市，前 4 位前缀一致；与 moments.js sharesHometown 同口径）
function sharesHometown(db, a, b) {
  const ha = q1(db, 'SELECT region_code FROM user_hometowns WHERE user_id=? AND type=1', a);
  const hb = q1(db, 'SELECT region_code FROM user_hometowns WHERE user_id=? AND type=1', b);
  if (!ha || !hb) return false;
  return String(ha.region_code).slice(0, 4) === String(hb.region_code).slice(0, 4);
}

// UserBrief：所有返回用户对象的出口统一过渐显中间件（resolveUserView）
export function toUserBrief(db, viewer, ownerRow, opts = {}) {
  const view = resolveUserView(db, viewer, ownerRow, { scene: opts.scene || 'brief', forceFullName: opts.forceFullName });
  return {
    user_id: ownerRow.id,
    nickname: ownerRow.nickname,
    real_name: view.realName,
    avatar_url: ownerRow.avatar_url ?? null,
    relation: relationBetween(db, viewer.id, ownerRow.id),
    intersection_tier: view.displayTier,
    match_tags: view.tags,
    mutual_friends: view.mutual,
    reason: view.reason,
  };
}

function eduOut(row) {
  return {
    id: row.id,
    stage: row.stage,
    school_id: row.school_id,
    school_name: row.school_name_snapshot,
    enroll_year: row.enroll_year,
    class_name_raw: row.class_name_raw,
    class_name_norm: row.class_name_norm,
    department: row.department,
    major: row.major,
    verification_level: row.verification_level,
    verified_at: row.verified_at,
    verification_source: row.verification_source,
    visibility: row.visibility,
  };
}

function registeredCount(db, { school_id, enroll_year, class_name_norm }, excludeUserId) {
  if (class_name_norm) {
    return q1(
      db,
      'SELECT COUNT(DISTINCT user_id) c FROM education_experiences WHERE school_id=? AND enroll_year=? AND class_name_norm=? AND user_id!=?',
      school_id, enroll_year, class_name_norm, excludeUserId
    ).c;
  }
  return q1(
    db,
    'SELECT COUNT(DISTINCT user_id) c FROM education_experiences WHERE school_id=? AND enroll_year=? AND user_id!=?',
    school_id, enroll_year, excludeUserId
  ).c;
}

export function registerUserRoutes(router, { db, storage, config }) {
  router.get('/v1/users/me', { auth: true }, (ctx) => ok(ctx, selfView(db, ctx.user)));

  // 独立于资料编辑；旧号保留归属以免改号后被冒认，但不再用于搜索。
  router.put('/v1/users/me/dimi-no', { auth: true }, (ctx) => {
    const input = ctx.body?.dimi_no;
    if (typeof input !== 'string') throw E.param('请输入 DIMI 号');
    const value = input.trim().toLowerCase();
    db.exec('BEGIN IMMEDIATE');
    try {
      // 在写事务内读取修改时间，多个进程同时改号时也遵守修改间隔。
      const user = getUser(db, ctx.user.id);
      if (value === user.dimi_no?.toLowerCase()) {
        db.exec('COMMIT');
        return ok(ctx, selfView(db, user));
      }
      if (!/^[a-z][a-z0-9_-]{5,19}$/.test(value) || /^dm\d+$/i.test(value)) {
        throw E.param('以字母开头，6–20 位字母、数字、下划线或短横线；DM 纯数字号为系统保留');
      }
      if (user.dimi_no_changed_at && Date.now() - Date.parse(user.dimi_no_changed_at) < 365 * 86400000) {
        throw E.param('DIMI 号每 365 天可修改一次');
      }
      const taken = q1(db, 'SELECT id FROM users WHERE dimi_no=? COLLATE NOCASE AND id!=?', value, user.id);
      const claimed = q1(db, 'SELECT user_id FROM dimi_no_claims WHERE dimi_no=?', value);
      if (taken || (claimed && claimed.user_id !== user.id)) throw E.param('这个 DIMI 号已被使用，请换一个');
      const timestamp = now();
      if (user.dimi_no) run(db, 'INSERT OR IGNORE INTO dimi_no_claims(dimi_no,user_id,created_at) VALUES(?,?,?)', user.dimi_no, user.id, timestamp);
      run(db, 'INSERT OR IGNORE INTO dimi_no_claims(dimi_no,user_id,created_at) VALUES(?,?,?)', value, user.id, timestamp);
      run(db, 'UPDATE users SET dimi_no=?, dimi_no_changed_at=?, updated_at=? WHERE id=?', value, timestamp, timestamp, user.id);
      audit(db, { userId: user.id, event: 'dimi_no_update' });
      db.exec('COMMIT');
    } catch (error) {
      db.exec('ROLLBACK');
      throw error;
    }
    return ok(ctx, selfView(db, getUser(db, ctx.user.id)));
  });

  // 联系方式分项可见范围（契约 /users/me/contacts-visibility，§20.2 四档，默认仅自己）
  router.put('/v1/users/me/contacts-visibility', { auth: true }, (ctx) => {
    const LEVELS = ['self', 'friends', 'verified_friends', 'strong_tier'];
    const body = ctx.body || {};
    const cur = JSON.parse(q1(db, 'SELECT contacts_visibility FROM privacy_settings WHERE user_id=?', ctx.user.id)?.contacts_visibility || '{}');
    for (const k of ['phone', 'wechat', 'email']) {
      if (body[k] !== undefined) {
        if (!LEVELS.includes(body[k])) throw E.param(`${k} 可见范围仅支持 ${LEVELS.join('/')}`);
        cur[k] = body[k];
      }
    }
    run(db, 'INSERT OR IGNORE INTO privacy_settings(user_id) VALUES(?)', ctx.user.id);
    run(db, 'UPDATE privacy_settings SET contacts_visibility=? WHERE user_id=?', JSON.stringify(cur), ctx.user.id);
    audit(db, { userId: ctx.user.id, event: 'contacts_visibility_update', input: cur });
    return ok(ctx, { contacts_visibility: { phone: 'self', wechat: 'self', email: 'self', ...cur } });
  });

  router.get('/v1/users/me/contacts-visibility', { auth: true }, (ctx) => {
    const cur = JSON.parse(q1(db, 'SELECT contacts_visibility FROM privacy_settings WHERE user_id=?', ctx.user.id)?.contacts_visibility || '{}');
    return ok(ctx, { contacts_visibility: { phone: 'self', wechat: 'self', email: 'self', ...cur } });
  });

  // 谁看过我的联系方式（契约 /users/me/contact-viewers，审计回看，§20.7 双向透明；仅近 30 天）
  router.get('/v1/users/me/contact-viewers', { auth: true }, (ctx) => {
    const since = new Date(Date.now() - 30 * 86400 * 1000).toISOString();
    const rows = q(
      db,
      "SELECT user_id, created_at FROM audit_logs WHERE event='contact_view' AND target_id=? AND created_at>? ORDER BY id DESC LIMIT 100",
      ctx.user.id, since
    );
    return ok(ctx, {
      items: rows.map((r) => {
        const u = getUser(db, r.user_id);
        return u ? { ...toUserBrief(db, ctx.user, u, { scene: 'brief' }), viewed_at: r.created_at } : null;
      }).filter(Boolean),
    });
  });

  router.put('/v1/users/me', { auth: true }, (ctx) => {
    const { nickname, real_name, avatar_url, avatar_media_id, gender, birth_year, signature, moment_cover } = ctx.body || {};
    const sets = [];
    const vals = [];
    if (nickname !== undefined) {
      if (!nickname || [...String(nickname)].length > 32) throw E.param('昵称必填且不超过 32 字');
      sets.push('nickname=?'); vals.push(String(nickname));
    }
    if (real_name !== undefined) {
      // 真名每年限改 1 次（§5.2.7 防冒名）
      if (!real_name || [...String(real_name)].length > 32) throw E.param('real_name 必填且不超过 32 字');
      const last = ctx.user.real_name_changed_at;
      if (last && ctx.user.real_name && ctx.user.real_name !== real_name &&
          Date.now() - Date.parse(last) < rules.register.real_name_change_days * 86400 * 1000) {
        throw E.param('真名每年限改 1 次');
      }
      if (ctx.user.real_name !== real_name) {
        sets.push('real_name=?', 'real_name_changed_at=?'); vals.push(String(real_name), now());
      } else {
        sets.push('real_name=?'); vals.push(String(real_name));
      }
    }
    // 头像：契约字段 avatar_url，取 /misc/upload 返回的媒体 url 原样写入（local 为 /media/ 相对
    // 路径，oss 为绝对公网 URL，经 storage 分层校验）；
    // avatar_media_id 为旧字段名，保留兼容（同样按 url 处理），新客户端请用 avatar_url
    const avatar = avatar_url ?? avatar_media_id;
    if (avatar !== undefined) {
      if (!storage.isValidMediaUrl(avatar)) {
        throw E.param('avatar_url 须为 /misc/upload 返回的媒体 url（jpg/jpeg/png/webp）');
      }
      sets.push('avatar_url=?'); vals.push(String(avatar));
    }
    if (gender !== undefined) {
      if (![0, 1, 2].includes(Number(gender))) throw E.param('gender 仅支持 0/1/2');
      sets.push('gender=?'); vals.push(Number(gender));
    }
    if (birth_year !== undefined) {
      // 出生年份复用注册同款区间校验（未成年人边界，V3.1 A3 / 计划书 §4）；null 表示清除
      if (birth_year !== null) {
        const age = ageOf(birth_year);
        if (age < rules.register.min_age) throw E.param('未满 14 周岁不予注册');
        if (age < rules.register.minor_max_age) throw E.param('本产品暂不支持 14–18 周岁用户注册（未成年人模式尚未开放）');
        if (!/^\d{4}$/.test(String(birth_year))) throw E.param('birth_year 格式不正确');
      }
      sets.push('birth_year=?'); vals.push(birth_year === null ? null : Number(birth_year));
    }
    if (signature !== undefined) {
      if ([...String(signature)].length > 60) throw E.param('签名不超过 60 字');
      sets.push('signature=?'); vals.push(String(signature));
    }
    // 朋友圈封面：与头像同口径取 /misc/upload 返回的媒体 url（经 storage 分层校验），null 表示清除
    if (moment_cover !== undefined) {
      if (moment_cover !== null && !storage.isValidMediaUrl(moment_cover)) {
        throw E.param('moment_cover 须为 /misc/upload 返回的媒体 url（jpg/jpeg/png/webp）');
      }
      sets.push('moment_cover=?'); vals.push(moment_cover === null ? null : String(moment_cover));
      audit(db, { userId: ctx.user.id, event: 'moment_cover_update', input: { moment_cover } });
    }
    if (!sets.length) throw E.param('没有可更新的字段');
    sets.push('updated_at=?'); vals.push(now());
    run(db, `UPDATE users SET ${sets.join(',')} WHERE id=?`, ...vals, ctx.user.id);
    return ok(ctx);
  });

  router.get('/v1/users/:user_id', { auth: true }, (ctx) => {
    if (!isInt(ctx.params.user_id)) throw E.param('user_id 格式不正确');
    const owner = getUser(db, Number(ctx.params.user_id));
    if (!owner || owner.status !== 1) throw E.notFound('用户不存在');
    if (owner.id === ctx.user.id) return ok(ctx, selfView(db, owner));
    // 高隐私分组门禁：对方在本人高隐私分组中且未解锁 → 不暴露资料
    if (needsGroupUnlock(db, ctx.user, owner.id) && !hasGroupUnlock(db, ctx)) {
      throw E.privacy('该联系人在你的高隐私分组中，输入隐私密码后查看', { locked: true });
    }
    const view = resolveUserView(db, ctx.user, owner, { scene: 'profile' });
    if (view.blocked) throw E.privacy();
    const privacy = getPrivacy(db, owner);
    const friend = view.tier === 'FRIEND';
    // 经历可见性：不满足可见性的字段整块缺省（OpenAPI UserCard 约定）
    const edus = q(db, 'SELECT * FROM education_experiences WHERE user_id=?', owner.id).filter((e) => {
      if (e.visibility === 'private') return false;
      if (e.visibility === 'friends') return friend;
      if (e.visibility === 'fellows_only') return friend || view.displayTier === 'T3' || view.displayTier === 'T2';
      return true;
    });
    const card = {
      ...toUserBrief(db, ctx.user, owner, { scene: 'profile' }),
      signature: owner.signature ?? null,
      moment_cover: owner.moment_cover ?? null,
      relation: relationBetween(db, ctx.user.id, owner.id),
      educations: edus.map(eduOut),
      intersection_banner: view.banner,
      cross_experiences: view.tags.length ? [`你们还有 ${view.tags.join('、')} 交集`] : [],
      can_view_moments: friend || !!privacy.stranger_moments_10,
    };
    // 家乡展示门禁分档（§5.2.4；OpenAPI Visibility 四档，双入口取更严）：
    // user_hometowns.visibility / privacy_settings.hometown_visibility 任一为 private → 不可见；
    // friends → 仅好友；fellows_only → 好友或同乡（同市前缀）；public → 走交集深度降级（T0 缺省）。
    // 满足门禁后按 displayTier 降级粒度：T3/FRIEND 精确到镇 / T2 到县 / T1 及以下到市
    const ht = q1(db, 'SELECT * FROM user_hometowns WHERE user_id=? AND type=1', owner.id);
    // 双入口取更严档（严格度 private > friends > fellows_only > public）
    const STRICTNESS = { public: 0, fellows_only: 1, friends: 2, private: 3 };
    const recVis = ht?.visibility ?? 'public';
    const gateVis = (STRICTNESS[privacy.hometown_visibility] ?? 0) > (STRICTNESS[recVis] ?? 0)
      ? privacy.hometown_visibility
      : recVis;
    const friendTier = view.tier === 'FRIEND';
    const hometownAllowed =
      gateVis === 'public' ? view.displayTier !== 'T0'
      : gateVis === 'friends' ? friendTier
      : gateVis === 'fellows_only' ? (friendTier || sharesHometown(db, ctx.user.id, owner.id))
      : false; // private：不可见
    if (ht && hometownAllowed) {
      const chain = regionChain(db, ht.region_code);
      const depth = view.displayTier === 'FRIEND' || view.displayTier === 'T3' ? 4 : view.displayTier === 'T2' ? 3 : 2;
      card.hometown_display = chain.filter((r) => r.level <= depth).map((r) => r.name).join('');
      // 家乡页跳转码仅随镇级展示（depth=4）下发，低粒度档位只读文字——
      // 避免 T1/T2 访客经家乡页反推出精确镇（家乡页服务端仅接受镇级 code）
      if (depth === 4) card.hometown_region_code = ht.region_code;
    }
    audit(db, { userId: ctx.user.id, event: 'view_profile', targetId: owner.id, output: { tier: view.displayTier } });
    return ok(ctx, card);
  });

  // ---------- Educations ----------
  router.get('/v1/users/me/educations', { auth: true }, (ctx) => {
    const items = q(db, 'SELECT * FROM education_experiences WHERE user_id=? ORDER BY enroll_year', ctx.user.id);
    return ok(ctx, { items: items.map(eduOut) });
  });

  router.post('/v1/users/me/educations', { auth: true }, (ctx) => {
    const { stage, school_id, school_name_snapshot, enroll_year, class_name, department, major, visibility = 'public' } = ctx.body || {};
    if (!STAGES.includes(stage)) throw E.param('stage 不合法');
    if (!isInt(school_id)) throw E.param('school_id 必填');
    const school = q1(db, 'SELECT * FROM schools WHERE school_id=?', Number(school_id));
    if (!school) throw E.notFound('学校不存在，可先申请共建');
    const year = Number(enroll_year);
    const curYear = new Date().getFullYear();
    if (!Number.isInteger(year) || year < curYear - 70 || year > curYear) throw E.param('enroll_year 超出合法区间');
    if (!VISIBILITIES.includes(visibility)) throw E.param('visibility 不合法');
    const classNorm = normalizeClassName(class_name);
    const exists = q1(
      db,
      'SELECT 1 x FROM education_experiences WHERE user_id=? AND school_id=? AND enroll_year=? AND stage=? AND class_name_norm=?',
      ctx.user.id, school.school_id, year, stage, classNorm
    );
    if (exists) throw E.param('该段经历已存在');
    const info = run(
      db,
      `INSERT INTO education_experiences(user_id,stage,school_id,school_name_snapshot,enroll_year,class_name_raw,class_name_norm,department,major,visibility,created_at)
       VALUES(?,?,?,?,?,?,?,?,?,?,?)`,
      ctx.user.id, stage, school.school_id, school_name_snapshot || school.name, year,
      class_name ? String(class_name) : null, classNorm, department ?? null, major ?? null, visibility, now()
    );
    const row = q1(db, 'SELECT * FROM education_experiences WHERE id=?', Number(info.lastInsertRowid));
    grantTask(db, ctx.user.id, 'edu_complete'); // 完善首条教育经历 +10（P0 纯赠送，幂等一次性）
    return ok(ctx, { education: eduOut(row), registered_count: registeredCount(db, row, ctx.user.id) });
  });

  router.put('/v1/users/me/educations/:education_id', { auth: true }, (ctx) => {
    const row = q1(db, 'SELECT * FROM education_experiences WHERE id=? AND user_id=?', Number(ctx.params.education_id), ctx.user.id);
    if (!row) throw E.notFound('经历不存在');
    const { class_name, visibility, department, major, school_name_snapshot } = ctx.body || {};
    const sets = [];
    const vals = [];
    if (class_name !== undefined) {
      const norm = normalizeClassName(class_name);
      if (q1(db, 'SELECT 1 x FROM education_experiences WHERE user_id=? AND school_id=? AND enroll_year=? AND stage=? AND class_name_norm=? AND id!=?',
        ctx.user.id, row.school_id, row.enroll_year, row.stage, norm, row.id)) throw E.param('该段经历已存在');
      sets.push('class_name_raw=?', 'class_name_norm=?');
      vals.push(class_name ? String(class_name) : null, norm);
      if (norm !== row.class_name_norm) sets.push('verification_level=0', 'verified_at=NULL', 'verification_source=NULL');
    }
    if (visibility !== undefined) {
      if (!VISIBILITIES.includes(visibility)) throw E.param('visibility 不合法');
      sets.push('visibility=?'); vals.push(visibility);
    }
    if (department !== undefined) { sets.push('department=?'); vals.push(department); }
    if (major !== undefined) { sets.push('major=?'); vals.push(major); }
    if (school_name_snapshot !== undefined) { sets.push('school_name_snapshot=?'); vals.push(String(school_name_snapshot)); }
    if (!sets.length) throw E.param('没有可更新的字段');
    run(db, `UPDATE education_experiences SET ${sets.join(',')} WHERE id=?`, ...vals, row.id);
    getIMProvider(db, config).syncClassMemberships(ctx.user.id);
    return ok(ctx);
  });

  router.delete('/v1/users/me/educations/:education_id', { auth: true }, (ctx) => {
    const info = run(db, 'DELETE FROM education_experiences WHERE id=? AND user_id=?', Number(ctx.params.education_id), ctx.user.id);
    if (!info.changes) throw E.notFound('经历不存在');
    getIMProvider(db, config).syncClassMemberships(ctx.user.id);
    return ok(ctx);
  });

  router.get('/v1/schools/search', { auth: true }, (ctx) => {
    const keyword = String(ctx.query.keyword ?? '').trim();
    if (!keyword) throw E.param('keyword 必填');
    const like = `%${keyword}%`;
    let rows = q(
      db,
      "SELECT * FROM schools WHERE status='active' AND (name LIKE ? OR former_names LIKE ?) LIMIT 20",
      like, like
    );
    if (ctx.query.region_code) {
      rows = rows.filter((s) => String(s.region_code || '').startsWith(String(ctx.query.region_code).slice(0, 4)));
    }
    return ok(ctx, {
      items: rows.map((s) => ({
        school_id: s.school_id, name: s.name,
        former_names: JSON.parse(s.former_names || '[]'),
        region_code: s.region_code, stage: s.stage,
      })),
    });
  });

  router.post('/v1/schools/apply', { auth: true }, (ctx) => {
    const { name, region_code, evidence_urls = [] } = ctx.body || {};
    if (!name || !region_code) throw E.param('name 与 region_code 必填');
    run(
      db,
      'INSERT INTO school_applications(user_id,name,region_code,evidence_urls,created_at) VALUES(?,?,?,?,?)',
      ctx.user.id, String(name), String(region_code), JSON.stringify(evidence_urls), now()
    );
    return ok(ctx, { status: 'pending', sla: '运营审核 SLA 3 个工作日' });
  });
}
