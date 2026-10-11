import { q, q1, run, audit, getUser, getPrivacy, regionChain, isFriend, isBlockedBetween } from '../repo.js';
import { ok, E } from '../http/respond.js';
import { isInt, now, maskName } from '../util.js';
import { containsContactInfo } from '../engine/index.js';
import { hitRate } from '../rate.js';
import { getIMProvider } from '../im/provider.js';
import { toUserBrief } from './users.js';

// 家乡页（《DIMI围城_家乡页与共建体系设计_V1》§10，M1 范围）：
// 镇级页（regions level=4）+ 投稿（最新区）+ 浏览去重 + 点赞/关注 + 公开落地页数据。
// M1 不做：热度榜/名片区/置顶/守护人（pinned_by/pinned_at/heat/gift_coins 字段保留待 M2 消费）。
// 投稿资格与老乡圈同边界：作者籍贯（user_hometowns type=1）与目标镇市级前缀（前 4 位）一致。
const CATEGORIES = ['scenery', 'product', 'craft', 'story'];
const PAGE_SIZE = 20;
const ROLLUP_THRESHOLD = 5; // 镇页内容 <5 条时触发同县兜底
const VIEW_DEDUP_MS = 24 * 3600 * 1000; // 浏览去重：同人同内容 24h 计 1 次

// 镇级行政区划校验：家乡页以镇（regions level=4）为单位
function requireTown(db, code) {
  const region = q1(db, 'SELECT * FROM regions WHERE code=? AND is_active=1', String(code ?? ''));
  if (!region) throw E.notFound('行政区划不存在');
  if (region.level !== 4) throw E.param('家乡页以乡镇/街道（四级行政区划）为单位');
  return region;
}

// 页面记录不存在则自动创建（INSERT OR IGNORE 幂等，并发安全）。
// 仅写路径（投稿/关注）调用；GET 页聚合为懒返回缺省，不在读路径落库
function getOrCreatePage(db, regionCode) {
  run(
    db,
    'INSERT OR IGNORE INTO hometown_pages(region_code,created_at,updated_at) VALUES(?,?,?)',
    regionCode, now(), now()
  );
  return q1(db, 'SELECT * FROM hometown_pages WHERE region_code=?', regionCode);
}

// 页内容计数：查询时实时 COUNT（仅 published），不依赖 hometown_pages.content_count 冗余列
function liveContentCount(db, regionCode) {
  return q1(db, "SELECT COUNT(*) c FROM hometown_contents WHERE region_code=? AND status='published'", regionCode).c;
}

// 作者家乡可见性双入口（与 users.js 资料卡门禁同口径）：
// user_hometowns.visibility（逐条家乡记录）与 privacy_settings.hometown_visibility（全局设置）。
// - 任一为 private → 其家乡页内容对非作者一律缺省（列表过滤 / 详情 41001）；
// - 公开落地页再收紧：仅两者均 public 的作者内容入选
function hometownVisibilityOf(db, authorId) {
  const rec = q1(db, 'SELECT visibility FROM user_hometowns WHERE user_id=? AND type=1', authorId);
  const author = getUser(db, authorId);
  return {
    record: rec?.visibility ?? 'public',
    privacy: author ? getPrivacy(db, author).hometown_visibility : 'private',
  };
}

// 投稿资格：我籍贯（type=1）与目标镇同市（前 4 位一致，与老乡圈/老乡群同边界）
function canPostTo(db, userId, regionCode) {
  const hometown = q1(db, 'SELECT region_code FROM user_hometowns WHERE user_id=? AND type=1', userId);
  if (!hometown) return false;
  return String(hometown.region_code).slice(0, 4) === String(regionCode).slice(0, 4);
}

