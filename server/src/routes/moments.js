import { q, q1, run, audit, getUser, getPrivacy, isFriend, isBlockedBetween } from '../repo.js';
import { ok, E } from '../http/respond.js';
import { isInt, now } from '../util.js';
import { containsContactInfo } from '../engine/index.js';
import { hitRate } from '../rate.js';
import { toUserBrief } from './users.js';
import { hasGroupUnlock, needsGroupUnlock } from './groups.js';
import { grantTask } from '../coins.js';

// 朋友圈/发现（契约 Moments 域）：纯时间倒序无算法；可见范围发布即冻结；
// 主时间线仅含「自己 + 好友」动态（陌生人十条只在相册页生效）；
// 同学圈/老乡圈聚合页（feed?visibility=classmates|fellows）按作者关系聚合：
// 与我同校同届（或家乡同市）的人的 classmates/public（或 fellows/public）动态，无需好友；
// 互动仅共同好友可见（服务端过滤）；好友时间范围由隐私设置控制
const VISIBILITIES = ['public', 'private', 'partial', 'excluded', 'classmates', 'fellows'];
const CONTENT_TYPES = ['text', 'image', 'article'];

// 同窗判定（同学圈 classmates 语义）：任一教育经历同校且同届（差一届不算同窗，
// 「我们班的只给同班同学看」按同校同届收紧，见设计报告同学圈章节）
function sharesSameGrade(db, a, b) {
  return !!q1(
    db,
    `SELECT 1 x FROM education_experiences e1
     JOIN education_experiences e2 ON e2.school_id=e1.school_id AND e2.enroll_year=e1.enroll_year
     WHERE e1.user_id=? AND e2.user_id=? LIMIT 1`,
    a, b
  );
}

// 与作者存在同乡交集（家乡同市及以上）
function sharesHometown(db, a, b) {
  const ha = q1(db, 'SELECT region_code FROM user_hometowns WHERE user_id=? AND type=1', a);
  const hb = q1(db, 'SELECT region_code FROM user_hometowns WHERE user_id=? AND type=1', b);
  if (!ha || !hb) return false;
  return ha.region_code.slice(0, 4) === hb.region_code.slice(0, 4); // 市级前缀
}

// 陌生人十条窗口下限：作者第 10 新的 public 动态 moment_id（不足 10 条返回 null 即全部可见）。
// 详情/互动直访按此窗口判定，防 moment_id 枚举拉取全部历史公开动态；相册页 slice(10) 逻辑不变
function strangerTenFloor(db, authorId) {
  const row = q1(
    db,
    "SELECT moment_id FROM moments WHERE author_id=? AND deleted=0 AND visibility='public' ORDER BY moment_id DESC LIMIT 1 OFFSET 9",
    authorId
  );
  return row ? row.moment_id : null;
}

