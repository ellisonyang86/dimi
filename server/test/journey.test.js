import { test } from 'node:test';
import assert from 'node:assert/strict';
import { startTestServer, api, registerUser, addDemoClassEducation, befriend } from './helpers.js';

// 完整找回旅程：注册 → 填经历 → 锚点检索 → 渐显资料卡 → 申请（内容安全 + 正常）
// → accept → V1 互证自动升级 → 单聊发消息/已读
test('完整找回旅程（检索→辨认→申请→通过→对话）', async (t) => {
  const { base, close } = await startTestServer();
  t.after(close);

  // 注册 A(男) / B(女) / C / D，均填同班经历
  const A = await registerUser(base, { phone: '13910000001', nickname: '阿明', gender: 1, real_name: '王明' });
  const B = await registerUser(base, { phone: '13910000002', nickname: '小芳', gender: 2, real_name: '林小芳' });
  const C = await registerUser(base, { phone: '13910000003', nickname: '铁柱', gender: 1, real_name: '赵铁柱' });
  const D = await registerUser(base, { phone: '13910000004', nickname: '丽娟', gender: 2, real_name: '孙丽娟' });
  for (const u of [A, B, C, D]) await addDemoClassEducation(base, u.token);

  // B 先与 C、D 成为同班好友（为互证升级凑齐「A 加入后 ≥3 名同单元好友」）
  await befriend(base, B, C);
  await befriend(base, B, D);

  // A 锚点检索命中 B（school_id+enroll_year + 姓名）
  const search = await api(base, 'GET', '/v1/discover/search-user?school_id=1001&enroll_year=1996&name=林小芳', { token: A.token });
  assert.equal(search.json.code, 0);
  const hit = search.json.data.items.find((i) => i.user_id === B.userId);
  assert.ok(hit, '锚点检索应命中 B');
  // 渐显：A-B 为 T3 同班，但 B 为女性默认加一档 → 按 T2 掩码名展示「林*芳」
  assert.equal(hit.real_name, '林*芳');
  assert.equal(hit.intersection_tier, 'T2');
  assert.ok(hit.match_tags.includes('同班'));

  // 资料卡渐显正确：掩码名 + V0 限定句交集横幅（双方经历均 verification_level=0 → 未验证措辞）
  const card = await api(base, 'GET', `/v1/users/${B.userId}`, { token: A.token });
  assert.equal(card.json.code, 0);
  assert.equal(card.json.data.real_name, '林*芳');
  assert.ok(card.json.data.intersection_banner.includes('未验证'), 'V0 经历横幅应带「未验证」限定句');
  assert.ok(card.json.data.intersection_banner.includes('六年2班'));
  assert.ok(card.json.data.hometown_display === undefined, 'B 未填家乡时该字段整块缺省');

  // 内容安全：验证语含手机号 → 45001
  const bad1 = await api(base, 'POST', '/v1/friends/requests', {
    token: A.token, body: { to_user_id: B.userId, verify_msg: '我电话13812345678，联系我' },
  });
  assert.equal(bad1.json.code, 45001);
  // 含微信号 → 45001
  const bad2 = await api(base, 'POST', '/v1/friends/requests', {
    token: A.token, body: { to_user_id: B.userId, verify_msg: '加我微信 wxid_abc123' },
  });
  assert.equal(bad2.json.code, 45001);

  // 正常申请通过
  const reqOk = await api(base, 'POST', '/v1/friends/requests', {
    token: A.token, body: { to_user_id: B.userId, verify_msg: '我是96届六年2班的王明', source: 'classmate_search' },
  });
  assert.equal(reqOk.json.code, 0);
  const requestId = reqOk.json.data.request_id;

  // B 收件箱：钥匙式披露——申请人真名随申请披露给被申请人（A 未关 attach_real_name）
  const inbox = await api(base, 'GET', '/v1/friends/requests?box=inbox', { token: B.token });
  const item = inbox.json.data.items.find((i) => i.id === requestId);
  assert.ok(item);
  assert.equal(item.from_user.real_name, '王明');
  assert.equal(item.verify_msg, '我是96届六年2班的王明');
  assert.ok(item.intersection_snapshot.includes('六年2班'), '交集快照应冻结班级证据');

  // B accept → 建立好友 + 返回会话
  const acc = await api(base, 'POST', `/v1/friends/requests/${requestId}/accept`, { token: B.token });
  assert.equal(acc.json.code, 0);
  const convId = acc.json.data.conversation_id;
  assert.ok(convId > 0);

  // 互证升级断言：B 的同单元好友 = C、D、A（3 人）→ 经历升 V1/peer_review
  const eduB = await api(base, 'GET', '/v1/users/me/educations', { token: B.token });
  assert.equal(eduB.json.data.items[0].verification_level, 1);
  assert.equal(eduB.json.data.items[0].verification_source, 'peer_review');
  assert.ok(eduB.json.data.items[0].verified_at);
  // A 只有 1 名同班好友（B），不升级
  const eduA = await api(base, 'GET', '/v1/users/me/educations', { token: A.token });
  assert.equal(eduA.json.data.items[0].verification_level, 0);

  // 成为好友后真名互见（渐显完成）
  const card2 = await api(base, 'GET', `/v1/users/${B.userId}`, { token: A.token });
  assert.equal(card2.json.data.real_name, '林小芳');
  assert.equal(card2.json.data.intersection_tier, 'FRIEND');

  // 单聊：A 发消息（client_msg_id 幂等）→ B 未读 1 → 拉取 → 已读归零
  const m1 = await api(base, 'POST', `/v1/conversations/${convId}/messages`, {
    token: A.token, body: { client_msg_id: 'journey-m1', msg_type: 'text', content: '小芳，还记得我吗？' },
  });
  assert.equal(m1.json.code, 0);
  const msgId = m1.json.data.msg_id;
  const m1dup = await api(base, 'POST', `/v1/conversations/${convId}/messages`, {
    token: A.token, body: { client_msg_id: 'journey-m1', msg_type: 'text', content: '小芳，还记得我吗？' },
  });
  assert.equal(m1dup.json.data.msg_id, msgId, 'client_msg_id 幂等防重');
  assert.equal(m1dup.json.data.duplicated, true);

  const convsB = await api(base, 'GET', '/v1/conversations', { token: B.token });
  const convB = convsB.json.data.items.find((c) => c.conv_id === convId);
  assert.equal(convB.unread_count, 1);
  assert.ok(convB.intersection_banner.includes('六年2班'), '单聊顶部应有交集标签条');

  const msgs = await api(base, 'GET', `/v1/conversations/${convId}/messages`, { token: B.token });
  const textMsg = msgs.json.data.items.find((m) => m.msg_id === msgId);
  assert.equal(textMsg.content, '小芳，还记得我吗？');
  assert.equal(textMsg.sender.real_name, '王明', '好友消息署名应为真名');
  assert.ok(msgs.json.data.items.some((m) => m.msg_type === 'system'), '应有破冰系统消息');

  const read = await api(base, 'POST', `/v1/conversations/${convId}/read`, {
    token: B.token, body: { last_read_msg_id: msgId },
  });
  assert.equal(read.json.code, 0);
  const convsB2 = await api(base, 'GET', '/v1/conversations', { token: B.token });
  assert.equal(convsB2.json.data.items.find((c) => c.conv_id === convId).unread_count, 0);
});
