import { q, q1, run, audit, getUser, isBlockedBetween } from '../repo.js';
import { ok, E } from '../http/respond.js';
import { isInt, now, uuid } from '../util.js';
import { containsContactInfo, rules } from '../engine/index.js';
import { hitRate } from '../rate.js';
import { withTx, creditCoins, debitCoins } from '../coins.js';
import { toUserBrief } from './users.js';
import { requireVisibleHometownContent } from './hometownPages.js';

// Hometown comments are visible to the article's readers. Blocked/deactivated
// commenters are omitted; personal moments retain their mutual-friend rules.
const COMMENT_VISIBLE = `c.content_id=? AND c.deleted=0 AND u.status=1
  AND NOT EXISTS (SELECT 1 FROM blocks b WHERE
    (b.user_id=? AND b.blocked_id=c.from_user) OR
    (b.user_id=c.from_user AND b.blocked_id=?))`;

export function registerHometownInteractions(router, { db }) {
  router.get('/v1/hometown-contents/:id/comments', { auth: true }, (ctx) => {
    const article = requireVisibleHometownContent(db, ctx.user, ctx.params.id);
    const cursor = ctx.query.cursor;
    if (cursor !== undefined && (!isInt(cursor) || Number(cursor) <= 0)) throw E.param('cursor 须为正整数');
    const params = [article.content_id, ctx.user.id, ctx.user.id];
    const rows = q(db, `SELECT c.* FROM hometown_comments c JOIN users u ON u.id=c.from_user
      WHERE ${COMMENT_VISIBLE} ${cursor ? 'AND c.id<?' : ''} ORDER BY c.id DESC LIMIT 21`,
    ...params, ...(cursor ? [Number(cursor)] : []));
    const total = q1(db, `SELECT COUNT(*) n FROM hometown_comments c JOIN users u ON u.id=c.from_user
      WHERE ${COMMENT_VISIBLE}`, ...params).n;
    const items = rows.slice(0, 20).map(c => ({
      id: c.id, content: c.content, created_at: c.created_at,
      from_user: toUserBrief(db, ctx.user, getUser(db, c.from_user), { scene: 'moment' }),
      can_delete: c.from_user === ctx.user.id || article.author_id === ctx.user.id,
    }));
    return ok(ctx, { items, total_count: total, next_cursor: rows.length > 20 ? String(items.at(-1).id) : null });
  });

  router.post('/v1/hometown-contents/:id/comments', { auth: true }, (ctx) => {
    const article = requireVisibleHometownContent(db, ctx.user, ctx.params.id);
    const text = ctx.body?.content;
    if (typeof text !== 'string' || !text.trim() || [...text.trim()].length > 500) throw E.param('评论必填且不超过 500 字');
    if (containsContactInfo(text)) {
      audit(db, { userId: ctx.user.id, event: 'content_block', scene: 'hometown_comment' });
      throw E.content('评论包含联系方式或导流信息，已被拦截');
    }
    if (!hitRate(db, `hometown_comment:${ctx.user.id}:day`, 100, 86400).allowed) throw E.rate('今日评论已达上限');
    const info = run(db, 'INSERT INTO hometown_comments(content_id,from_user,content,created_at) VALUES(?,?,?,?)',
      article.content_id, ctx.user.id, text.trim(), now());
    audit(db, { userId: ctx.user.id, event: 'hometown_comment', targetId: article.content_id });
    return ok(ctx, { comment_id: Number(info.lastInsertRowid) });
  });

  router.delete('/v1/hometown-contents/:id/comments/:comment_id', { auth: true }, (ctx) => {
    const article = requireVisibleHometownContent(db, ctx.user, ctx.params.id);
    if (!isInt(ctx.params.comment_id)) throw E.param('comment_id 须为整数');
    const comment = q1(db, 'SELECT * FROM hometown_comments WHERE id=? AND content_id=?', Number(ctx.params.comment_id), article.content_id);
    if (!comment) throw E.notFound('评论不存在');
    if (comment.from_user !== ctx.user.id && article.author_id !== ctx.user.id) throw E.privacy('只能删除自己的评论或自己文章下的评论');
    run(db, 'UPDATE hometown_comments SET deleted=1 WHERE id=?', comment.id);
    audit(db, { userId: ctx.user.id, event: 'hometown_comment_delete', targetId: comment.id });
    return ok(ctx);
  });

  router.post('/v1/hometown-contents/:id/gifts', { auth: true }, (ctx) => {
    const article = requireVisibleHometownContent(db, ctx.user, ctx.params.id);
    if (article.author_id === ctx.user.id) throw E.param('不能给自己的文章打赏');
    const raw = ctx.body?.coin_amount;
    if (!isInt(raw) || !rules.gift.denominations.includes(Number(raw))) throw E.param(`打赏面额仅支持 ${rules.gift.denominations.join(' / ')} 觅豆`);
    const amount = Number(raw);
    const orderId = `H${uuid().replace(/-/g, '').slice(0, 24)}`;
    const { balance } = withTx(db, () => {
      // Rate counter, debit, credit, order and aggregate commit together.
      if (!hitRate(db, `gift_send:${ctx.user.id}:day`, rules.gift.daily_limit, 86400).allowed) throw E.rate('今日打赏次数已达上限');
      const result = debitCoins(db, { userId: ctx.user.id, bizType: 'gift_send', bizId: orderId, amount, remark: '打赏家乡文章' });
      creditCoins(db, { userId: article.author_id, bizType: 'gift_recv', bizId: orderId, amount, remark: '收到家乡文章打赏' });
      run(db, `INSERT INTO gift_orders(order_id,from_user,to_user,hometown_content_id,coin_amount,status,created_at)
        VALUES(?,?,?,?,?,'confirmed',?)`, orderId, ctx.user.id, article.author_id, article.content_id, amount, now());
      run(db, 'UPDATE hometown_contents SET gift_coins=gift_coins+? WHERE content_id=?', amount, article.content_id);
      return result;
    });
    audit(db, { userId: ctx.user.id, event: 'hometown_gift_send', targetId: article.content_id, input: { order_id: orderId, amount } });
    return ok(ctx, { order_id: orderId, coin_amount: amount, to_user_id: article.author_id, balance });
  });

  router.get('/v1/hometown-contents/:id/gifts', { auth: true }, (ctx) => {
    const article = requireVisibleHometownContent(db, ctx.user, ctx.params.id);
    const where = "hometown_content_id=? AND status='confirmed'";
    const total = q1(db, `SELECT COUNT(*) n, COALESCE(SUM(coin_amount),0) coins FROM gift_orders WHERE ${where}`, article.content_id);
    const rows = q(db, `SELECT * FROM gift_orders WHERE ${where} ORDER BY created_at DESC, order_id DESC LIMIT 50`, article.content_id);
    return ok(ctx, { total_count: total.n, total_coins: total.coins, items: rows.map(g => {
      const u = getUser(db, g.from_user);
      return {
        from_user: u?.status === 1 && !isBlockedBetween(db, ctx.user.id, u.id)
          ? toUserBrief(db, ctx.user, u, { scene: 'gift' }) : null,
        coin_amount: g.coin_amount, created_at: g.created_at,
      };
    }) });
  });
}
