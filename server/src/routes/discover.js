import { q, q1, run, audit, getUser, getPrivacy, getUserByPhone, isBlockedBetween } from '../repo.js';
import { ok, E } from '../http/respond.js';
import { isInt, now, normalizeClassName } from '../util.js';
import { rules } from '../engine/index.js';
import { hitRate } from '../rate.js';
import { passWithCaptcha } from './captcha.js';
import { toUserBrief } from './users.js';

// 找同学/找老乡检索：锚点强制（§5.2.5）+ 频控与翻页深度（§6.2.3 / §22.4）+ 渐显矩阵出口
// 42901 need_captcha 消费点：触发时先尝试 captcha_token（一次性，query/body/X-Captcha-Token 头），
// 通过则放行并重置该计数窗口；dev 模式（DIMI_SMS_DEV=true）接受 dev_bypass
function maskedTotal(n) {
  return n <= 10 ? String(n) : `${Math.floor(n / 10) * 10}+`;
}

function checkSearchCommon(ctx) {
  const rl = rules.rate_limit;
  const rateKey = `search:${ctx.user.id}:hour`;
  let captchaOk = false;
  if (!hitRate(ctx.db, rateKey, rl.search_per_hour, 3600).allowed) {
    captchaOk = passWithCaptcha(ctx, rateKey);
    if (!captchaOk) throw E.rate('检索过于频繁，请完成验证', { captcha_required: true, need_captcha: true });
  }
  const page = Number(ctx.query.page ?? 1);
  const requestedSize = Number(ctx.query.size ?? rl.search_page_size);
  if (!Number.isInteger(page) || page < 1 || !Number.isInteger(requestedSize) || requestedSize < 1) throw E.param('page / size 须为正整数');
  // 同一请求一枚 token 只需验一次：小时窗已用 token 放行则翻页深度沿用
  if (page > rl.search_max_page && !captchaOk && !passWithCaptcha(ctx)) {
    throw E.rate('翻页过深，请完成人机验证', { captcha_required: true, need_captcha: true });
  }
  const size = Math.min(requestedSize, 50);
  return { page, size, offset: (page - 1) * size };
}

// 可见性在分页前判断，隐藏用户不消耗 offset 或页大小。
function visibleCandidates(db, viewer, candidates, { via, size, offset = 0, exclude = new Set(), scene = 'search' }) {
  const rows = [];
  let skipped = 0;
  for (const user of candidates) {
    if (exclude.has(user.id) || getPrivacy(db, user).add_me_via[via] === false) continue;
    const brief = toUserBrief(db, viewer, user, { scene });
    if (brief.intersection_tier === 'T0') continue;
    if (skipped++ < offset) continue;
    rows.push({ ...user, _brief: brief });
    if (rows.length > size) break;
  }
  return rows;
}

function searchBySchool(db, viewer, { schoolId, year, classNorm, name, size, offset, exclude, scene }) {
  classNorm = classNorm ? normalizeClassName(classNorm) : null;
  const like = name ? `%${name}%` : null;
  const rows = db.prepare(
    `SELECT DISTINCT u.* FROM users u
     JOIN education_experiences e ON e.user_id = u.id
     WHERE u.status=1 AND u.id!=?
       AND e.school_id=? AND e.enroll_year=?
       AND (? IS NULL OR e.class_name_norm = ?)
       AND (? IS NULL OR u.real_name LIKE ? OR u.nickname LIKE ?)
       AND NOT EXISTS (SELECT 1 FROM blocks b WHERE (b.user_id=? AND b.blocked_id=u.id) OR (b.user_id=u.id AND b.blocked_id=?))
     ORDER BY u.id`).iterate(
    viewer.id, schoolId, year,
    classNorm || null, classNorm || null,
    like, like, like,
    viewer.id, viewer.id
  );
  // 隐私豁免（§6.2.3）：关闭「通过学校检索到我」的用户不出现在结果中
  return visibleCandidates(db, viewer, rows, { via: 'school_search', size, offset, exclude, scene });
}

