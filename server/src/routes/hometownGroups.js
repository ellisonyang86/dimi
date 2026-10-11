import { q1, run, audit, getUser } from '../repo.js';
import { ok, E } from '../http/respond.js';
import { containsContactInfo } from '../engine/index.js';
import { getIMProvider } from '../im/provider.js';
import { toUserBrief } from './users.js';

// 老乡群聊：家乡同市单元（user_hometowns type=1 的 region_code 前 4 位，与老乡圈同边界）一一对应一个群会话。
// 入群依据=本人已设置家乡（type=1），群成员不要求互为好友；
// 群成员复用 conversation_members（已读位点/置顶/免打扰），消息收发走 IM Provider。
export function registerHometownGroupRoutes(router, { db, config }) {
  const im = () => getIMProvider(db, config);

  const findGroup = (convId) => q1(db, 'SELECT * FROM hometown_groups WHERE conv_id=?', convId);
  // 市级行政区名：region_prefix（前 4 位）匹配 level=2 的 regions 记录
  const cityOf = (prefix) => q1(db, "SELECT * FROM regions WHERE level=2 AND substr(code,1,4)=? AND is_active=1", prefix);

  // 我的老乡群：以本人家乡（type=1）为准，未设家乡返回空列表
  router.get('/v1/hometown-groups/mine', { auth: true }, (ctx) => {
    const provider = im();
    const hometown = q1(db, 'SELECT * FROM user_hometowns WHERE user_id=? AND type=1', ctx.user.id);
    if (!hometown) return ok(ctx, { items: [] });
    const prefix = String(hometown.region_code).slice(0, 4);
    const city = cityOf(prefix);
    const group = q1(db, 'SELECT * FROM hometown_groups WHERE region_prefix=?', prefix);
    let groupOut = null;
    if (group) {
      const conv = q1(db, 'SELECT * FROM conversations WHERE conv_id=?', group.conv_id);
      const joined = provider.isConvMember(group.conv_id, ctx.user.id);
      groupOut = {
        conv_id: group.conv_id,
        title: conv?.title ?? null,
        member_count: provider.convMemberCount(group.conv_id),
        announcement: group.announcement ?? '',
        joined,
        unread_count: joined ? provider.unreadCount(group.conv_id, ctx.user.id) : 0,
      };
    }
    return ok(ctx, {
      items: [{ region_code: hometown.region_code, region_name: city?.name ?? null, group: groupOut }],
    });
  });

  // 加入（或创建）老乡群：以本人家乡（type=1）为准，未设置则拒绝
  router.post('/v1/hometown-groups/join', { auth: true }, (ctx) => {
    const hometown = q1(db, 'SELECT * FROM user_hometowns WHERE user_id=? AND type=1', ctx.user.id);
    if (!hometown) throw E.privacy('先设置家乡才能加入老乡群');
    const prefix = String(hometown.region_code).slice(0, 4);
    const city = cityOf(prefix);
    const title = `${city?.name ?? prefix}老乡群`;
    const targetCode = ctx.body?.region_code;
    if (targetCode != null && String(targetCode).slice(0, 4) !== prefix) {
      throw E.privacy('只有当地老乡才能加入该老乡群');
    }
    const provider = im();
    const { group, conv, created } = provider.getOrCreateHometownGroup({
      regionPrefix: prefix, title, creatorId: ctx.user.id,
    });
    provider.joinConversation(group.conv_id, ctx.user.id);
    // 群主补位：群无主（created_by NULL，正常路径=空群待任；非空群 NULL 为异常防御）时由本次 join 者继任
    if (group.created_by == null) {
      run(db, 'UPDATE hometown_groups SET created_by=? WHERE group_id=?', ctx.user.id, group.group_id);
    }
    audit(db, {
      userId: ctx.user.id, event: 'hometown_group_join', targetId: group.group_id,
      input: { conv_id: group.conv_id, region_prefix: prefix, created },
    });
    return ok(ctx, {
      conv_id: group.conv_id,
      title: conv?.title ?? null,
      member_count: provider.convMemberCount(group.conv_id),
      announcement: group.announcement ?? '',
      joined: true,
      unread_count: provider.unreadCount(group.conv_id, ctx.user.id),
      created,
    });
  });

  // 群成员列表：须为群成员；姓名展示走可见性引擎（与资料卡同一渐显规则）
  router.get('/v1/hometown-groups/:conv_id/members', { auth: true }, (ctx) => {
    const convId = Number(ctx.params.conv_id);
    const group = findGroup(convId);
    if (!group) throw E.notFound('老乡群不存在');
    if (!im().isConvMember(convId, ctx.user.id)) throw E.privacy('不在该老乡群中');
    const items = im().listConvMembers(convId)
      .map((m) => {
        const u = getUser(db, m.user_id);
        if (!u) return null;
        return { ...toUserBrief(db, ctx.user, u, { scene: 'class_group' }), is_owner: group.created_by === u.id };
      })
      .filter(Boolean);
    return ok(ctx, { items, owner_id: group.created_by ?? null });
  });

  // 群公告：仅群主可改，≤200 字
  router.put('/v1/hometown-groups/:conv_id/announcement', { auth: true }, (ctx) => {
    const convId = Number(ctx.params.conv_id);
    const group = findGroup(convId);
    if (!group) throw E.notFound('老乡群不存在');
    if (!im().isConvMember(convId, ctx.user.id)) throw E.privacy('不在该老乡群中');
    if (group.created_by !== ctx.user.id) throw E.privacy('仅群主可修改群公告');
    const announcement = String(ctx.body?.announcement ?? '');
    if ([...announcement].length > 200) throw E.param('群公告不超过 200 字');
    // 内容安全：联系方式/引流拦截（45001，与动态/验证语同一套规则）
    if (announcement && containsContactInfo(announcement)) {
      audit(db, { userId: ctx.user.id, event: 'content_block', scene: 'hometown_group_announcement' });
      throw E.content('群公告包含联系方式或导流信息，已被拦截');
    }
    run(db, 'UPDATE hometown_groups SET announcement=? WHERE group_id=?', announcement, group.group_id);
    audit(db, { userId: ctx.user.id, event: 'hometown_group_announcement', targetId: group.group_id, input: { conv_id: convId } });
    return ok(ctx, { announcement });
  });

  // 退群：移出成员；群主退群且群内还有人 → 群主顺延给最早加入者；无人则 created_by 置 NULL，
  // 群与消息历史保留，由下一位 join 者补位群主（见 join 路由）
  router.post('/v1/hometown-groups/:conv_id/leave', { auth: true }, (ctx) => {
    const convId = Number(ctx.params.conv_id);
    const group = findGroup(convId);
    if (!group) throw E.notFound('老乡群不存在');
    if (!im().isConvMember(convId, ctx.user.id)) throw E.privacy('不在该老乡群中');
    im().leaveConversation(convId, ctx.user.id);
    if (group.created_by === ctx.user.id) {
      // 顺延给最早加入的在册成员（JOIN users 过滤 status=1，不顺延给已注销账号）
      const next = q1(
        db,
        `SELECT m.user_id FROM conversation_members m JOIN users u ON u.id=m.user_id
         WHERE m.conv_id=? AND u.status=1 ORDER BY m.rowid LIMIT 1`,
        convId
      );
      run(db, 'UPDATE hometown_groups SET created_by=? WHERE group_id=?', next?.user_id ?? null, group.group_id);
    }
    audit(db, { userId: ctx.user.id, event: 'hometown_group_leave', targetId: group.group_id, input: { conv_id: convId } });
    return ok(ctx);
  });
}
