import { q1, run, audit, getUser, isFriend, isBlockedBetween } from '../repo.js';
import { ok, E } from '../http/respond.js';
import { isInt } from '../util.js';
import { hitRate } from '../rate.js';
import { resolveUserView, containsContactInfo } from '../engine/index.js';
import { getIMProvider } from '../im/provider.js';
import { toUserBrief } from './users.js';

// 客户端可发消息类型白名单；system / red_packet / contact_card 等仅服务端可发
// （红包走 wallet.js、破冰/系统消息走 friends.js，均经 IM Provider 直发，不经本路由）
const CLIENT_MSG_TYPES = ['text', 'image', 'voice', 'video'];

// 单聊消息：全部经 IM Provider 接口层（SDK 可替换，计划书 §5.3）
export function registerMessageRoutes(router, { db, config, storage }) {
  const im = () => getIMProvider(db, config);

  router.post('/v1/conversations', { auth: true }, (ctx) => {
    const { to_user_id } = ctx.body || {};
    if (!isInt(to_user_id)) throw E.param('to_user_id 必填');
    const target = getUser(db, Number(to_user_id));
    if (!target || target.status !== 1) throw E.notFound('用户不存在');
    // 陌生人消息（§9.3.2）：V0.9 仅好友可发起单聊
    if (!isFriend(db, ctx.user.id, target.id)) throw E.privacy('先加为好友才能发起聊天');
    const conv = im().getOrCreateSingleConversation(ctx.user.id, target.id);
    im().showConversation(conv.conv_id, ctx.user.id);
    return ok(ctx, conversationOut(db, ctx.user, conv));
  });

  router.get('/v1/conversations', { auth: true }, (ctx) => {
    const provider = im();
    const convs = provider.listConversations(ctx.user.id);
    const items = convs.map((c) => {
      const conv = q1(db, 'SELECT * FROM conversations WHERE conv_id=?', c.conv_id);
      const out = conversationOut(db, ctx.user, conv);
      out.unread_count = provider.unreadCount(c.conv_id, ctx.user.id);
      out.is_pinned = !!c.is_pinned;
      out.is_muted = !!c.is_muted;
      return out;
    });
    return ok(ctx, { items, next_cursor: null });
  });

  router.post('/v1/conversations/:conv_id/messages', { auth: true }, (ctx) => {
    const convId = Number(ctx.params.conv_id);
    const conv = q1(db, 'SELECT * FROM conversations WHERE conv_id=?', convId);
    if (!conv) throw E.notFound('会话不存在');
    if (!im().isMember(convId, ctx.user.id)) throw E.privacy('不在该会话中');
    const { client_msg_id, msg_type = 'text', content } = ctx.body || {};
    if (!client_msg_id) throw E.param('client_msg_id 必填（客户端幂等键）');
    if (!CLIENT_MSG_TYPES.includes(msg_type)) throw E.param('msg_type 不合法（仅支持 text/image/voice/video）');
    if (msg_type === 'text' && !content) throw E.param('content 必填');
    if (content && [...String(content)].length > 4000) throw E.param('消息内容不超过 4000 字');
    // 媒体消息：content 须为 /misc/upload 返回的媒体 url，扩展名按类型分档
    // （image=图片默认；voice=m4a/aac；video=mp4/mov，与 upload scene 白名单一致，见 storage.js）
    if (msg_type !== 'text') {
      if (!content) throw E.param('content 必填（媒体消息为 /misc/upload 返回的 url）');
      const okMedia =
        msg_type === 'image' ? storage.isValidMediaUrl(content)
        : msg_type === 'voice' ? storage.isValidMediaUrl(content, ['m4a', 'aac'])
        : storage.isValidMediaUrl(content, ['mp4', 'mov']);
      if (!okMedia) throw E.param(`${msg_type} 消息 content 须为 /misc/upload 返回的媒体 url`);
    }
    if (conv.conv_type === 'group') {
      // 班级群：成员关系已在上方校验；群成员不要求互为好友，跳过好友/拉黑校验（§群聊语义）
      // 群发言频控：群维度 key 与单聊区分，30 条/60s
      if (!hitRate(db, `grp_msg:${convId}:${ctx.user.id}`, 30, 60).allowed) throw E.rate('发言过于频繁，请稍后再试');
      // 内容安全：群消息过联系方式/引流拦截（45001，与动态/验证语同一套规则）
      if (content && containsContactInfo(String(content))) {
        audit(db, { userId: ctx.user.id, event: 'content_block', scene: 'group_message' });
        throw E.content('消息包含联系方式或导流信息，已被拦截');
      }
    } else {
      // 单向删除场景：被删方发消息时提示（§8.4）
      const otherId = im().otherMember(conv, ctx.user.id);
      if (otherId && !isFriend(db, otherId, ctx.user.id)) throw E.privacy('对方开启了朋友验证，你还不是TA的好友');
      // 拉黑双向断联（§8.1）：任一方向拉黑即不可发消息
      if (otherId && isBlockedBetween(db, ctx.user.id, otherId)) throw E.privacy('消息无法送达');
      // 单聊发言频控：与群聊同档，30 条/60s（置于隐私校验后，被拒消息不占配额）
      if (!hitRate(db, `single_msg:${convId}:${ctx.user.id}`, 30, 60).allowed) throw E.rate('发言过于频繁，请稍后再试');
    }
    const { message, duplicated } = im().sendMessage({
      convId, senderId: ctx.user.id, msgType: msg_type, content: content ?? null, clientMsgId: String(client_msg_id),
    });
    return ok(ctx, { msg_id: message.msg_id, server_time: message.created_at, duplicated });
  });

  router.get('/v1/conversations/:conv_id/messages', { auth: true }, (ctx) => {
    const convId = Number(ctx.params.conv_id);
    if (!q1(db, 'SELECT 1 x FROM conversations WHERE conv_id=?', convId)) throw E.notFound('会话不存在');
    if (!im().isMember(convId, ctx.user.id)) throw E.privacy('不在该会话中');
    const msgOut = (m) => ({
      msg_id: m.msg_id,
      conv_id: m.conv_id,
      sender: (() => {
        const s = getUser(db, m.sender_id);
        return s ? toUserBrief(db, ctx.user, s, { scene: 'message' }) : null;
      })(),
      msg_type: m.msg_type,
      content: m.content,
      status: m.status,
      client_msg_id: m.client_msg_id,
      created_at: m.created_at,
    });
    const limit = Math.min(Number(ctx.query.limit) || 20, 50);
    // 增量模式：since_msg_id 之后的消息（正序，封顶 50），与 cursor 倒序分页共存
    if (isInt(ctx.query.since_msg_id)) {
      const items = im().listMessagesSince({ convId, sinceMsgId: Number(ctx.query.since_msg_id), limit, userId: ctx.user.id });
      return ok(ctx, { items: items.map(msgOut), next_cursor: null });
    }
    const { items, nextCursor } = im().listMessages({
      convId, cursor: isInt(ctx.query.cursor) ? Number(ctx.query.cursor) : null, limit, userId: ctx.user.id,
    });
    return ok(ctx, { items: items.map(msgOut), next_cursor: nextCursor });
  });

  // 仅清除本人的历史视图；保留对方消息与群成员关系，新消息自动恢复列表。
  router.delete('/v1/conversations/:conv_id', { auth: true }, (ctx) => {
    const convId = Number(ctx.params.conv_id);
    if (!im().isMember(convId, ctx.user.id)) throw E.notFound('会话不存在或不在会话中');
    im().clearConversation(convId, ctx.user.id);
    return ok(ctx);
  });

  router.post('/v1/conversations/:conv_id/read', { auth: true }, (ctx) => {
    const convId = Number(ctx.params.conv_id);
    if (!im().isMember(convId, ctx.user.id)) throw E.notFound('会话不存在或不在会话中');
    const requested = ctx.body?.last_read_msg_id;
    if (requested !== undefined && (!isInt(requested) || Number(requested) < 0)) {
      throw E.param('last_read_msg_id 须为非负整数');
    }
    const lastRead = requested === undefined ? undefined : Number(requested);
    im().markRead({ convId, userId: ctx.user.id, lastReadMsgId: lastRead });
    return ok(ctx);
  });

  // 撤回消息：仅发送者、2 分钟内（契约 /messages/{msg_id}/recall）
  router.post('/v1/messages/:msg_id/recall', { auth: true }, (ctx) => {
    const msgId = Number(ctx.params.msg_id);
    const msg = q1(db, 'SELECT * FROM messages WHERE msg_id=?', msgId);
    if (!msg || msg.sender_id !== ctx.user.id || !im().isMember(msg.conv_id, ctx.user.id)) {
      throw E.notFound('消息不存在或非本人发送');
    }
    if (!CLIENT_MSG_TYPES.includes(msg.msg_type)) throw E.param('红包和系统消息不支持撤回');
    const result = im().recallMessage({ msgId, senderId: ctx.user.id });
    if (result === null) throw E.notFound('消息不存在或非本人发送');
    if (result === false) throw E.param('已超过 2 分钟，无法撤回');
    return ok(ctx, { msg_id: msgId, status: 'recalled' });
  });

  // 会话设置：置顶/免打扰（契约 PUT /conversations/{conv_id}/settings）
  router.put('/v1/conversations/:conv_id/settings', { auth: true }, (ctx) => {
    const convId = Number(ctx.params.conv_id);
    if (!im().isMember(convId, ctx.user.id)) throw E.notFound('会话不存在或不在会话中');
    const { is_pinned, is_muted } = ctx.body || {};
    const done = im().setConvSettings({
      convId, userId: ctx.user.id,
      pinned: is_pinned === undefined ? null : (is_pinned ? 1 : 0),
      muted: is_muted === undefined ? null : (is_muted ? 1 : 0),
    });
    if (!done) throw E.notFound('会话不存在或不在会话中');
    return ok(ctx);
  });

  function conversationOut(db, viewer, conv) {
    const provider = im();
    const last = provider.lastMessage(conv.conv_id, viewer.id);
    const out = {
      conv_id: conv.conv_id,
      conv_type: conv.conv_type,
      title: conv.title ?? null,
      avatar_url: null,
      last_msg_summary: last ? (last.status === 'recalled' ? '消息已撤回' : last.msg_type === 'text' ? last.content : `[${last.msg_type}]`) : null,
      last_msg_time: last?.created_at ?? null,
      unread_count: provider.unreadCount(conv.conv_id, viewer.id),
      is_pinned: !!conv.is_pinned,
      is_muted: !!conv.is_muted,
      intersection_banner: null,
    };
    if (conv.conv_type === 'group') {
      // 班级群：标题用 conversations.title，无 other/头像逻辑，附成员数
      out.member_count = provider.convMemberCount(conv.conv_id);
      // 群种类：班级群 / 老乡群（客户端群资料页据此区分 API 与文案）
      if (q1(db, 'SELECT group_id FROM class_groups WHERE conv_id=?', conv.conv_id)) {
        out.group_kind = 'class';
      } else if (q1(db, 'SELECT group_id FROM hometown_groups WHERE conv_id=?', conv.conv_id)) {
        out.group_kind = 'hometown';
      } else {
        out.group_kind = null;
      }
    } else if (conv.conv_type === 'single') {
      const otherId = conv.user_a === viewer.id ? conv.user_b : conv.user_a;
      const other = getUser(db, otherId);
      if (other) {
        // 会话标题：备注 > 真名 > 昵称（§20.6 好友署名优先级）
        const remark = q1(db, 'SELECT remark_name FROM friendships WHERE user_id=? AND friend_id=?', viewer.id, other.id)?.remark_name;
        const view = resolveUserView(db, viewer, other, { scene: 'conversation' });
        out.title = remark || view.realName || other.nickname;
        out.avatar_url = other.avatar_url ?? null;
        out.intersection_banner = view.banner;
        out.peer_user_id = other.id;
      }
    }
    return out;
  }
}