function searchByTown(db, viewer, { regionCode, name, size, offset, exclude, scene }) {
  const like = name ? `%${name}%` : null;
  const rows = db.prepare(
    `SELECT DISTINCT u.* FROM users u
     JOIN user_hometowns h ON h.user_id = u.id AND h.type = 1
     WHERE u.status=1 AND u.id!=?
       AND h.region_code=?
       AND (? IS NULL OR u.real_name LIKE ? OR u.nickname LIKE ?)
       AND NOT EXISTS (SELECT 1 FROM blocks b WHERE (b.user_id=? AND b.blocked_id=u.id) OR (b.user_id=u.id AND b.blocked_id=?))
     ORDER BY u.id`).iterate(
    viewer.id, regionCode,
    like, like, like,
    viewer.id, viewer.id
  );
  return visibleCandidates(db, viewer, rows, { via: 'hometown_search', size, offset, exclude, scene });
}

// 分页契约统一：只消费 page（默认 1）/ size（默认 20，上限 50），忽略 cursor；
// next_cursor = 还有下一页时 String(page+1)，否则 null（客户端按页传 page）
function resultOut(db, viewer, rows, size, page, extra = {}) {
  const hasMore = rows.length > size;
  const items = rows
    .slice(0, size)
    .map((u) => u._brief ?? toUserBrief(db, viewer, u, { scene: 'search' }))
    .filter((i) => i.intersection_tier !== 'T0'); // §5.2.4：T0 纯陌生人不出现在检索结果中
  return {
    total_masked: maskedTotal(items.length + (hasMore ? 1 : 0)),
    items,
    next_cursor: hasMore ? String(page + 1) : null,
    ...extra,
  };
}