// 可见性判定：viewer 是否可见该动态（返回 false 即整块缺省，不反向暴露）
// classmates/fellows 无需好友：作者发布时已显式选择圈子受众（同窗/同乡即目标读者）；
// public 动态对同窗/同乡同样放行（圈页语境下他们是同窗/同乡而非陌生人），
// 陌生人十条约束与作者无任何交集的陌生人（相册页 + 详情/互动直访同窗口）
// ctx 为路由上下文（读 X-Group-Unlock 头判高隐私分组解锁）；无 ctx 的调用方按未解锁处理（安全缺省）
export function canSeeMoment(db, viewer, moment, author, ctx = null) {
  if (moment.deleted || !author || author.status !== 1) return false;
  if (isBlockedBetween(db, viewer.id, author.id)) return false;
  if (viewer.id === author.id) return true;
  // 高隐私分组门禁：作者在 viewer 的高隐私组 → 须解锁（hasGroupUnlock 读 ctx.req.headers）
  if (needsGroupUnlock(db, viewer, author.id) && !(ctx && hasGroupUnlock(db, ctx))) return false;

  const friend = isFriend(db, viewer.id, author.id);
  const authorPrivacy = getPrivacy(db, author);

  // 好友时间范围（friend_moments_range：all / three_days / one_month / half_year）
  if (friend && authorPrivacy.friend_moments_range !== 'all') {
    const days = {
      three_days: 3,
      one_month: 30,
      half_year: 182,
    }[authorPrivacy.friend_moments_range] ?? 182;
    if (Date.now() - Date.parse(moment.created_at) > days * 86400 * 1000) return false;
  }

  switch (moment.visibility) {
    case 'private':
      return false;
    case 'public': {
      if (friend) return true;
      // 非好友：同窗/同乡放行保持现状（刻意：圈页可见则详情可见，详情接口共用本判定）
      const related = sharesSameGrade(db, viewer.id, author.id) || sharesHometown(db, viewer.id, author.id);
      if (!authorPrivacy.stranger_moments_10) return related;
      if (related) return true;
      // 与作者无交集的陌生人：仅作者最新 10 条 public 动态可见（详情/互动直访同样受限）
      const floor = strangerTenFloor(db, author.id);
      return floor === null || moment.moment_id >= floor;
    }
    case 'partial': {
      if (!friend) return false;
      const tags = JSON.parse(moment.visible_tag_ids || '[]');
      const rel = q1(db, 'SELECT tags FROM friendships WHERE user_id=? AND friend_id=?', author.id, viewer.id);
      const viewerTags = JSON.parse(rel?.tags || '[]');
      return tags.some((t) => viewerTags.includes(String(t)));
    }
    case 'excluded': {
      const excluded = JSON.parse(moment.excluded_user_ids || '[]').map(Number);
      return friend && !excluded.includes(viewer.id);
    }
    case 'classmates':
      return sharesSameGrade(db, viewer.id, author.id); // 同窗即可见，无需好友
    case 'fellows':
      return sharesHometown(db, viewer.id, author.id); // 同乡即可见，无需好友
    default:
      return false;
  }
}

// 互动过滤：仅 viewer 的好友（含本人/作者）的点赞与评论可见。
// 刻意保留的隐私语义：即使在同学圈/老乡圈聚合页中动态对非好友同窗/同乡可见，
// 非好友的互动（点赞/评论）仍不下发，避免向陌生人暴露社交关系链
function visibleInteractions(db, viewer, author, momentId) {
  const likeRows = q(db, 'SELECT user_id FROM moment_likes WHERE moment_id=?', momentId);
  const likeIds = likeRows
    .map((r) => r.user_id)
    .filter((id) => id === viewer.id || id === author.id || isFriend(db, viewer.id, id));
  const comments = q(
    db,
    'SELECT * FROM moment_comments WHERE moment_id=? AND deleted=0 ORDER BY id',
    momentId
  ).filter((c) => c.from_user === viewer.id || c.from_user === author.id || isFriend(db, viewer.id, c.from_user));
  return { likeIds, comments, liked: likeIds.includes(viewer.id) };
}

function momentOut(db, viewer, m, author, { detail = false } = {}) {
  const { likeIds, comments, liked } = visibleInteractions(db, viewer, author, m.moment_id);
  // 点赞名单（仅共同好友可见的口径已由 visibleInteractions 过滤）：微信式「♥ 张三、李四」
  const likes = likeIds.map((id) => {
    const u = id === viewer.id ? viewer : id === author.id ? author : getUser(db, id);
    return u ? toUserBrief(db, viewer, u, { scene: 'moment' }) : null;
  }).filter(Boolean);
  // 评论的回复对象 brief（能在可见评论/作者中解析到才下发，查不到为 null）
  const replyBrief = (replyToUserId) => {
    if (!replyToUserId) return null;
    const visibleIds = new Set([viewer.id, author.id, ...comments.map((c) => c.from_user)]);
    if (!visibleIds.has(replyToUserId)) return null;
    const u = getUser(db, replyToUserId);
    return u ? toUserBrief(db, viewer, u, { scene: 'moment' }) : null;
  };
  const out = {
    moment_id: m.moment_id,
    author: toUserBrief(db, viewer, author, { scene: 'moment' }),
    content_type: m.content_type,
    content: m.content,
    media: JSON.parse(m.media || '[]'),
    article_card: null,
    location_poi: m.location_poi ?? null,
    visibility: m.visibility,
    like_count: likeIds.length,
    likes,
    liked,
    comment_count: comments.length,
    comment_preview: comments.slice(-3).map((c) => ({
      from_user: toUserBrief(db, viewer, getUser(db, c.from_user), { scene: 'moment' }),
      reply_to_user: replyBrief(c.reply_to_user_id),
      content: c.content,
    })),
    created_at: m.created_at,
    is_own: author.id === viewer.id,
  };
  if (detail) {
    out.comments = comments.map((c) => ({
      id: c.id,
      from_user: toUserBrief(db, viewer, getUser(db, c.from_user), { scene: 'moment' }),
      reply_to_user_id: c.reply_to_user_id ?? null,
      reply_to_user: replyBrief(c.reply_to_user_id),
      content: c.content,
      created_at: c.created_at,
    }));
  }
  return out;
}

