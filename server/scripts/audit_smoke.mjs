// 全量审计冒烟（a–j）：注册 → 教育经历 → 找同学 → 好友链 → 单聊 → 朋友圈可见性
// → 互动/未读/共同好友隔离 → 拉黑断联 → 内容安全 45001 → 幂等/频控抽查
// 运行：DIMI_SMS_DEV=true PORT=8080 node src/index.js 另开终端执行 node scripts/audit_smoke.mjs
const base = process.env.SMOKE_BASE || 'http://127.0.0.1:8080';

let passed = 0, failed = 0;
const failures = [];
function step(name, ok, extra = '') {
  if (ok) passed++;
  else { failed++; failures.push({ name, extra }); }
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${extra ? '  → ' + extra : ''}`);
}

async function api(method, p, { token, body, headers } = {}) {
  const res = await fetch(base + p, {
    method,
    headers: {
      ...(body ? { 'Content-Type': 'application/json' } : {}),
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...headers,
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  let json = null;
  try { json = await res.json(); } catch { /* ignore */ }
  return { status: res.status, json };
}
const brief = (r) => `HTTP ${r.status} code=${r.json?.code} msg=${r.json?.message}`;

const suffix = String(Math.floor(Math.random() * 1e6)).padStart(6, '0');
const randPhone = () => '137' + String(Math.floor(Math.random() * 1e8)).padStart(8, '0');

async function registerUser({ nickname, realName }) {
  const phone = randPhone();
  const sms = await api('POST', '/v1/auth/sms/send', { body: { phone } });
  if (sms.json?.code !== 0) throw new Error('sms/send: ' + brief(sms));
  const reg = await api('POST', '/v1/auth/register', {
    body: { phone, sms_code: sms.json.data.sms_code, nickname, gender: 1, birth_year: 1990 },
  });
  if (reg.json?.code !== 0) throw new Error('register: ' + brief(reg));
  const token = reg.json.data.access_token;
  const userId = reg.json.data.user.user_id;
  const rn = await api('PUT', '/v1/users/me', { token, body: { real_name: realName } });
  if (rn.json?.code !== 0) throw new Error('real_name: ' + brief(rn));
  return { token, userId, phone, realName };
}

async function befriend(from, to, verifyMsg, idemKey) {
  const req = await api('POST', '/v1/friends/requests', {
    token: from.token,
    body: { to_user_id: to.userId, verify_msg: verifyMsg },
    headers: idemKey ? { 'Idempotency-Key': idemKey } : {},
  });
  if (req.json?.code !== 0) return { req };
  const inbox = await api('GET', '/v1/friends/requests?box=inbox', { token: to.token });
  const item = inbox.json?.data?.items?.find((i) => i.from_user_id === from.userId && i.status === 'pending');
  if (!item) return { req, inbox };
  const acc = await api('POST', `/v1/friends/requests/${item.id}/accept`, { token: to.token });
  return { req, acc, convId: acc.json?.data?.conversation_id };
}

// ---------- a. 注册 A/B/C ----------
const nameA = '审甲' + suffix, nameB = '审乙' + suffix, nameC = '审丙' + suffix;
const A = await registerUser({ nickname: '审计甲', realName: nameA });
const B = await registerUser({ nickname: '审计乙', realName: nameB });
const C = await registerUser({ nickname: '审计丙', realName: nameC });
step('a. 注册 A/B/C 拿 token', !!(A.token && B.token && C.token), `A=${A.userId} B=${B.userId} C=${C.userId}`);

// ---------- b. 教育经历（同班：城关镇第二小学 1996 级 六年9班） ----------
const eduBody = { stage: 'PRIMARY', school_id: 1001, enroll_year: 1996, class_name: '六年9班' };
const eduA = await api('POST', '/v1/users/me/educations', { token: A.token, body: eduBody });
const eduB = await api('POST', '/v1/users/me/educations', { token: B.token, body: eduBody });
step('b. A/B 添加同班教育经历', eduA.json?.code === 0 && eduB.json?.code === 0,
  `A:${brief(eduA)} B:${brief(eduB)}`);
// C 添加同校不同班（grade 同窗，但不同班）：用于 classmates 可见性负面对照
const eduC = await api('POST', '/v1/users/me/educations', {
  token: C.token, body: { stage: 'PRIMARY', school_id: 1001, enroll_year: 1997, class_name: '六年1班' },
});
step('b2. C 添加非同班经历（对照组）', eduC.json?.code === 0, brief(eduC));

// ---------- c. A 精确搜索找到 B ----------
const search = await api('GET', `/v1/discover/search-user?school_id=1001&enroll_year=1996&name=${encodeURIComponent(nameB)}`, { token: A.token });
const hitB = search.json?.data?.items?.find((i) => i.user_id === B.userId);
step('c. A 锚点+姓名检索到 B', search.json?.code === 0 && !!hitB,
  hitB ? `tier=${hitB.intersection_tier} masked=${search.json.data.total_masked}` : brief(search));
// 无锚点纯姓名检索应被 40001 拒绝
const noAnchor = await api('GET', `/v1/discover/search-user?name=${encodeURIComponent(nameB)}`, { token: A.token });
step('c2. 无锚点检索被 40001 拒绝', noAnchor.json?.code === 40001, brief(noAnchor));

// ---------- d. 好友申请链 ----------
const badReq = await api('POST', '/v1/friends/requests', {
  token: A.token, body: { to_user_id: B.userId, verify_msg: '加我微信13800001111' },
});
step('d0. 验证语含联系方式被 45001 拦截', badReq.json?.code === 45001, brief(badReq));
const d = await befriend(A, B, '我是96届六年9班的老同学');
step('d. A→B 申请 → B 同意 → 成为好友', d.acc?.json?.code === 0 && !!d.convId, `conv=${d.convId}`);
const friendsA = await api('GET', '/v1/friends', { token: A.token });
const friendsB = await api('GET', '/v1/friends', { token: B.token });
step('d2. 双方好友列表互见',
  friendsA.json?.data?.items?.some((i) => i.user_id === B.userId) &&
  friendsB.json?.data?.items?.some((i) => i.user_id === A.userId));

// ---------- e. 单聊 ----------
const msg1 = await api('POST', `/v1/conversations/${d.convId}/messages`, {
  token: A.token, body: { client_msg_id: `audit-${suffix}-1`, msg_type: 'text', content: '乙，是我，甲！' },
});
step('e. A 发单聊消息', msg1.json?.code === 0 && !!msg1.json?.data?.msg_id, brief(msg1));
const convsB = await api('GET', '/v1/conversations', { token: B.token });
const convB = convsB.json?.data?.items?.find((c) => c.conv_id === d.convId);
step('e2. B 会话列表可见且有未读', !!convB && convB.unread_count >= 1,
  convB ? `unread=${convB.unread_count} last="${convB.last_msg_summary}"` : brief(convsB));
const msgsB = await api('GET', `/v1/conversations/${d.convId}/messages`, { token: B.token });
step('e3. B 拉取消息确认收到',
  msgsB.json?.data?.items?.some((m) => m.content === '乙，是我，甲！' && m.sender?.user_id === A.userId));

// ---------- f. 朋友圈 ----------
const mPub = await api('POST', '/v1/moments', {
  token: A.token, body: { content_type: 'text', content: '周六回母校看了看，操场还是老样子。', visibility: 'public' },
});
step('f. A 发纯文字朋友圈（public）', mPub.json?.code === 0 && !!mPub.json?.data?.moment_id, brief(mPub));
const mCls = await api('POST', '/v1/moments', {
  token: A.token, body: { content_type: 'text', content: '六年9班的老同学们，聚一次吧。', visibility: 'classmates' },
});
step('f2. A 发同学圈可见动态（classmates）', mCls.json?.code === 0, brief(mCls));
const pubId = mPub.json?.data?.moment_id, clsId = mCls.json?.data?.moment_id;
const feedB = await api('GET', '/v1/moments/feed', { token: B.token });
const feedBIds = feedB.json?.data?.items?.map((m) => m.moment_id) || [];
step('f3. B 的 feed 可见 A 的 public 与 classmates 动态',
  feedBIds.includes(pubId) && feedBIds.includes(clsId), `feed=${JSON.stringify(feedBIds)}`);

// C 先与 A 成为好友（g/h 需要）；C 与 A 不同届 → classmates 动态对 C 不可见
const idemKey = `audit-idem-${suffix}`;
const cReq1 = await api('POST', '/v1/friends/requests', {
  token: A.token, body: { to_user_id: C.userId, verify_msg: '丙，我是甲' },
  headers: { 'Idempotency-Key': idemKey },
});
// j. 幂等：相同 Idempotency-Key 重放
const cReq2 = await api('POST', '/v1/friends/requests', {
  token: A.token, body: { to_user_id: C.userId, verify_msg: '丙，我是甲' },
  headers: { 'Idempotency-Key': idemKey },
});
step('j. Idempotency-Key 重放返回相同 request_id',
  cReq1.json?.code === 0 && cReq2.json?.code === 0 &&
  cReq1.json.data.request_id === cReq2.json.data.request_id,
  `id1=${cReq1.json?.data?.request_id} id2=${cReq2.json?.data?.request_id} msg2=${cReq2.json?.message}`);
const inboxC = await api('GET', '/v1/friends/requests?box=inbox', { token: C.token });
const itemC = inboxC.json?.data?.items?.find((i) => i.from_user_id === A.userId && i.status === 'pending');
const accC = itemC ? await api('POST', `/v1/friends/requests/${itemC.id}/accept`, { token: C.token }) : null;
step('g0. C 与 A 成为好友（C 非 B 好友，作互动隔离对照）', accC?.json?.code === 0, accC ? brief(accC) : 'no pending request');

const feedC = await api('GET', '/v1/moments/feed', { token: C.token });
const feedCIds = feedC.json?.data?.items?.map((m) => m.moment_id) || [];
step('f4. C（好友但非同窗）可见 public、不可见 classmates 动态',
  feedCIds.includes(pubId) && !feedCIds.includes(clsId), `feed=${JSON.stringify(feedCIds)}`);
const clsDetailC = await api('GET', `/v1/moments/${clsId}`, { token: C.token });
step('f5. C 直接访问 classmates 动态详情被拒（40301）', clsDetailC.json?.code === 40301, brief(clsDetailC));

// ---------- g. 互动与未读 ----------
const like = await api('POST', `/v1/moments/${pubId}/likes`, { token: B.token });
const comment = await api('POST', `/v1/moments/${pubId}/comments`, {
  token: B.token, body: { content: '操场那棵槐树还在吗？' },
});
step('g. B 点赞+评论 A 的动态', like.json?.code === 0 && comment.json?.code === 0,
  `like:${brief(like)} comment:${brief(comment)}`);
const unread = await api('GET', '/v1/moments/interactions/unread?since=0', { token: A.token });
step('g2. A 的互动未读 has_new=true', unread.json?.data?.has_new === true, JSON.stringify(unread.json?.data));
const detailB = await api('GET', `/v1/moments/${pubId}`, { token: B.token });
step('g3. B（共同好友）看详情可见自己的点赞与评论',
  detailB.json?.data?.like_count >= 1 && detailB.json?.data?.comments?.some((c) => c.content === '操场那棵槐树还在吗？'));
const detailC = await api('GET', `/v1/moments/${pubId}`, { token: C.token });
const cSeesB = detailC.json?.data?.comments?.some((c) => c.content === '操场那棵槐树还在吗？') || (detailC.json?.data?.like_count ?? 0) > 0;
step('g4. C（非 B 好友）看 A 的动态详情，看不到 B 的互动',
  detailC.json?.code === 0 && !cSeesB,
  `like_count=${detailC.json?.data?.like_count} comments=${JSON.stringify(detailC.json?.data?.comments?.map((c) => c.content))}`);

// ---------- h. 拉黑双向断联 ----------
const mB = await api('POST', '/v1/moments', { token: B.token, body: { content_type: 'text', content: '乙的一条动态。', visibility: 'public' } });
const feedA0 = await api('GET', '/v1/moments/feed', { token: A.token });
const bVisibleBefore = feedA0.json?.data?.items?.some((m) => m.moment_id === mB.json?.data?.moment_id);
const block = await api('POST', `/v1/friends/${A.userId}/block`, { token: B.token });
step('h. B 拉黑 A', block.json?.code === 0, brief(block));
const msgAfter = await api('POST', `/v1/conversations/${d.convId}/messages`, {
  token: A.token, body: { client_msg_id: `audit-${suffix}-2`, msg_type: 'text', content: '还能收到吗' },
});
step('h2. 拉黑后 A→B 发消息被拒（40301）', msgAfter.json?.code === 40301, brief(msgAfter));
const feedA1 = await api('GET', '/v1/moments/feed', { token: A.token });
const bVisibleAfter = feedA1.json?.data?.items?.some((m) => m.moment_id === mB.json?.data?.moment_id);
step('h3. 拉黑后 A 的 feed 不再可见 B 的动态', bVisibleBefore && !bVisibleAfter,
  `before=${bVisibleBefore} after=${bVisibleAfter}`);
const feedB1 = await api('GET', '/v1/moments/feed', { token: B.token });
step('h4. 拉黑后 B 的 feed 也不再可见 A 的动态（双向）',
  !feedB1.json?.data?.items?.some((m) => m.author?.user_id === A.userId));
const searchAfter = await api('GET', `/v1/discover/search-user?school_id=1001&enroll_year=1996&name=${encodeURIComponent(nameB)}`, { token: A.token });
step('h5. 拉黑后 A 检索不到 B', !searchAfter.json?.data?.items?.some((i) => i.user_id === B.userId),
  `items=${searchAfter.json?.data?.items?.length}`);
const unblock = await api('DELETE', `/v1/friends/${A.userId}/block`, { token: B.token });
const msgBack = await api('POST', `/v1/conversations/${d.convId}/messages`, {
  token: A.token, body: { client_msg_id: `audit-${suffix}-3`, msg_type: 'text', content: '解除了，测试完毕' },
});
step('h6. 解除拉黑后消息恢复（清理现场）', unblock.json?.code === 0 && msgBack.json?.code === 0,
  `unblock:${brief(unblock)} msg:${brief(msgBack)}`);

// ---------- i. 内容安全 45001 ----------
const mBad = await api('POST', '/v1/moments', {
  token: A.token, body: { content_type: 'text', content: '加我微信13800001111', visibility: 'public' },
});
step('i. 动态含联系方式被 45001 拦截', mBad.json?.code === 45001, brief(mBad));
const cBad = await api('POST', `/v1/moments/${pubId}/comments`, {
  token: B.token, body: { content: '加我V信详聊' },
});
step('i2. 评论含导流信息被 45001 拦截', cBad.json?.code === 45001, brief(cBad));
// 误伤观察：纯英文单词（≥6 字母）会被微信号模式命中？
const mFp = await api('POST', '/v1/moments', {
  token: A.token, body: { content_type: 'text', content: 'Saturday morning, feeling great!', visibility: 'public' },
});
console.log(`INFO  误伤观察：纯英文动态 "Saturday morning..." → ${brief(mFp)}（code=45001 说明微信号正则误伤正常英文）`);

// ---------- j2. 消息幂等（client_msg_id 重复） ----------
const dup1 = await api('POST', `/v1/conversations/${d.convId}/messages`, {
  token: A.token, body: { client_msg_id: `audit-${suffix}-dup`, msg_type: 'text', content: '幂等测试' },
});
const dup2 = await api('POST', `/v1/conversations/${d.convId}/messages`, {
  token: A.token, body: { client_msg_id: `audit-${suffix}-dup`, msg_type: 'text', content: '幂等测试' },
});
step('j2. 相同 client_msg_id 重发返回 duplicated=true 且 msg_id 相同',
  dup1.json?.code === 0 && dup2.json?.data?.duplicated === true &&
  dup1.json?.data?.msg_id === dup2.json?.data?.msg_id,
  `msg1=${dup1.json?.data?.msg_id} msg2=${dup2.json?.data?.msg_id} dup=${dup2.json?.data?.duplicated}`);

console.log(`\n===== 结果：${passed} PASS / ${failed} FAIL =====`);
if (failures.length) {
  for (const f of failures) console.log(`FAIL 明细：${f.name} → ${f.extra}`);
  process.exit(1);
}