export function registerDiscoverRoutes(router, { db }) {
  // 主动检索器（路径 B，§6.2.1）：锚点强制 school_id + enroll_year
  router.get('/v1/discover/classmates', { auth: true }, (ctx) => {
    const { school_id, enroll_year, class_norm, name } = ctx.query;
    if (!isInt(school_id) || !isInt(enroll_year)) throw E.param('缺少检索锚点：school_id + enroll_year 必填（§5.2.5）');
    const { page, size, offset } = checkSearchCommon(ctx);
    const rows = searchBySchool(db, ctx.user, {
      schoolId: Number(school_id), year: Number(enroll_year),
      classNorm: class_norm || null, name: name || null, size, offset,
    });
    audit(db, { userId: ctx.user.id, event: 'search', scene: 'classmates', input: { school_id, enroll_year, class_norm, name } });
    return ok(ctx, resultOut(db, ctx.user, rows, size, page));
  });

  // 路径 A：从我的经历出发的同班/同届/同校名录
  router.get('/v1/discover/classmates/mine', { auth: true }, (ctx) => {
    const { education_id, scope = 'class' } = ctx.query;
    if (!isInt(education_id)) throw E.param('education_id 必填');
    const edu = q1(db, 'SELECT * FROM education_experiences WHERE id=? AND user_id=?', Number(education_id), ctx.user.id);
    if (!edu) throw E.notFound('经历不存在');
    const { page, size, offset } = checkSearchCommon(ctx);
    let rows;
    if (scope === 'class') {
      rows = searchBySchool(db, ctx.user, { schoolId: edu.school_id, year: edu.enroll_year, classNorm: edu.class_name_norm, name: null, size, offset });
    } else if (scope === 'grade') {
      rows = searchBySchool(db, ctx.user, { schoolId: edu.school_id, year: edu.enroll_year, classNorm: null, name: null, size, offset });
    } else if (scope === 'school') {
      const candidates = db.prepare(
        `SELECT DISTINCT u.* FROM users u JOIN education_experiences e ON e.user_id=u.id
         WHERE u.status=1 AND u.id!=? AND e.school_id=?
           AND NOT EXISTS (SELECT 1 FROM blocks b WHERE (b.user_id=? AND b.blocked_id=u.id) OR (b.user_id=u.id AND b.blocked_id=?))
         ORDER BY u.id`).iterate(
        ctx.user.id, edu.school_id, ctx.user.id, ctx.user.id
      );
      rows = visibleCandidates(db, ctx.user, candidates, { via: 'school_search', size, offset });
    } else {
      throw E.param('scope 仅支持 class / grade / school');
    }
    audit(db, { userId: ctx.user.id, event: 'search', scene: 'classmates_mine', input: { education_id, scope } });
    return ok(ctx, resultOut(db, ctx.user, rows, size, page));
  });

  // 推荐 Feed（人脉首页卡片流）：共同经历/同乡候选，必带 reason 推荐理由标签
  router.get('/v1/discover/recommendations', { auth: true }, (ctx) => {
    const { scene = 'home' } = ctx.query;
    if (!['home', 'classmate', 'fellow'].includes(scene)) throw E.param('scene 仅支持 home / classmate / fellow');
    if (!getPrivacy(db, ctx.user).personalized_recommend) {
      return ok(ctx, { items: [], next_cursor: null, total_masked: '0', disabled: true });
    }
    // 与主动检索同姿态的防爬频控 + 翻页深度上限（契约 §6.2.3）
    const rl = rules.rate_limit;
    const recKey = `recommend:${ctx.user.id}:hour`;
    let recCaptchaOk = false;
    if (!hitRate(db, recKey, rl.search_per_hour, 3600).allowed) {
      recCaptchaOk = passWithCaptcha(ctx, recKey);
      if (!recCaptchaOk) throw E.rate('加载过于频繁，请稍后再试', { captcha_required: true, need_captcha: true });
    }
    const page = Number(ctx.query.page ?? 1);
    const requestedSize = Number(ctx.query.size ?? rl.search_page_size);
    if (!Number.isInteger(page) || page < 1 || !Number.isInteger(requestedSize) || requestedSize < 1) throw E.param('page / size 须为正整数');
    if (page > rl.search_max_page && !recCaptchaOk && !passWithCaptcha(ctx)) {
      throw E.rate('翻页过深，请完成人机验证', { captcha_required: true, need_captcha: true });
    }
    const size = Math.min(requestedSize, 50);
    const offset = (page - 1) * size;

    const excluded = new Set([
      ...q(db, 'SELECT friend_id id FROM friendships WHERE user_id=?', ctx.user.id),
      ...q(db, "SELECT target_user_id id FROM recommendation_feedback WHERE user_id=? AND action='not_interested'", ctx.user.id),
      ...q(db, `SELECT CASE WHEN from_user=? THEN to_user ELSE from_user END id FROM friend_requests
        WHERE (from_user=? OR to_user=?) AND status='pending' AND expire_at>?`, ctx.user.id, ctx.user.id, ctx.user.id, now()),
    ].map(row => row.id));
    const seen = new Map(); // userId -> { u, reason }，按优先级去重
    const add = (u, reason) => { if (!seen.has(u.id)) seen.set(u.id, { u, reason }); };

    if (scene !== 'fellow') {
      const edus = q(db, 'SELECT * FROM education_experiences WHERE user_id=?', ctx.user.id);
      for (const edu of edus) {
        if (edu.class_name_norm) {
          for (const u of searchBySchool(db, ctx.user, { schoolId: edu.school_id, year: edu.enroll_year, classNorm: edu.class_name_norm, name: null, size: offset + size, offset: 0, exclude: excluded, scene: 'recommend' })) {
            add(u, '同班同学');
          }
        }
        for (const u of searchBySchool(db, ctx.user, { schoolId: edu.school_id, year: edu.enroll_year, classNorm: null, name: null, size: offset + size, offset: 0, exclude: excluded, scene: 'recommend' })) {
          add(u, '同届校友');
        }
      }
    }
    if (scene !== 'classmate') {
      const towns = q(db, 'SELECT * FROM user_hometowns WHERE user_id=? AND type=1', ctx.user.id);
      for (const t of towns) {
        for (const u of searchByTown(db, ctx.user, { regionCode: t.region_code, name: null, size: offset + size, offset: 0, exclude: excluded, scene: 'recommend' })) {
          add(u, '同乡');
        }
      }
    }

    const visible = [...seen.values()];
    const slice = visible.slice(offset, offset + size + 1);
    const hasMore = slice.length > size;
    const items = slice
      .slice(0, size)
      .map(({ u, reason }) => ({ ...(u._brief ?? toUserBrief(db, ctx.user, u, { scene: 'recommend' })), reason }))
      .filter((i) => i.intersection_tier !== 'T0'); // §5.2.4：T0 纯陌生人不出现在推荐中
    audit(db, { userId: ctx.user.id, event: 'recommend', scene, input: { page, size } });
    return ok(ctx, {
      total_masked: maskedTotal(items.length + (hasMore ? 1 : 0)),
      items,
      next_cursor: hasMore ? String(page + 1) : null,
    });
  });

  // 找老乡检索（契约 /discover/fellows）：锚点为区县以上地区，level 控制匹配粒度
  router.get('/v1/discover/fellows', { auth: true }, (ctx) => {
    const { region_code, name, gender, age_range, live_city_code } = ctx.query;
    const anchor = q1(db, 'SELECT * FROM regions WHERE code=? AND is_active=1', String(region_code ?? ''));
    if (!anchor) throw E.param('region_code 必填且须为有效行政区划');
    const lvl = Number(ctx.query.level || 3);
    if (![2, 3, 4].includes(lvl)) throw E.param('level 仅支持 2 市 / 3 区县 / 4 镇');
    if (anchor.level < lvl) throw E.param('匹配粒度（level）不能细于锚点地区层级');

    // 祖先链上取目标层级地区，转 LIKE 前缀（省级 41 / 市级 4116 / 区县 411623 / 镇级全码）
    let r = anchor;
    while (r.level > lvl && r.parent_code) {
      r = q1(db, 'SELECT * FROM regions WHERE code=?', r.parent_code);
    }
    const prefix = r.level === 1 ? r.code.slice(0, 2) : r.level === 2 ? r.code.slice(0, 4) : r.code;

    // 出生年份区间 "1980-1990"
    let yMin = null, yMax = null;
    if (age_range) {
      const m = /^(\d{4})-(\d{4})$/.exec(String(age_range));
      if (!m) throw E.param('age_range 格式应为 "1980-1990"');
      yMin = Number(m[1]); yMax = Number(m[2]);
    }
    const like = name ? `%${name}%` : null;
    const g = isInt(gender) && [1, 2].includes(Number(gender)) ? Number(gender) : null;

    const { page, size, offset } = checkSearchCommon(ctx);
    const candidates = db.prepare(
      `SELECT DISTINCT u.* FROM users u
       JOIN user_hometowns h ON h.user_id=u.id AND h.type=1 AND h.visibility='public'
       WHERE u.status=1 AND u.id!=?
         AND h.region_code LIKE ? || '%'
         AND (? IS NULL OR u.gender=?)
         AND (? IS NULL OR u.birth_year>=?) AND (? IS NULL OR u.birth_year<=?)
         AND (? IS NULL OR u.real_name LIKE ? OR u.nickname LIKE ?)
         AND (? IS NULL OR EXISTS (SELECT 1 FROM user_hometowns h2 WHERE h2.user_id=u.id AND h2.type=2 AND h2.region_code=?))
         AND NOT EXISTS (SELECT 1 FROM blocks b WHERE (b.user_id=? AND b.blocked_id=u.id) OR (b.user_id=u.id AND b.blocked_id=?))
       ORDER BY u.id`).iterate(
      ctx.user.id, prefix,
      g, g,
      yMin, yMin, yMax, yMax,
      like, like, like,
      live_city_code ? String(live_city_code) : null, live_city_code ? String(live_city_code) : null,
      ctx.user.id, ctx.user.id
    );
    const rows = visibleCandidates(db, ctx.user, candidates, { via: 'hometown_search', size, offset });
    audit(db, { userId: ctx.user.id, event: 'search', scene: 'fellows', input: { region_code, level: lvl, name, gender: g, age_range, live_city_code } });
    return ok(ctx, resultOut(db, ctx.user, rows, size, page));
  });

  // 精确找人 / 姓名检索：锚点强制——school_id+enroll_year 或镇级 region_id，否则 40001（§5.2.5）
  router.get('/v1/discover/search-user', { auth: true }, (ctx) => {
    const { dimi_no, phone, school_id, enroll_year, class_norm, region_id, name } = ctx.query;

    // 契约模式：DIMI号/手机号精确找人（0 或 1 条）。独立更严频控（20 次/时），
    // 尊重「添加我的方式」开关（add_me_via.dimi_no / phone），拉黑双向不可见
    if (dimi_no || phone) {
      if (dimi_no && phone) throw E.param('dimi_no 与 phone 二选一');
      const exactKey = `search_exact:${ctx.user.id}:hour`;
      if (!hitRate(db, exactKey, 20, 3600).allowed && !passWithCaptcha(ctx, exactKey)) {
        throw E.rate('精确找人过于频繁，请完成验证', { captcha_required: true, need_captcha: true });
      }
      let target = null;
      let via = null;
      if (dimi_no) {
        via = 'dimi_no';
        target = q1(db, 'SELECT * FROM users WHERE dimi_no=? COLLATE NOCASE AND status=1', String(dimi_no).trim());
      } else {
        via = 'phone';
        if (!/^1[3-9]\d{9}$/.test(String(phone))) throw E.param('手机号格式不正确');
        const u = getUserByPhone(db, String(phone));
        if (u && u.status === 1) target = u;
      }
      if (target && getPrivacy(db, target).add_me_via[via] === false) target = null;
      if (target && isBlockedBetween(db, ctx.user.id, target.id)) target = null;
      audit(db, { userId: ctx.user.id, event: 'search', scene: 'search_user_exact', input: { via }, output: { hit: !!target } });
      return ok(ctx, {
        total_masked: target ? '1' : '0',
        items: target ? [toUserBrief(db, ctx.user, target, { scene: 'search' })] : [],
        next_cursor: null,
      });
    }

    const hasSchoolAnchor = isInt(school_id) && isInt(enroll_year);
    let townAnchor = null;
    if (region_id) {
      const region = q1(db, 'SELECT * FROM regions WHERE code=? AND is_active=1', String(region_id));
      if (region && region.level === 4) townAnchor = region;
    }
    if (!hasSchoolAnchor && !townAnchor) {
      throw E.param('姓名检索必须携带锚点：school_id+enroll_year 或 镇级 region_id（禁止纯姓名全库扫描）');
    }
    const { page, size, offset } = checkSearchCommon(ctx);
    const rows = hasSchoolAnchor
      ? searchBySchool(db, ctx.user, { schoolId: Number(school_id), year: Number(enroll_year), classNorm: class_norm || null, name: name || null, size, offset })
      : searchByTown(db, ctx.user, { regionCode: townAnchor.code, name: name || null, size, offset });
    audit(db, { userId: ctx.user.id, event: 'search', scene: 'search_user', input: { school_id, enroll_year, region_id, name } });
    return ok(ctx, resultOut(db, ctx.user, rows, size, page));
  });

  // 推荐负反馈（契约 /discover/feedback）：不感兴趣/减少此类，落库并影响后续候选排序
  router.post('/v1/discover/feedback', { auth: true }, (ctx) => {
    const { target_user_id, action } = ctx.body || {};
    if (!isInt(target_user_id)) throw E.param('target_user_id 必填');
    if (!['not_interested', 'reduce_similar'].includes(action)) throw E.param('action 仅支持 not_interested / reduce_similar');
    if (!hitRate(db, `rec_feedback:${ctx.user.id}:hour`, 30, 3600).allowed) {
      throw E.rate('操作过于频繁');
    }
    run(db, 'INSERT INTO recommendation_feedback(user_id,target_user_id,action,created_at) VALUES(?,?,?,?)',
      ctx.user.id, Number(target_user_id), action, now());
    audit(db, { userId: ctx.user.id, event: 'recommend_feedback', targetId: Number(target_user_id), input: { action } });
    return ok(ctx);
  });

  // 班级预占位名册（沉睡名字，不含任何联系方式；V3.1 A7「沉睡不可见」原则）
  router.get('/v1/discover/placeholders', { auth: true }, (ctx) => {
    const unit = resolveUnit(ctx);
    const out = placeholderOut(db, ctx.user, unit);
    const invite = q1(
      db,
      'SELECT code FROM invites WHERE school_id=? AND enroll_year=? AND class_norm=?',
      unit.school_id, unit.enroll_year, unit.class_norm
    );
    return ok(ctx, {
      rally_ready: out.registered_count >= 3,
      rally_card_url: invite ? `/h5/invite.html?code=${invite.code}` : null,
      ...out,
    });
  });

  // 为未注册同学「点亮名字」（§6.4）
  router.post('/v1/discover/placeholders', { auth: true }, (ctx) => {
    const { education_id, name } = ctx.body || {};
    if (!isInt(education_id)) throw E.param('education_id 必填');
    if (!name || [...String(name)].length > 32) throw E.param('name 必填且不超过 32 字');
    const edu = q1(db, 'SELECT * FROM education_experiences WHERE id=? AND user_id=?', Number(education_id), ctx.user.id);
    if (!edu) throw E.notFound('经历不存在');
    if (!edu.class_name_norm) throw E.param('该经历未填写班级，无法点亮名册');
    run(
      db,
      'INSERT OR IGNORE INTO placeholders(school_id,enroll_year,class_norm,name,lit_by,created_at) VALUES(?,?,?,?,?,?)',
      edu.school_id, edu.enroll_year, edu.class_name_norm, String(name), ctx.user.id, now()
    );
    const unit = { school_id: edu.school_id, enroll_year: edu.enroll_year, class_norm: edu.class_name_norm };
    const out = placeholderOut(db, ctx.user, unit);
    const invite = q1(
      db,
      'SELECT code FROM invites WHERE school_id=? AND enroll_year=? AND class_norm=?',
      unit.school_id, unit.enroll_year, unit.class_norm
    );
    return ok(ctx, {
      rally_ready: out.registered_count >= 3,
      rally_card_url: invite ? `/h5/invite.html?code=${invite.code}` : null,
      ...out,
    });
  });

  function resolveUnit(ctx) {
    const { education_id, school_id, enroll_year, class_norm } = ctx.query;
    if (isInt(education_id)) {
      // 归属校验：education_id 必须属于当前用户（与 POST 侧一致），防横向探测他班名册
      const edu = q1(db, 'SELECT * FROM education_experiences WHERE id=? AND user_id=?', Number(education_id), ctx.user.id);
      if (!edu) throw E.privacy('仅能查看本人教育经历对应班级的名册');
      return { school_id: edu.school_id, enroll_year: edu.enroll_year, class_norm: edu.class_name_norm };
    }
    if (isInt(school_id) && isInt(enroll_year) && class_norm) {
      // 三元组直查同样要求该校+届+班在本人教育经历中
      const own = q1(
        db,
        'SELECT 1 x FROM education_experiences WHERE user_id=? AND school_id=? AND enroll_year=? AND class_name_norm=?',
        ctx.user.id, Number(school_id), Number(enroll_year), String(class_norm)
      );
      if (!own) throw E.privacy('仅能查看本人教育经历对应班级的名册');
      return { school_id: Number(school_id), enroll_year: Number(enroll_year), class_norm: String(class_norm) };
    }
    throw E.param('需要 education_id 或 school_id+enroll_year+class_norm 锚点');
  }

  function placeholderOut(db, viewer, unit) {
    const names = q(
      db,
      'SELECT name FROM placeholders WHERE school_id=? AND enroll_year=? AND class_norm=? ORDER BY id',
      unit.school_id, unit.enroll_year, unit.class_norm
    ).map((r) => r.name);
    const registered = q1(
      db,
      'SELECT COUNT(DISTINCT user_id) c FROM education_experiences WHERE school_id=? AND enroll_year=? AND class_name_norm=?',
      unit.school_id, unit.enroll_year, unit.class_norm
    ).c;
    const school = q1(db, 'SELECT name FROM schools WHERE school_id=?', unit.school_id);
    return {
      unit: { school_id: unit.school_id, school_name: school?.name ?? null, enroll_year: unit.enroll_year, class_norm: unit.class_norm },
      registered_count: registered,
      placeholder_count: names.length,
      items: names.map((name) => ({ name })),
    };
  }
}
