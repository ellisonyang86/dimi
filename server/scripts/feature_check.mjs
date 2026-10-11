// 新功能验证：精确找人 / 好友备注 / 拉黑断联 / 撤回 / 会话设置 / 数据导出 / 注销冷静期
const base = process.env.SMOKE_BASE || 'http://127.0.0.1:8080';

async function api(method, p, { token, body } = {}) {
  const res = await fetch(base + p, {
    method,
    headers: {
      ...(body ? { 'Content-Type': 'application/json' } : {}),
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  return { status: res.status, json: await res.json() };
}
const step = (name, ok, extra = '') => console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${extra ? '  → ' + extra : ''}`);

async function register(phone, nickname) {
  const sms = await api('POST', '/v1/auth/sms/send', { body: { phone } });
  const reg = await api('POST', '/v1/auth/register', {
    body: { phone, sms_code: sms.json.data.sms_code, nickname, gender: 1, birth_year: 1988 },
  });
  return { token: reg.json.data.access_token, userId: reg.json.data.user.user_id };
}

const suffix = String(Math.floor(Math.random() * 1e6)).padStart(6, '0');
const A = await register('139' + suffix + '01', '验证用户A');
const B = await register('139' + suffix + '02', '验证用户B');

// 1. 精确找人（dimi_no / phone）
const dimiNoB = 'DM' + (10000000 + B.userId);
const byDimi = await api('GET', `/v1/discover/search-user?dimi_no=${dimiNoB}`, { token: A.token });
step('dimi_no 精确找人', byDimi.json.code === 0 && byDimi.json.data.items[0]?.user_id === B.userId);
const byPhone = await api('GET', `/v1/discover/search-user?phone=139${suffix}02`, { token: A.token });
step('phone 精确找人', byPhone.json.code === 0 && byPhone.json.data.items.length === 1);
const byBad = await api('GET', '/v1/discover/search-user?dimi_no=DM99999999', { token: A.token });
step('未命中返回 0 条', byBad.json.code === 0 && byBad.json.data.items.length === 0);

// 2. 好友链路：申请 → 通过 → 备注 → 撤回消息 → 会话设置
const fr = await api('POST', '/v1/friends/requests', {
  token: A.token, body: { to_user_id: B.userId, verify_msg: '我是老同学' },
});
const inbox = await api('GET', '/v1/friends/requests?box=inbox', { token: B.token });
const reqItem = inbox.json.data.items.find((i) => i.from_user_id === A.userId && i.status === 'pending');
const acc = await api('POST', `/v1/friends/requests/${reqItem.id}/accept`, { token: B.token });
const convId = acc.json.data.conversation_id;
step('申请并通过', !!convId);

const remark = await api('PUT', `/v1/friends/${A.userId}`, { token: B.token, body: { remark_name: '老张', is_starred: true } });
const listB = await api('GET', '/v1/friends', { token: B.token });
const fItem = listB.json.data.items.find((i) => i.user_id === A.userId);
step('好友备注写入', remark.json.code === 0 && fItem?.remark_name === '老张' && fItem?.is_starred === true);

const msg = await api('POST', `/v1/conversations/${convId}/messages`, {
  token: A.token, body: { client_msg_id: 't1', content: '这条将被撤回' },
});
const recall = await api('POST', `/v1/messages/${msg.json.data.msg_id}/recall`, { token: A.token });
const history = await api('GET', `/v1/conversations/${convId}/messages`, { token: B.token });
const recalledMsg = history.json.data.items.find((m) => m.msg_id === msg.json.data.msg_id);
step('消息撤回', recall.json.code === 0 && recalledMsg?.status === 'recalled' && recalledMsg?.content === null);

const settings = await api('PUT', `/v1/conversations/${convId}/settings`, { token: A.token, body: { is_pinned: true } });
const convs = await api('GET', '/v1/conversations', { token: A.token });
const convItem = convs.json.data.items.find((c) => c.conv_id === convId);
step('会话置顶设置', settings.json.code === 0 && convItem?.is_pinned === true);

// 3. 拉黑双向断联
const block = await api('POST', `/v1/friends/${B.userId}/block`, { token: A.token });
const msgAfterBlock = await api('POST', `/v1/conversations/${convId}/messages`, {
  token: A.token, body: { client_msg_id: 't2', content: '拉黑后消息' },
});
const searchBlocked = await api('GET', `/v1/discover/search-user?dimi_no=${dimiNoB}`, { token: A.token });
step('拉黑后消息被拒', block.json.code === 0 && msgAfterBlock.json.code === 40301);
step('拉黑后检索不可见', searchBlocked.json.data.items.length === 0);
const unblock = await api('DELETE', `/v1/friends/${B.userId}/block`, { token: A.token });
const msgAfterUnblock = await api('POST', `/v1/conversations/${convId}/messages`, {
  token: A.token, body: { client_msg_id: 't3', content: '解除后消息' },
});
step('移出黑名单恢复', unblock.json.code === 0 && msgAfterUnblock.json.code === 0);

// 4. 数据导出（PIPL 可携带权）
const exp = await api('POST', '/v1/privacy/data-export', { token: A.token });
step('数据导出', exp.json.code === 0 && exp.json.data.profile?.phone === `139${suffix}01`, exp.json.data?.profile?.dimi_no);
const exp2 = await api('POST', '/v1/privacy/data-export', { token: A.token });
step('导出频控 1 次/时', exp2.json.code === 42901);

// 5. 注销冷静期（短信 60s 频控：等一个间隔再发码）
await new Promise((r) => setTimeout(r, 61000));
const smsC = await api('POST', '/v1/auth/sms/send', { body: { phone: `139${suffix}02`, scene: 'deactivate' } });
const deact = await api('POST', '/v1/auth/deactivate', { token: B.token, body: { sms_code: smsC.json.data.sms_code } });
step('注销进入冷静期', deact.json.code === 0 && !!deact.json.data.cooling_until);
const tokenDead = await api('GET', '/v1/users/me', { token: B.token });
step('注销后 token 失效', tokenDead.json.code === 40101);
await new Promise((r) => setTimeout(r, 61000)); // 再避一次短信 60s 频控
const smsRelogin = await api('POST', '/v1/auth/sms/send', { body: { phone: `139${suffix}02`, scene: 'login' } });
const relogin = await api('POST', '/v1/auth/login', {
  body: { grant_type: 'sms', phone: `139${suffix}02`, sms_code: smsRelogin.json.data.sms_code },
});
step('冷静期内登录撤销注销', relogin.json.code === 0);
const meAfter = await api('GET', '/v1/users/me', { token: relogin.json.data?.access_token });
step('撤销注销后账号恢复', meAfter.json.code === 0);

// 6. 验证码防爆：同一码错 5 次后正确码也失效
const phoneC = '139' + suffix + '03';
const smsE = await api('POST', '/v1/auth/sms/send', { body: { phone: phoneC } });
const realCode = smsE.json.data.sms_code;
for (let i = 0; i < 5; i++) {
  await api('POST', '/v1/auth/register', { body: { phone: phoneC, sms_code: '000000', nickname: '爆破测试', birth_year: 1990 } });
}
const brute = await api('POST', '/v1/auth/register', { body: { phone: phoneC, sms_code: realCode, nickname: '爆破测试', birth_year: 1990 } });
step('验证码 5 次错误后作废', brute.json.code === 40001);

console.log('feature-check done');

// 7. R1 新增端点
const devs = await api('GET', '/v1/auth/devices', { token: A.token });
step('设备列表', devs.json.code === 0 && devs.json.data.items.some((d) => d.current));
const cv = await api('PUT', '/v1/users/me/contacts-visibility', { token: A.token, body: { phone: 'friends' } });
step('联系方式可见性设置', cv.json.code === 0 && cv.json.data.contacts_visibility.phone === 'friends');
const cvBad = await api('PUT', '/v1/users/me/contacts-visibility', { token: A.token, body: { phone: 'everyone' } });
step('可见性非法值拒绝', cvBad.json.code === 40001);
const viewers = await api('GET', '/v1/users/me/contact-viewers', { token: A.token });
step('谁看过我接口', viewers.json.code === 0 && Array.isArray(viewers.json.data.items));
const fb = await api('POST', '/v1/discover/feedback', { token: A.token, body: { target_user_id: B.userId, action: 'not_interested' } });
step('推荐负反馈', fb.json.code === 0);
const appeal = await api('POST', '/v1/misc/appeal', { token: A.token, body: { type: 'freeze', content: '账号被误冻结，申请复核' } });
step('申诉提交', appeal.json.code === 0 && appeal.json.data.sla === '24h');
const report = await api('POST', '/v1/misc/report', { token: A.token, body: { target_type: 'user', target_id: B.userId, reason: 'other' } });
step('举报契约路径', report.json.code === 0 && !!report.json.data.report_id);
const png1x1 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
const up = await api('POST', '/v1/misc/upload', { token: A.token, body: { scene: 'avatar', content_base64: png1x1, ext: 'png' } });
step('媒体上传', up.json.code === 0 && !!up.json.data.media_id);
const media = await fetch(base + up.json.data.url);
step('媒体可访问', media.status === 200);
const tagged = await api('GET', '/v1/friends?tag=' + encodeURIComponent('同学'), { token: A.token });
step('好友标签筛选', tagged.json.code === 0);
const recAfterFb = await api('GET', '/v1/discover/recommendations?scene=home', { token: A.token });
step('负反馈后推荐排除', recAfterFb.json.code === 0 && !recAfterFb.json.data.items.some((i) => i.user_id === B.userId));

console.log('R1 check done');

// 8. 高隐私分组门禁
const gApi = async (m, p, { token, body, unlock } = {}) => {
  const res = await fetch(base + p, {
    method: m,
    headers: {
      ...(body ? { 'Content-Type': 'application/json' } : {}),
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(unlock ? { 'X-Group-Unlock': unlock } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  return { status: res.status, json: await res.json() };
};

// C 与 D 成好友，C 把 D 移入高隐私分组
const suffix2 = String(Math.floor(Math.random() * 1e6)).padStart(6, '0');
const C = await register('137' + suffix2 + '01', '分组用户C');
const D = await register('137' + suffix2 + '02', '分组用户D');
const frCD = await api('POST', '/v1/friends/requests', { token: C.token, body: { to_user_id: D.userId, verify_msg: '老同学' } });
const inboxD = await api('GET', '/v1/friends/requests?box=inbox', { token: D.token });
const reqCD = inboxD.json.data.items.find((i) => i.from_user_id === C.userId && i.status === 'pending');
await api('POST', `/v1/friends/requests/${reqCD.id}/accept`, { token: D.token });

// 未设密码不能建高隐私组
const g0 = await api('POST', '/v1/contact-groups', { token: C.token, body: { name: '密友', privacy_level: 'high' } });
step('未设密码拒建高隐私组', g0.json.code === 40001);
await api('PUT', '/v1/privacy/password', { token: C.token, body: { password: 'secret123' } });
const g1 = await api('POST', '/v1/contact-groups', { token: C.token, body: { name: '密友', privacy_level: 'high' } });
step('创建高隐私分组', g1.json.code === 0 && !!g1.json.data.group_id);
const gid = g1.json.data.group_id;
await api('PUT', `/v1/friends/${D.userId}/group`, { token: C.token, body: { group_id: gid } });

// 未解锁：列表隐藏、资料卡门禁
const listLocked = await api('GET', '/v1/friends', { token: C.token });
step('未解锁列表隐藏高隐私好友', !listLocked.json.data.items.some((i) => i.user_id === D.userId) && listLocked.json.data.locked_count === 1);
const cardLocked = await api('GET', `/v1/users/${D.userId}`, { token: C.token });
step('未解锁资料卡门禁 40301', cardLocked.json.code === 40301 && cardLocked.json.data?.locked === true);

// 错误密码计数，正确密码解锁
const badUnlock = await api('POST', '/v1/privacy/groups/unlock', { token: C.token, body: { password: 'wrong' } });
step('错误密码拒绝', badUnlock.json.code === 40001);
const un = await api('POST', '/v1/privacy/groups/unlock', { token: C.token, body: { password: 'secret123' } });
step('解锁获得凭证', un.json.code === 0 && !!un.json.data.unlock_token);
const ut = un.json.data.unlock_token;
const listUn = await gApi('GET', '/v1/friends', { token: C.token, unlock: ut });
step('解锁后列表可见', listUn.json.data.items.some((i) => i.user_id === D.userId));
const cardUn = await gApi('GET', `/v1/users/${D.userId}`, { token: C.token, unlock: ut });
step('解锁后资料卡可见', cardUn.json.code === 0);
const lock = await api('POST', '/v1/privacy/groups/lock', { token: C.token });
const listRelock = await gApi('GET', '/v1/friends', { token: C.token, unlock: ut });
step('主动锁定后凭证失效', lock.json.code === 0 && !listRelock.json.data.items.some((i) => i.user_id === D.userId));

console.log('group-privacy check done');

// 9. 朋友圈/发现（Moments 域）
// C、D 已是好友（分组章节）；再注册 E（陌生人，与 C/D 无交集）
// C/D 设为同乡（城关乡），供 fellows 可见性用例
await api('PUT', '/v1/users/me/hometown', { token: C.token, body: { type: 1, region_code: '411623102' } });
await api('PUT', '/v1/users/me/hometown', { token: D.token, body: { type: 1, region_code: '411623102' } });
const suffix3 = String(Math.floor(Math.random() * 1e6)).padStart(6, '0');
const E2 = await register('135' + suffix3 + '01', '路人E');

// C 发三条：公开 / 私密 / 仅老乡圈
const mPub = await api('POST', '/v1/moments', { token: C.token, body: { content_type: 'text', content: '今天回了趟母校', visibility: 'public' } });
const mPri = await api('POST', '/v1/moments', { token: C.token, body: { content_type: 'text', content: '仅自己可见的心事', visibility: 'private' } });
const mFel = await api('POST', '/v1/moments', { token: C.token, body: { content_type: 'text', content: '老乡们聚一波', visibility: 'fellows' } });
step('发布动态', mPub.json.code === 0 && mPri.json.code === 0 && mFel.json.code === 0);
const pubId = mPub.json.data.moment_id;
const felId = mFel.json.data.moment_id;

// D（好友）的 feed：可见公开+老乡圈（C、D 同乡同镇），不可见私密
const feedD = await api('GET', '/v1/moments/feed', { token: D.token });
const dIds = feedD.json.data.items.map((m) => m.moment_id);
step('好友 feed 可见性', dIds.includes(pubId) && dIds.includes(felId) && !dIds.includes(mPri.json.data.moment_id));

// E（陌生人）：public 可见（种子用户 stranger_moments_10 默认关 → 实际不可见）
const cardE = await api('GET', `/v1/users/${C.userId}/moments`, { token: E2.token });
step('陌生人十条默认关闭', cardE.json.code === 0 && cardE.json.data.items.length === 0);

// 互动：D 点赞+评论；E 不可见（无权）
const like = await api('POST', `/v1/moments/${pubId}/likes`, { token: D.token });
const cmt = await api('POST', `/v1/moments/${pubId}/comments`, { token: D.token, body: { content: '母校变化真大' } });
const likeE = await api('POST', `/v1/moments/${pubId}/likes`, { token: E2.token });
step('好友点赞评论', like.json.code === 0 && cmt.json.code === 0);
step('陌生人互动被拒', likeE.json.code === 40301);

// 互动过滤：F 是 C 的好友但不是 D 的好友 → F 看不到 D 的评论
const F = await register('135' + suffix3 + '02', '好友F');
await api('POST', '/v1/friends/requests', { token: F.token, body: { to_user_id: C.userId, verify_msg: '老同学' } });
const inboxC = await api('GET', '/v1/friends/requests?box=inbox', { token: C.token });
const reqF = inboxC.json.data.items.find((i) => i.from_user_id === F.userId && i.status === 'pending');
await api('POST', `/v1/friends/requests/${reqF.id}/accept`, { token: C.token });
const detailF = await api('GET', `/v1/moments/${pubId}`, { token: F.token });
const detailD = await api('GET', `/v1/moments/${pubId}`, { token: D.token });
step('互动仅共同好友可见', detailF.json.code === 0 && detailF.json.data.comments.length === 0 && detailD.json.data.comments.length === 1);

// 45001 内容拦截 + 作者删除
const bad = await api('POST', '/v1/moments', { token: C.token, body: { content_type: 'text', content: '加我V信 abc12345', visibility: 'public' } });
step('动态 45001 拦截', bad.json.code === 45001);
const delByD = await api('DELETE', `/v1/moments/${pubId}`, { token: D.token });
const delByC = await api('DELETE', `/v1/moments/${pubId}`, { token: C.token });
step('仅作者可删', delByD.json.code === 40301 && delByC.json.code === 0);
const feedAfter = await api('GET', '/v1/moments/feed', { token: D.token });
step('删除后 feed 消失', !feedAfter.json.data.items.some((m) => m.moment_id === pubId));

console.log('moments check done');
