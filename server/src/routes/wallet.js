import crypto from 'node:crypto';
import { q, q1, run, audit, getUser, isFriend, isBlockedBetween } from '../repo.js';
import { ok, E } from '../http/respond.js';
import { isInt, now, uuid } from '../util.js';
import { hitRate } from '../rate.js';
import { rules } from '../engine/index.js';
import { getIMProvider } from '../im/provider.js';
import { withTx, ensureCoinAccount, coinBalance, creditCoins, debitCoins, grantTask } from '../coins.js';
import { canSeeMoment } from './moments.js';
import { toUserBrief } from './users.js';

// 觅豆钱包 / 红包 / 动态打赏（P0 纯赠送体系，《DIMI围城_虚拟币与打赏体系设计_V1.md》§1.3/§4/§6/§8.3）
// 红线（V3.1 A8）：无充值、无提现、无现金价值；币来源仅任务赠送（coins.js grantTask）。
// 幂等：写接口全部走 app.js 通用幂等层（Idempotency-Key）+ 流水唯一键双保险；
// 红包消息卡由服务端在发红包同事务内代发（client_msg_id=rp:{packet_id}），客户端不得自行拼卡。
export function registerWalletRoutes(router, { db, config }) {
  const im = () => getIMProvider(db, config);

  // ---------- 钱包 ----------
  router.get('/v1/wallet', { auth: true }, (ctx) => {
    const acc = ensureCoinAccount(db, ctx.user.id);
    const today = now().slice(0, 10);
    const grants = new Set(
      q(db, "SELECT biz_id FROM coin_transactions WHERE user_id=? AND biz_type='grant_task' AND direction='in'", ctx.user.id)
        .map((r) => r.biz_id)
    );
    const tasks = Object.entries(rules.coin_tasks)
      .filter(([code]) => code !== 'comment')
      .map(([code, conf]) => ({
        code,
        amount: conf.amount,
        period: conf.period,
        remark: conf.remark,
        done: conf.period === 'day'
          ? grants.has(`${code}:${today}`)
          : conf.period === 'once'
            ? grants.has(`${code}:all`)
            : false, // per_target 无"完成"态，按次数累计
      }));
    return ok(ctx, {
      balance: acc.balance,
      total_earned: acc.total_earned,
      total_spent: acc.total_spent,
      today_checked_in: grants.has(`daily_login:${today}`),
      tasks,
    });
  });

  router.get('/v1/wallet/transactions', { auth: true }, (ctx) => {
    const cursor = isInt(ctx.query.cursor) ? Number(ctx.query.cursor) : null;
    const limit = 20;
    const rows = q(
      db,
      `SELECT * FROM coin_transactions WHERE user_id=? ${cursor ? 'AND id<?' : ''} ORDER BY id DESC LIMIT ?`,
      ...[ctx.user.id, ...(cursor ? [cursor] : []), limit + 1]
    );
    const hasMore = rows.length > limit;
    const items = rows.slice(0, limit);
    return ok(ctx, {
      items: items.map((t) => ({
        id: t.id, biz_type: t.biz_type, direction: t.direction,
        amount: t.amount, balance_after: t.balance_after, remark: t.remark, created_at: t.created_at,
      })),
      next_cursor: hasMore ? String(items[items.length - 1].id) : null,
    });
  });

  // 每日打卡：每日活跃奖励 +5（幂等，当日重复打卡 granted=false）
  router.post('/v1/wallet/checkin', { auth: true }, (ctx) => {
    const r = grantTask(db, ctx.user.id, 'daily_login');
    return ok(ctx, { granted: r.granted, amount: r.amount, balance: coinBalance(db, ctx.user.id) });
  });

  // ---------- 红包 ----------
  // 班级群灰度门（V3.0 §18.4 同一原则）：单元注册数达 min_registered 才开放群红包
  function assertUnitGate(db, convId) {
    const minReg = rules.feature_gates?.red_packet?.min_registered ?? 0;
    if (!minReg) return;
    const group = q1(db, 'SELECT * FROM class_groups WHERE conv_id=?', convId);
    if (!group) return; // 非班级群（单聊）不走单元门
    const registered = q1(
      db,
      'SELECT COUNT(DISTINCT user_id) c FROM education_experiences WHERE school_id=? AND enroll_year=? AND class_name_norm=?',
      group.school_id, group.enroll_year, group.class_name_norm
    ).c;
    if (registered < minReg) throw E.privacy(`本班点亮人数达到 ${minReg} 人后开放群红包`);
  }

  function packetOut(db, viewer, p, { withClaims = false } = {}) {
    const sender = getUser(db, p.sender_id);
    const out = {
      packet_id: p.packet_id,
      conv_id: p.conv_id,
      msg_id: p.msg_id,
      sender: sender ? toUserBrief(db, viewer, sender, { scene: 'red_packet' }) : null,
      type: p.type,
      total_amount: p.total_amount,
      count: p.count,
      claimed_amount: p.claimed_amount,
      claimed_count: p.claimed_count,
      greeting: p.greeting,
      status: p.status,
      expire_at: p.expire_at,
      created_at: p.created_at,
    };
    if (withClaims) {
      const claims = q(db, 'SELECT * FROM red_packet_claims WHERE packet_id=? ORDER BY id', p.packet_id);
      out.claims = claims.map((c) => {
        const u = getUser(db, c.user_id);
        return {
          user: u ? toUserBrief(db, viewer, u, { scene: 'red_packet' }) : null,
          amount: c.amount, is_best: !!c.is_best, created_at: c.created_at,
        };
      });
      const mine = claims.find((c) => c.user_id === viewer.id);
      out.my_claim = mine ? { amount: mine.amount, is_best: !!mine.is_best } : null;
    }
    return out;
  }

  router.post('/v1/red-packets', { auth: true }, (ctx) => {
    const { conv_id, type, total_amount, count, greeting = null } = ctx.body || {};
    if (!isInt(conv_id)) throw E.param('conv_id 必填');
    if (!isInt(total_amount) || !isInt(count)) throw E.param('total_amount / count 必填（整数，单位：觅豆）');
    const total = Number(total_amount);
    const cnt = Number(count);
    const cfg = rules.red_packet;
    const conv = q1(db, 'SELECT * FROM conversations WHERE conv_id=?', Number(conv_id));
    if (!conv) throw E.notFound('会话不存在');
    if (!im().isMember(conv.conv_id, ctx.user.id)) throw E.privacy('不在该会话中');
    if (greeting !== null && [...String(greeting)].length > 20) throw E.param('祝福语不超过 20 字');

    if (conv.conv_type === 'group') {
      if (!['luck', 'normal'].includes(type)) throw E.param('群红包 type 仅支持 luck（拼手气）/ normal（普通）');
      const memberCount = im().convMemberCount(conv.conv_id);
      const maxCount = Math.min(cfg.max_count, memberCount);
      if (type === 'luck') {
        if (cnt < 2 || cnt > maxCount) throw E.param(`拼手气红包个数 2–${maxCount}`);
        if (total < cnt * cfg.min_per_share || total > cfg.max_total) {
          throw E.param(`拼手气红包总额 ${cnt * cfg.min_per_share}–${cfg.max_total} 觅豆`);
        }
      } else {
        if (cnt < 1 || cnt > maxCount) throw E.param(`普通红包个数 1–${maxCount}`);
        if (total % cnt !== 0) throw E.param('普通红包总额须能被个数整除（均分）');
        const per = total / cnt;
        if (per < cfg.min_per_share || per > cfg.max_per_share) {
          throw E.param(`普通红包单份 ${cfg.min_per_share}–${cfg.max_per_share} 觅豆`);
        }
      }
      assertUnitGate(db, conv.conv_id);
    } else {
      // 私聊红包：固定普通红包 1 份（§6.1），仅好友可发
      if (type !== 'normal' || cnt !== 1) throw E.param('私聊红包为普通红包、固定 1 份');
      if (total < cfg.min_per_share || total > cfg.max_per_share) {
        throw E.param(`私聊红包单份 ${cfg.min_per_share}–${cfg.max_per_share} 觅豆`);
      }
      const otherId = im().otherMember(conv, ctx.user.id);
      if (otherId && !isFriend(db, otherId, ctx.user.id)) throw E.privacy('对方开启了朋友验证，你还不是TA的好友');
      if (otherId && isBlockedBetween(db, ctx.user.id, otherId)) throw E.privacy('红包无法送达');
    }
    if (!hitRate(db, `rp_send:${ctx.user.id}:day`, cfg.daily_send_limit, 86400).allowed) {
      throw E.rate('今日发红包次数已达上限');
    }

    const packetId = `RP${uuid().replace(/-/g, '').slice(0, 24)}`;
    const expireAt = new Date(Date.now() + cfg.expire_hours * 3600 * 1000).toISOString();
    const result = withTx(db, () => {
      const { balance } = debitCoins(db, {
        userId: ctx.user.id, bizType: 'red_packet_send', bizId: packetId, amount: total, remark: '发红包',
      });
      run(
        db,
        `INSERT INTO red_packets(packet_id,conv_id,sender_id,type,total_amount,count,greeting,status,expire_at,created_at)
         VALUES(?,?,?,?,?,?,?,'active',?,?)`,
        packetId, conv.conv_id, ctx.user.id, type, total, cnt,
        greeting === null ? null : String(greeting), expireAt, now()
      );
      const { message } = im().sendMessage({
        convId: conv.conv_id, senderId: ctx.user.id, msgType: 'red_packet',
        content: JSON.stringify({ packet_id: packetId, type, total_amount: total, count: cnt, greeting }),
        clientMsgId: `rp:${packetId}`,
      });
      run(db, 'UPDATE red_packets SET msg_id=? WHERE packet_id=?', message.msg_id, packetId);
      return { balance, msgId: message.msg_id };
    });
    audit(db, { userId: ctx.user.id, event: 'red_packet_send', input: { packet_id: packetId, conv_id: conv.conv_id, type, total, count: cnt } });
    const p = q1(db, 'SELECT * FROM red_packets WHERE packet_id=?', packetId);
    return ok(ctx, { ...packetOut(db, ctx.user, p), balance: result.balance, msg_id: result.msgId });
  });

  router.post('/v1/red-packets/:packet_id/claim', { auth: true }, (ctx) => {
    const p = q1(db, 'SELECT * FROM red_packets WHERE packet_id=?', ctx.params.packet_id);
    if (!p) throw E.notFound('红包不存在');
    if (!im().isMember(p.conv_id, ctx.user.id)) throw E.privacy('不在该会话中');
    if (p.status === 'finished') throw E.param('红包已领完');
    if (p.status === 'expired') throw E.param('红包已过期');
    if (p.expire_at <= now()) {
      // 惰性过期：领取路径上即时结算，不等 janitor 扫描
      expirePacket(db, p);
      throw E.param('红包已过期');
    }
    const conv = q1(db, 'SELECT * FROM conversations WHERE conv_id=?', p.conv_id);
    if (conv.conv_type === 'single' && p.sender_id === ctx.user.id) throw E.param('自己发的私聊红包不能自己领');
    if (q1(db, 'SELECT 1 x FROM red_packet_claims WHERE packet_id=? AND user_id=?', p.packet_id, ctx.user.id)) {
      throw E.param('你已领取过这个红包');
    }

    const cfg = rules.red_packet;
    const amount = withTx(db, () => {
      const rest = p.total_amount - p.claimed_amount;
      const restCount = p.count - p.claimed_count;
      let got;
      if (p.type === 'luck') {
        if (restCount === 1) {
          got = rest;
        } else {
          // 二倍均值法：随机 [min_per_share, floor(rest/restCount*2)]，保底剩余每份 ≥min_per_share
          const cap = Math.max(cfg.min_per_share, Math.min(Math.floor((rest / restCount) * 2), rest - (restCount - 1) * cfg.min_per_share));
          got = crypto.randomInt(cfg.min_per_share, cap + 1);
        }
      } else {
        got = Math.floor(p.total_amount / p.count);
      }
      const info = run(
        db,
        "UPDATE red_packets SET claimed_count=claimed_count+1, claimed_amount=claimed_amount+? WHERE packet_id=? AND status='active' AND claimed_count<count",
        got, p.packet_id
      );
      if (!Number(info.changes)) throw E.param('红包已领完');
      // INSERT OR IGNORE + changes 判定：撞 UNIQUE(packet_id,user_id)（并发重复领取）时
      // 返回 40001「已领取过」而非 500；外层事务回滚刚加的 claimed_count，状态自洽
      const claimInfo = run(
        db,
        'INSERT OR IGNORE INTO red_packet_claims(packet_id,user_id,amount,created_at) VALUES(?,?,?,?)',
        p.packet_id, ctx.user.id, got, now()
      );
      if (!Number(claimInfo.changes)) throw E.param('你已领取过这个红包');
      creditCoins(db, { userId: ctx.user.id, bizType: 'red_packet_claim', bizId: p.packet_id, amount: got, remark: '领红包' });
      if (p.claimed_count + 1 === p.count) {
        run(db, "UPDATE red_packets SET status='finished' WHERE packet_id=?", p.packet_id);
        run(
          db,
          // Equal amounts use claim order as a stable tie breaker.
          'UPDATE red_packet_claims SET is_best=(id=(SELECT id FROM red_packet_claims WHERE packet_id=? ORDER BY amount DESC,id ASC LIMIT 1)) WHERE packet_id=?',
          p.packet_id, p.packet_id
        );
      }
      return got;
    });
    audit(db, { userId: ctx.user.id, event: 'red_packet_claim', input: { packet_id: p.packet_id, amount } });
    const fresh = q1(db, 'SELECT * FROM red_packets WHERE packet_id=?', p.packet_id);
    return ok(ctx, { amount, balance: coinBalance(db, ctx.user.id), packet: packetOut(db, ctx.user, fresh, { withClaims: true }) });
  });

  router.get('/v1/red-packets/:packet_id', { auth: true }, (ctx) => {
    const p = q1(db, 'SELECT * FROM red_packets WHERE packet_id=?', ctx.params.packet_id);
    if (!p) throw E.notFound('红包不存在');
    if (!im().isMember(p.conv_id, ctx.user.id)) throw E.privacy('不在该会话中');
    return ok(ctx, packetOut(db, ctx.user, p, { withClaims: true }));
  });

  // ---------- 动态打赏（P0：纯心意，不产生现金收益） ----------
  router.post('/v1/moments/:moment_id/gifts', { auth: true }, (ctx) => {
    const m = q1(db, 'SELECT * FROM moments WHERE moment_id=? AND deleted=0', Number(ctx.params.moment_id));
    if (!m) throw E.notFound('动态不存在或已删除');
    const author = getUser(db, m.author_id);
    if (!author || author.status !== 1) throw E.notFound('作者不存在');
    if (m.author_id === ctx.user.id) throw E.param('不能给自己的动态打赏');
    if (!canSeeMoment(db, ctx.user, m, author, ctx)) throw E.privacy('无权操作该动态');
    const { coin_amount } = ctx.body || {};
    if (!isInt(coin_amount)) throw E.param('coin_amount 必填（整数，单位：觅豆）');
    const amount = Number(coin_amount);
    const cfg = rules.gift;
    if (!cfg.denominations.includes(amount)) {
      throw E.param(`打赏面额仅支持 ${cfg.denominations.join(' / ')} 觅豆`);
    }
    if (!hitRate(db, `gift_send:${ctx.user.id}:day`, cfg.daily_limit, 86400).allowed) {
      throw E.rate('今日打赏次数已达上限');
    }
    const orderId = `G${uuid().replace(/-/g, '').slice(0, 24)}`;
    const { balance } = withTx(db, () => {
      const r = debitCoins(db, {
        userId: ctx.user.id, bizType: 'gift_send', bizId: orderId, amount, remark: '打赏动态',
      });
      creditCoins(db, { userId: author.id, bizType: 'gift_recv', bizId: orderId, amount, remark: '收到打赏' });
      run(
        db,
        "INSERT INTO gift_orders(order_id,from_user,to_user,moment_id,coin_amount,status,created_at) VALUES(?,?,?,?,?,'confirmed',?)",
        orderId, ctx.user.id, author.id, m.moment_id, amount, now()
      );
      return r;
    });
    audit(db, { userId: ctx.user.id, event: 'gift_send', targetId: m.moment_id, input: { order_id: orderId, to_user: author.id, amount } });
    return ok(ctx, { order_id: orderId, coin_amount: amount, to_user_id: author.id, balance });
  });

  router.get('/v1/moments/:moment_id/gifts', { auth: true }, (ctx) => {
    const m = q1(db, 'SELECT * FROM moments WHERE moment_id=? AND deleted=0', Number(ctx.params.moment_id));
    if (!m) throw E.notFound('动态不存在或已删除');
    const author = getUser(db, m.author_id);
    if (!canSeeMoment(db, ctx.user, m, author, ctx)) throw E.privacy('无权查看该动态');
    const rows = q(
      db,
      'SELECT * FROM gift_orders WHERE moment_id=? ORDER BY created_at DESC LIMIT 50',
      m.moment_id
    );
    const total = q1(db, 'SELECT COUNT(*) c, COALESCE(SUM(coin_amount),0) s FROM gift_orders WHERE moment_id=?', m.moment_id);
    return ok(ctx, {
      total_count: total.c,
      total_coins: total.s,
      items: rows.map((g) => {
        const u = getUser(db, g.from_user);
        return {
          from_user: u ? toUserBrief(db, ctx.user, u, { scene: 'gift' }) : null,
          coin_amount: g.coin_amount, created_at: g.created_at,
        };
      }),
    });
  });
}

// 过期退回（§6.2）：24h 未领完，剩余觅豆原路退回发出者币账户（退的是币不是钱）。
// 供 janitor 定时扫描与领取路径惰性结算共用；状态流转 active→expired 保证只退一次。
export function expirePacket(db, p) {
  withTx(db, () => {
    const info = run(db, "UPDATE red_packets SET status='expired' WHERE packet_id=? AND status='active'", p.packet_id);
    if (!Number(info.changes)) return;
    const remain = p.total_amount - p.claimed_amount;
    if (remain > 0) {
      creditCoins(db, {
        userId: p.sender_id, bizType: 'red_packet_refund', bizId: p.packet_id, amount: remain, remark: '红包24小时未领完退回',
      });
    }
  });
}