// 返回 null 表示对当前 viewer 缺省（作者家乡可见性 private），调用方过滤/404
function contentOut(db, viewer, row, { rolledUp = false } = {}) {
  const author = getUser(db, row.author_id);
  if (!author || author.status !== 1 || isBlockedBetween(db, viewer.id, author.id)) return null;
  // 作者隐私口径：作者家乡可见性任一入口为 private 时，其内容对非作者一律缺省
  if (author && viewer.id !== author.id) {
    const vis = hometownVisibilityOf(db, author.id);
    if (vis.record === 'private' || vis.privacy === 'private') return null;
    const friend = isFriend(db, viewer.id, author.id);
    if ([vis.record, vis.privacy].includes('friends') && !friend) return null;
    if ([vis.record, vis.privacy].includes('fellows_only') && !friend) {
      const hometown = q1(db, 'SELECT region_code FROM user_hometowns WHERE user_id=? AND type=1', viewer.id);
      const ownerHome = q1(db, 'SELECT region_code FROM user_hometowns WHERE user_id=? AND type=1', author.id);
      if (!hometown || !ownerHome || hometown.region_code.slice(0, 4) !== ownerHome.region_code.slice(0, 4)) return null;
    }
  }
  const liked = !!q1(
    db,
    'SELECT 1 x FROM hometown_content_likes WHERE content_id=? AND user_id=?',
    row.content_id, viewer.id
  );
  const out = {
    content_id: row.content_id,
    region_code: row.region_code,
    category: row.category,
    title: row.title,
    body: row.body ?? '',
    media: JSON.parse(row.media || '[]'),
    author: author ? toUserBrief(db, viewer, author, { scene: 'moment' }) : null,
    view_count: row.view_count,
    like_count: row.like_count,
    liked,
    created_at: row.created_at,
  };
  if (rolledUp) out.rolled_up = true; // 低密度兜底：同县其他镇内容标记
  return out;
}

// All article interactions share the detail endpoint's visibility rules.
export function requireVisibleHometownContent(db, viewer, id) {
  if (!isInt(id) || Number(id) <= 0) throw E.param('id 须为正整数');
  const row = q1(db, 'SELECT * FROM hometown_contents WHERE content_id=?', Number(id));
  if (!row || row.status !== 'published' || !contentOut(db, viewer, row)) {
    throw E.notFound('内容不存在或已下架');
  }
  return row;
}