function getMoment(db, id) {
  const m = q1(db, 'SELECT * FROM moments WHERE moment_id=? AND deleted=0', id);
  if (!m) throw E.notFound('动态不存在或已删除');
  return m;
}

export function registerMomentRoutes(router, { db, storage }) {
  // 发布动态：可见范围发布即冻结（不可改）
  router.post('/v1/moments', { auth: true }, (ctx) => {
    const { content_type = 'text', content, media_ids = [], visibility = 'public',
      visible_tag_ids = [], excluded_user_ids = [], location_poi = null } = ctx.body || {};
    if (!CONTENT_TYPES.includes(content_type)) throw E.param('content_type 支持 text / image / article');
    if (!VISIBILITIES.includes(visibility)) throw E.param('visibility 不合法（六档：public/private/partial/excluded/classmates/fellows）');
    if (['text', 'article'].includes(content_type) && (typeof content !== 'string' || !content.trim())) throw E.param('文字内容必填');
    const maxLength = content_type === 'article' ? 20000 : 2000;
    if (content != null && (typeof content !== 'string' || [...content].length > maxLength)) throw E.param(`内容不超过 ${maxLength} 字`);
    if (!Array.isArray(media_ids) || media_ids.length > 9) throw E.param('media_ids 最多 9 个');
    // 客户端把 /misc/upload 返回的 url 原样作为 media_id 提交，服务端原样存取；
    // URL 形态（/media/ 相对路径或 OSS 绝对 URL）经 storage 分层校验
    if (!media_ids.every((id) => typeof id === 'string' && storage.isValidMediaUrl(id))) {
      throw E.param('media_ids 元素须为 /misc/upload 返回的媒体 url（jpg/jpeg/png/webp）');
    }
    if (content_type === 'image' && media_ids.length < 1) throw E.param('图片动态至少 1 张图（配文可选）');
    // 内容安全：联系方式/引流拦截（45001，与申请验证语同一套规则）
    if (content && containsContactInfo(String(content))) {
      audit(db, { userId: ctx.user.id, event: 'content_block', scene: 'moment' });
      throw E.content('内容包含联系方式或导流信息，已被拦截');
    }
    if (!hitRate(db, `moment:${ctx.user.id}:day`, 30, 86400).allowed) throw E.rate('今日发布已达上限');
    const info = run(
      db,
      `INSERT INTO moments(author_id,content_type,content,media,visibility,visible_tag_ids,excluded_user_ids,location_poi,created_at)
       VALUES(?,?,?,?,?,?,?,?,?)`,
      ctx.user.id, content_type, content ?? null, JSON.stringify(media_ids.map(String)),
      visibility, JSON.stringify(visible_tag_ids), JSON.stringify(excluded_user_ids.map(Number)),
      location_poi ? String(location_poi).slice(0, 64) : null, now()
    );
    audit(db, { userId: ctx.user.id, event: 'moment_publish', targetId: Number(info.lastInsertRowid), input: { content_type, visibility } });
    grantTask(db, ctx.user.id, 'first_moment'); // 发布首条动态 +10（P0 纯赠送，幂等一次性）
    const m = getMoment(db, Number(info.lastInsertRowid));
    return ok(ctx, momentOut(db, ctx.user, m, ctx.user));
  });

  // 时间线：仅「好友 + 自己」的动态（陌生人公开动态即使开了 stranger_moments_10 也不进主 feed，
  // 陌生人十条只在 /users/:id/moments 相册页生效）；纯时间倒序；
  // visibility=classmates/fellows 为同学圈/老乡圈聚合页：按作者关系聚合——与我同校同届（或家乡同市）
  // 的人发布的 classmates/public（或 fellows/public）动态，不走好友门；private/partial/excluded 不进圈页
  router.get('/v1/moments/feed', { auth: true }, (ctx) => {
    const cursor = isInt(ctx.query.cursor) ? Number(ctx.query.cursor) : null;
    const { visibility } = ctx.query;
    if (visibility !== undefined && !['classmates', 'fellows'].includes(visibility)) {
      throw E.param('visibility 仅支持 classmates / fellows');
    }
    // 圈页宽取：显式圈子动态 + public 动态（public 在圈页语境下对同窗/同乡放行）
    const circleSql = visibility === 'classmates'
      ? "AND m.visibility IN ('public','classmates')"
      : visibility === 'fellows'
        ? "AND m.visibility IN ('public','fellows')"
        : '';
    const limit = 20;
    const rows = db.prepare(
      `SELECT m.*, u.status astatus FROM moments m JOIN users u ON u.id=m.author_id
       WHERE m.deleted=0 AND u.status=1 ${cursor ? 'AND m.moment_id<?' : ''}
       ${circleSql}
       ORDER BY m.moment_id DESC`
    ).iterate(...(cursor ? [cursor] : [])); // 找满一页可见内容再停止，避免前 200 条不可见导致假空页
    const visible = [];
    for (const m of rows) {
      // 好友门：仅主时间线（无 visibility 参数）生效——非自己且非好友的动态不进主 feed；
      // 圈子聚合页跳过好友门，改用作者关系判定 + canSeeMoment
      if (!visibility && m.author_id !== ctx.user.id && !isFriend(db, ctx.user.id, m.author_id)) continue;
      // 圈页关系门：非自己的作者须与 viewer 同校同届（classmates）或家乡同市（fellows）
      if (visibility && m.author_id !== ctx.user.id) {
        const related = visibility === 'classmates'
          ? sharesSameGrade(db, ctx.user.id, m.author_id)
          : sharesHometown(db, ctx.user.id, m.author_id);
        if (!related) continue;
      }
      const author = getUser(db, m.author_id);
      if (author && canSeeMoment(db, ctx.user, m, author, ctx)) visible.push(m);
      if (visible.length > limit) break;
    }
    const hasMore = visible.length > limit;
    const items = visible.slice(0, limit);
    return ok(ctx, {
      items: items.map((m) => momentOut(db, ctx.user, m, getUser(db, m.author_id))),
      next_cursor: hasMore ? String(items[items.length - 1].moment_id) : null,
    });
  });

  // 互动未读提示：我的动态上 since 之后是否有他人点赞/评论（红点轮询用）
  // 注意注册在 /v1/moments/:moment_id 之前（router 先注册先匹配）
  router.get('/v1/moments/interactions/unread', { auth: true }, (ctx) => {
    if (ctx.query.since !== undefined && !isInt(ctx.query.since)) throw E.param('since 须为 epoch 毫秒');
    const since = isInt(ctx.query.since) ? Number(ctx.query.since) : 0;
    if (since < 0 || !Number.isFinite(new Date(since).getTime())) throw E.param('since 超出有效时间范围');
    const sinceIso = new Date(since).toISOString(); // created_at 为 ISO 字符串，同格式按字符串比较
    const like = q1(
      db,
      `SELECT 1 x FROM moment_likes l JOIN moments m ON m.moment_id=l.moment_id
       WHERE m.author_id=? AND m.deleted=0 AND l.user_id!=? AND l.created_at>? LIMIT 1`,
      ctx.user.id, ctx.user.id, sinceIso
    );
    const comment = like ? null : q1(
      db,
      `SELECT 1 x FROM moment_comments c JOIN moments m ON m.moment_id=c.moment_id
       WHERE m.author_id=? AND m.deleted=0 AND c.deleted=0 AND c.from_user!=? AND c.created_at>? LIMIT 1`,
      ctx.user.id, ctx.user.id, sinceIso
    );
    return ok(ctx, { has_new: !!(like || comment) });
  });

  // 某用户相册页：陌生人范围由隐私设置控制（stranger_moments_10 → 仅最近 10 条）
  router.get('/v1/users/:user_id/moments', { auth: true }, (ctx) => {
    const author = getUser(db, Number(ctx.params.user_id));
    if (!author || author.status !== 1) throw E.notFound('用户不存在');
    if (needsGroupUnlock(db, ctx.user, author.id) && !hasGroupUnlock(db, ctx)) {
      throw E.privacy('该联系人在你的高隐私分组中，输入隐私密码后查看', { locked: true });
    }
    const stranger = author.id !== ctx.user.id && !isFriend(db, ctx.user.id, author.id);
    const rows = q(
      db,
      'SELECT * FROM moments WHERE author_id=? AND deleted=0 ORDER BY moment_id DESC LIMIT 100',
      author.id
    ).filter((m) => canSeeMoment(db, ctx.user, m, author, ctx));
    const limited = stranger ? rows.slice(0, 10) : rows; // 陌生人十条（§10.5）
    return ok(ctx, { items: limited.map((m) => momentOut(db, ctx.user, m, author)) });
  });

  // 动态详情
  router.get('/v1/moments/:moment_id', { auth: true }, (ctx) => {
    const m = getMoment(db, Number(ctx.params.moment_id));
    const author = getUser(db, m.author_id);
    if (!canSeeMoment(db, ctx.user, m, author, ctx)) throw E.privacy('无权查看该动态');
    return ok(ctx, momentOut(db, ctx.user, m, author, { detail: true }));
  });

  // 删除动态：仅作者
  router.delete('/v1/moments/:moment_id', { auth: true }, (ctx) => {
    const m = getMoment(db, Number(ctx.params.moment_id));
    if (m.author_id !== ctx.user.id) throw E.privacy('只能删除自己的动态');
    run(db, 'UPDATE moments SET deleted=1 WHERE moment_id=?', m.moment_id);
    audit(db, { userId: ctx.user.id, event: 'moment_delete', targetId: m.moment_id });
    return ok(ctx);
  });

  // 点赞 / 取消
  router.post('/v1/moments/:moment_id/likes', { auth: true }, (ctx) => {
    // 互动日频控：防刷赞（发布另有 30/日）
    if (!hitRate(db, `moment_like:${ctx.user.id}:day`, 100, 86400).allowed) throw E.rate('今日点赞已达上限');
    const m = getMoment(db, Number(ctx.params.moment_id));
    const author = getUser(db, m.author_id);
    if (!canSeeMoment(db, ctx.user, m, author, ctx)) throw E.privacy('无权操作该动态');
    run(db, 'INSERT OR IGNORE INTO moment_likes(moment_id,user_id,created_at) VALUES(?,?,?)', m.moment_id, ctx.user.id, now());
    return ok(ctx);
  });

  router.delete('/v1/moments/:moment_id/likes', { auth: true }, (ctx) => {
    run(db, 'DELETE FROM moment_likes WHERE moment_id=? AND user_id=?', Number(ctx.params.moment_id), ctx.user.id);
    return ok(ctx);
  });

  // 评论/回复（≤500 字，45001 同样生效）
  router.post('/v1/moments/:moment_id/comments', { auth: true }, (ctx) => {
    if (!hitRate(db, `moment_comment:${ctx.user.id}:day`, 100, 86400).allowed) throw E.rate('今日评论已达上限');
    const m = getMoment(db, Number(ctx.params.moment_id));
    const author = getUser(db, m.author_id);
    if (!canSeeMoment(db, ctx.user, m, author, ctx)) throw E.privacy('无权评论该动态');
    const { content, reply_to_user_id } = ctx.body || {};
    if (!content || [...String(content)].length > 500) throw E.param('评论必填且不超过 500 字');
    if (containsContactInfo(String(content))) {
      audit(db, { userId: ctx.user.id, event: 'content_block', scene: 'moment_comment' });
      throw E.content('评论包含联系方式或导流信息，已被拦截');
    }
    const info = run(
      db,
      'INSERT INTO moment_comments(moment_id,from_user,reply_to_user_id,content,created_at) VALUES(?,?,?,?,?)',
      m.moment_id, ctx.user.id, reply_to_user_id ? Number(reply_to_user_id) : null, String(content), now()
    );
    audit(db, { userId: ctx.user.id, event: 'moment_comment', targetId: m.moment_id });
    return ok(ctx, { comment_id: Number(info.lastInsertRowid) });
  });
}