export function registerHometownPagesRoutes(router, { db, config, storage }) {
  // 我关注的家乡页列表（须在 /:region_code 参数路由之前注册，先注册先匹配）
  router.get('/v1/hometown-pages/followed/mine', { auth: true }, (ctx) => {
    const rows = q(
      db,
      `SELECT f.region_code, f.created_at followed_at FROM hometown_follows f
       WHERE f.user_id=? ORDER BY f.created_at DESC LIMIT 100`,
      ctx.user.id
    );
    const items = rows.map((r) => {
      const chain = regionChain(db, r.region_code);
      const page = q1(db, 'SELECT * FROM hometown_pages WHERE region_code=?', r.region_code);
      return {
        region_code: r.region_code,
        region_path: chain.map((c) => c.name),
        cover_media: page?.cover_media ?? null,
        follower_count: page?.follower_count ?? 0,
        content_count: liveContentCount(db, r.region_code),
        followed_at: r.followed_at,
      };
    });
    return ok(ctx, { items });
  });

  // 家乡页聚合：简介/封面/关注与投稿资格/老乡群入口卡。
  // 懒返回缺省：页面记录不存在时返回 region_path + 零计数，不在读路径落库；
  // 建页只在写路径发生（首次投稿 / 首次关注，见 getOrCreatePage）
  router.get('/v1/hometown-pages/:region_code', { auth: true }, (ctx) => {
    const code = String(ctx.params.region_code);
    requireTown(db, code);
    const page = q1(db, 'SELECT * FROM hometown_pages WHERE region_code=?', code);
    const chain = regionChain(db, code);
    // 老乡群入口卡：该市（前 4 位前缀）老乡群，复用 hometown_groups（未创建为 null）
    const groupRow = q1(db, 'SELECT * FROM hometown_groups WHERE region_prefix=?', code.slice(0, 4));
    let group = null;
    if (groupRow) {
      const conv = q1(db, 'SELECT * FROM conversations WHERE conv_id=?', groupRow.conv_id);
      group = {
        conv_id: groupRow.conv_id,
        title: conv?.title ?? null,
        member_count: getIMProvider(db, config).convMemberCount(groupRow.conv_id),
      };
    }
    return ok(ctx, {
      region_code: code,
      region_path: chain.map((c) => c.name), // 省市区镇名称逐级数组
      cover_media: page?.cover_media ?? null,
      intro: page?.intro ?? '',
      follower_count: page?.follower_count ?? 0,
      content_count: liveContentCount(db, code), // 实时 COUNT（published），不读冗余列
      is_following: !!q1(db, 'SELECT 1 x FROM hometown_follows WHERE user_id=? AND region_code=?', ctx.user.id, code),
      can_post: canPostTo(db, ctx.user.id, code),
      group,
    });
  });

  // 内容分页（最新区）：倒序 cursor 分页 20 条；低密度兜底：镇内容 <5 条且无 cursor 时
  // 附加同县（前 6 位）其他镇最新内容最多 5 条（rolled_up:true 标记）
  router.get('/v1/hometown-pages/:region_code/contents', { auth: true }, (ctx) => {
    const code = String(ctx.params.region_code);
    requireTown(db, code);
    const { category } = ctx.query;
    if (category !== undefined && !CATEGORIES.includes(category)) {
      throw E.param(`category 仅支持 ${CATEGORIES.join(' / ')}`);
    }
    if (ctx.query.cursor !== undefined && !isInt(ctx.query.cursor)) throw E.param('cursor 须为整数');
    const cursor = isInt(ctx.query.cursor) ? Number(ctx.query.cursor) : null;
    const catSql = category ? 'AND c.category=?' : '';
    const catParams = category ? [category] : [];
    const visible = [];
    const rows = db.prepare(
      `SELECT c.* FROM hometown_contents c JOIN users u ON u.id=c.author_id
       WHERE c.region_code=? AND c.status='published' AND u.status=1
       ${catSql} ${cursor ? 'AND c.content_id<?' : ''}
       ORDER BY c.content_id DESC`
    ).iterate(code, ...catParams, ...(cursor ? [cursor] : []));
    for (const row of rows) {
      const item = contentOut(db, ctx.user, row);
      if (item) visible.push(item);
      if (visible.length > PAGE_SIZE) break;
    }
    const hasMore = visible.length > PAGE_SIZE;
    const items = visible.slice(0, PAGE_SIZE);
    const rollupItems = [];
    // 用当前分类下可见内容数判断兜底，避免隐私内容挤占首屏。
    if (!cursor && items.length < ROLLUP_THRESHOLD) {
      const nearby = db.prepare(
        `SELECT c.* FROM hometown_contents c JOIN users u ON u.id=c.author_id
         WHERE substr(c.region_code,1,6)=? AND c.region_code!=? AND c.status='published' AND u.status=1
         ${catSql} ORDER BY c.content_id DESC`
      ).iterate(code.slice(0, 6), code, ...catParams);
      for (const row of nearby) {
        const item = contentOut(db, ctx.user, row, { rolledUp: true });
        if (item) rollupItems.push(item);
        if (rollupItems.length >= ROLLUP_THRESHOLD) break;
      }
    }
    return ok(ctx, {
      items,
      rollup_items: rollupItems,
      rolled_up: rollupItems.length > 0,
      next_cursor: hasMore ? String(items[items.length - 1].content_id) : null,
    });
  });

  // 投稿：幂等（Idempotency-Key 走通用幂等层）；资格门禁（40301）+ 频控 5 条/日/人（42901）
  // + 联系方式拦截（45001，机器拦截即初审，M1 无审核队列，通过直接 published）
  router.post('/v1/hometown-contents', { auth: true }, (ctx) => {
    const { region_code, category, title, body, media = [] } = ctx.body || {};
    const code = String(region_code ?? '');
    requireTown(db, code);
    if (!CATEGORIES.includes(category)) throw E.param(`category 仅支持 ${CATEGORIES.join(' / ')}`);
    if (typeof title !== 'string' || !title.trim() || [...title].length > 60) throw E.param('标题必填且不超过 60 字');
    if (body != null && (typeof body !== 'string' || [...body].length > 20000)) throw E.param('正文不超过 20000 字');
    if (!Array.isArray(media) || media.length > 9) throw E.param('media 最多 9 张图');
    // 与动态同一约定：/misc/upload 返回的 url 原样提交，storage 分层校验形态
    if (!media.every((m) => typeof m === 'string' && storage.isValidMediaUrl(m))) {
      throw E.param('media 元素须为 /misc/upload 返回的媒体 url（jpg/jpeg/png/webp）');
    }
    if (!canPostTo(db, ctx.user.id, code)) {
      throw E.privacy('只有当地老乡才能向该家乡页投稿');
    }
    // 内容安全：标题+正文联系方式/引流拦截（45001，与动态同一套规则）
    if (containsContactInfo(String(title)) || (body && containsContactInfo(String(body)))) {
      audit(db, { userId: ctx.user.id, event: 'content_block', scene: 'hometown_content' });
      throw E.content('内容包含联系方式或导流信息，已被拦截');
    }
    // 频控 5 条/日/人：先只读预检（校验失败/45001 不占额度），INSERT 成功后才经 hitRate 计数
    const day = new Date().toISOString().slice(0, 10);
    const postKey = `hometown_post:${ctx.user.id}:${day}`;
    const cnt = q1(db, 'SELECT count, reset_at FROM rate_counters WHERE key=?', postKey);
    if (cnt && cnt.reset_at > Date.now() && cnt.count >= 5) {
      throw E.rate('今日投稿已达上限（5 条/日）');
    }
    const info = run(
      db,
      `INSERT INTO hometown_contents(region_code,author_id,category,title,body,media,status,created_at,updated_at)
       VALUES(?,?,?,?,?,?,'published',?,?)`,
      code, ctx.user.id, category, String(title), body == null ? null : String(body),
      JSON.stringify(media.map(String)), now(), now()
    );
    hitRate(db, postKey, 5, 86400); // 落库成功后计入当日额度
    const contentId = Number(info.lastInsertRowid);
    getOrCreatePage(db, code); // 首次投稿自动建页（写路径建页；GET 页聚合为懒返回缺省）
    audit(db, { userId: ctx.user.id, event: 'hometown_content_publish', targetId: contentId, input: { region_code: code, category } });
    const row = q1(db, 'SELECT * FROM hometown_contents WHERE content_id=?', contentId);
    return ok(ctx, contentOut(db, ctx.user, row));
  });

  // 内容详情 + 浏览计数（hometown_views 去重：同人 24h 只计 1 次，超时再访重新计数并刷新位点）
  // JOIN users 过滤注销/停用作者（u.status=1）；作者家乡可见性 private 时对非作者按 41001 缺省
  router.get('/v1/hometown-contents/:id', { auth: true }, (ctx) => {
    if (!isInt(ctx.params.id)) throw E.param('id 须为整数');
    const row = q1(
      db,
      `SELECT c.* FROM hometown_contents c JOIN users u ON u.id=c.author_id
       WHERE c.content_id=? AND u.status=1`,
      Number(ctx.params.id)
    );
    if (!row || row.status !== 'published') throw E.notFound('内容不存在或已下架');
    const out = contentOut(db, ctx.user, row);
    if (!out) throw E.notFound('内容不存在或已下架'); // 作者隐私缺省，不反向暴露
    const view = q1(db, 'SELECT * FROM hometown_views WHERE content_id=? AND viewer_id=?', row.content_id, ctx.user.id);
    const dedupFloorIso = new Date(Date.now() - VIEW_DEDUP_MS).toISOString();
    if (!view || view.viewed_at <= dedupFloorIso) {
      run(
        db,
        `INSERT INTO hometown_views(content_id,viewer_id,viewed_at) VALUES(?,?,?)
         ON CONFLICT(content_id,viewer_id) DO UPDATE SET viewed_at=excluded.viewed_at`,
        row.content_id, ctx.user.id, now()
      );
      run(db, 'UPDATE hometown_contents SET view_count=view_count+1 WHERE content_id=?', row.content_id);
      row.view_count += 1;
    }
    return ok(ctx, contentOut(db, ctx.user, row));
  });

  // 作者可删除投稿；保留审核记录，所有读路径统一排除已删除内容。
  router.delete('/v1/hometown-contents/:id', { auth: true }, (ctx) => {
    if (!isInt(ctx.params.id)) throw E.param('id 须为整数');
    const row = q1(db, 'SELECT * FROM hometown_contents WHERE content_id=?', Number(ctx.params.id));
    if (!row) throw E.notFound('内容不存在或已下架');
    if (row.author_id !== ctx.user.id) throw E.privacy('只能删除自己发布的内容');
    run(db, "UPDATE hometown_contents SET status='removed',updated_at=? WHERE content_id=?", now(), row.content_id);
    audit(db, { userId: ctx.user.id, event: 'hometown_content_delete', targetId: row.content_id });
    return ok(ctx);
  });

  // 点赞 / 取消：明细表 PRIMARY KEY 幂等，like_count 同步增减
  router.post('/v1/hometown-contents/:id/like', { auth: true }, (ctx) => {
    // 互动日频控：防刷赞（与动态点赞同口径 100/日）
    if (!hitRate(db, `hometown_like:${ctx.user.id}:day`, 100, 86400).allowed) throw E.rate('今日点赞已达上限');
    if (!isInt(ctx.params.id)) throw E.param('id 须为整数');
    const row = q1(db, 'SELECT * FROM hometown_contents WHERE content_id=?', Number(ctx.params.id));
    if (!row || row.status !== 'published') throw E.notFound('内容不存在或已下架');
    if (!contentOut(db, ctx.user, row)) throw E.notFound('内容不存在或已下架');
    const info = run(
      db,
      'INSERT OR IGNORE INTO hometown_content_likes(content_id,user_id,created_at) VALUES(?,?,?)',
      row.content_id, ctx.user.id, now()
    );
    if (Number(info.changes) > 0) {
      run(db, 'UPDATE hometown_contents SET like_count=like_count+1 WHERE content_id=?', row.content_id);
    }
    const fresh = q1(db, 'SELECT like_count FROM hometown_contents WHERE content_id=?', row.content_id);
    return ok(ctx, { like_count: fresh.like_count, liked: true });
  });

  router.delete('/v1/hometown-contents/:id/like', { auth: true }, (ctx) => {
    if (!isInt(ctx.params.id)) throw E.param('id 须为整数');
    const row = q1(db, 'SELECT * FROM hometown_contents WHERE content_id=?', Number(ctx.params.id));
    if (!row || row.status !== 'published') throw E.notFound('内容不存在或已下架');
    if (!contentOut(db, ctx.user, row)) throw E.notFound('内容不存在或已下架');
    const info = run(
      db,
      'DELETE FROM hometown_content_likes WHERE content_id=? AND user_id=?',
      row.content_id, ctx.user.id
    );
    if (Number(info.changes) > 0) {
      run(db, 'UPDATE hometown_contents SET like_count=MAX(like_count-1,0) WHERE content_id=?', row.content_id);
    }
    const fresh = q1(db, 'SELECT like_count FROM hometown_contents WHERE content_id=?', row.content_id);
    return ok(ctx, { like_count: fresh.like_count, liked: false });
  });

  // 关注 / 取关家乡：PRIMARY KEY 幂等，follower_count 同步增减；互动日频控 100 次/日（42901，防刷关注）
  router.post('/v1/hometown-pages/:region_code/follow', { auth: true }, (ctx) => {
    if (!hitRate(db, `hometown_follow:${ctx.user.id}:day`, 100, 86400).allowed) throw E.rate('今日关注/取关操作已达上限');
    const code = String(ctx.params.region_code);
    requireTown(db, code);
    const page = getOrCreatePage(db, code);
    const info = run(
      db,
      'INSERT OR IGNORE INTO hometown_follows(user_id,region_code,created_at) VALUES(?,?,?)',
      ctx.user.id, code, now()
    );
    if (Number(info.changes) > 0) {
      run(db, 'UPDATE hometown_pages SET follower_count=follower_count+1, updated_at=? WHERE page_id=?', now(), page.page_id);
      audit(db, { userId: ctx.user.id, event: 'hometown_follow', targetId: page.page_id, input: { region_code: code } });
    }
    const fresh = q1(db, 'SELECT follower_count FROM hometown_pages WHERE page_id=?', page.page_id);
    return ok(ctx, { follower_count: fresh.follower_count, is_following: true });
  });

  router.delete('/v1/hometown-pages/:region_code/follow', { auth: true }, (ctx) => {
    if (!hitRate(db, `hometown_follow:${ctx.user.id}:day`, 100, 86400).allowed) throw E.rate('今日关注/取关操作已达上限');
    const code = String(ctx.params.region_code);
    requireTown(db, code);
    const info = run(db, 'DELETE FROM hometown_follows WHERE user_id=? AND region_code=?', ctx.user.id, code);
    if (Number(info.changes) > 0) {
      run(db, 'UPDATE hometown_pages SET follower_count=MAX(follower_count-1,0), updated_at=? WHERE region_code=?', now(), code);
      audit(db, { userId: ctx.user.id, event: 'hometown_unfollow', input: { region_code: code } });
    }
    const page = q1(db, 'SELECT follower_count FROM hometown_pages WHERE region_code=?', code);
    return ok(ctx, { follower_count: page?.follower_count ?? 0, is_following: false });
  });

  // 公开落地页数据（免鉴权，H5 用）：不含 body 全文、不含作者 id，作者昵称掩码（maskName，与召集令一致）；
  // 页面积懒返回缺省（公共读路径不写库），无页面记录时返回缺省计数；
  // 作者口径收紧：仅作者家乡可见性双入口均 public 的内容入选；
  // 按 IP 低频限 60 次/小时（42901，防爬取批量抓取落地页）
  router.get('/v1/public/hometown-pages/:region_code', (ctx) => {
    const ip = ctx.req.socket.remoteAddress || 'unknown';
    if (!hitRate(db, `pub_hometown_page:${ip}:hour`, 60, 3600).allowed) {
      throw E.rate('访问过于频繁，请稍后再试', null);
    }
    const code = String(ctx.params.region_code);
    const region = requireTown(db, code);
    const page = q1(db, 'SELECT * FROM hometown_pages WHERE region_code=?', code);
    const rows = [];
    const candidates = db.prepare(
      `SELECT c.*, u.nickname FROM hometown_contents c JOIN users u ON u.id=c.author_id
       WHERE c.region_code=? AND c.status='published' AND u.status=1
       ORDER BY c.content_id DESC`
    ).iterate(code);
    for (const row of candidates) {
      const vis = hometownVisibilityOf(db, row.author_id);
      if (vis.record === 'public' && vis.privacy === 'public') rows.push(row);
      if (rows.length >= 10) break;
    }
    return ok(ctx, {
      region_code: code,
      region_name: region.name,
      cover_media: page?.cover_media ?? null,
      intro: page?.intro ?? '',
      follower_count: page?.follower_count ?? 0,
      items: rows.map((r) => ({
        category: r.category,
        title: r.title,
        cover: JSON.parse(r.media || '[]')[0] ?? null,
        view_count: r.view_count,
        author_nickname: maskName(r.nickname),
        created_at: r.created_at,
      })),
    });
  });
}
