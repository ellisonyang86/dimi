import { test } from 'node:test';
import assert from 'node:assert/strict';
import { startTestServer, api, registerUser, addDemoClassEducation } from './helpers.js';

// 班级群聊：建群幂等 / 入群校验 / 群消息收发 / 独立未读位点 / 非成员拒发 / 退群与群主顺延
test('班级群聊全流程', async (t) => {
  const { base, db, close } = await startTestServer();
  t.after(close);

  const A = await registerUser(base, { phone: '13920000001', nickname: '阿明', gender: 1, real_name: '王明' });
  const B = await registerUser(base, { phone: '13920000002', nickname: '小芳', gender: 2, real_name: '林小芳' });
  const C = await registerUser(base, { phone: '13920000003', nickname: '铁柱', gender: 1, real_name: '赵铁柱' });
  const D = await registerUser(base, { phone: '13920000004', nickname: '路人', gender: 1 });
  for (const u of [A, B, C]) await addDemoClassEducation(base, u.token); // 城关二小 1996级 六年2班
  // D 没有任何教育经历

  // mine：A 有一个班级单元，群尚未创建
  const mine0 = await api(base, 'GET', '/v1/class-groups/mine', { token: A.token });
  assert.equal(mine0.json.code, 0);
  assert.equal(mine0.json.data.items.length, 1);
  assert.equal(mine0.json.data.items[0].school_name, '城关镇第二小学');
  assert.equal(mine0.json.data.items[0].class_name, '六年2班');
  assert.equal(mine0.json.data.items[0].group, null);

  // 无该单元教育经历者 join 被拒
  const joinD = await api(base, 'POST', '/v1/class-groups/join', {
    token: D.token, body: { school_id: 1001, enroll_year: 1996, class_name: '六年2班' },
  });
  assert.equal(joinD.json.code, 40301);

  // A 创建并入群（class_name 原文走规范化）
  const joinA = await api(base, 'POST', '/v1/class-groups/join', {
    token: A.token, body: { school_id: 1001, enroll_year: 1996, class_name: '六年2班' },
  });
  assert.equal(joinA.json.code, 0);
  assert.equal(joinA.json.data.created, true);
  assert.equal(joinA.json.data.member_count, 1);
  const convId = joinA.json.data.conv_id;
  assert.ok(convId > 0);
  assert.ok(joinA.json.data.title.includes('六年2班'));

  // 建群幂等：A 重复 join / B 加入均落到同一个群，class_groups 仅一行
  const joinA2 = await api(base, 'POST', '/v1/class-groups/join', {
    token: A.token, body: { school_id: 1001, enroll_year: 1996, class_name_norm: '6-2' },
  });
  assert.equal(joinA2.json.data.conv_id, convId);
  assert.equal(joinA2.json.data.created, false);
  assert.equal(joinA2.json.data.member_count, 1, '重复 join 不产生重复成员');
  const joinB = await api(base, 'POST', '/v1/class-groups/join', {
    token: B.token, body: { school_id: 1001, enroll_year: 1996, class_name: '六年2班' },
  });
  assert.equal(joinB.json.data.conv_id, convId);
  assert.equal(joinB.json.data.member_count, 2);
  const groupRows = db.prepare('SELECT COUNT(*) c FROM class_groups').get();
  assert.equal(groupRows.c, 1, '重复 join 不产生第二个群');

  // 群消息收发：A 发言，B 非好友也能看到（群成员不要求互为好友）
  const m1 = await api(base, 'POST', `/v1/conversations/${convId}/messages`, {
    token: A.token, body: { client_msg_id: 'cg-m1', msg_type: 'text', content: '同学们好！' },
  });
  assert.equal(m1.json.code, 0);
  const msg1Id = m1.json.data.msg_id;

  // 会话列表：群会话带标题/成员数/未读数；B 未读 1，A 未读 0
  const convsB = await api(base, 'GET', '/v1/conversations', { token: B.token });
  const convB = convsB.json.data.items.find((c) => c.conv_id === convId);
  assert.equal(convB.conv_type, 'group');
  assert.equal(convB.group_kind, 'class');
  assert.equal(convB.member_count, 2);
  assert.ok(convB.title.includes('六年2班'));
  assert.equal(convB.unread_count, 1);
  assert.equal(convB.last_msg_summary, '同学们好！');
  const convsA = await api(base, 'GET', '/v1/conversations', { token: A.token });
  assert.equal(convsA.json.data.items.find((c) => c.conv_id === convId).unread_count, 0);

  // B 拉消息可见；since_msg_id 增量正序
  const msgsB = await api(base, 'GET', `/v1/conversations/${convId}/messages`, { token: B.token });
  assert.ok(msgsB.json.data.items.some((m) => m.msg_id === msg1Id && m.content === '同学们好！'));
  const m2 = await api(base, 'POST', `/v1/conversations/${convId}/messages`, {
    token: B.token, body: { client_msg_id: 'cg-m2', msg_type: 'text', content: '王明！真的是你' },
  });
  assert.equal(m2.json.code, 0);
  const inc = await api(base, 'GET', `/v1/conversations/${convId}/messages?since_msg_id=${msg1Id}`, { token: A.token });
  assert.deepEqual(inc.json.data.items.map((m) => m.msg_id), [m2.json.data.msg_id], 'since_msg_id 只返回增量且正序');

  // 未读位点按成员独立：C 入群后未读 2；B 已读归零后 C 仍为 2
  const joinC = await api(base, 'POST', '/v1/class-groups/join', {
    token: C.token, body: { school_id: 1001, enroll_year: 1996, class_name: '六年2班' },
  });
  assert.equal(joinC.json.data.member_count, 3);
  const mineC = await api(base, 'GET', '/v1/class-groups/mine', { token: C.token });
  assert.equal(mineC.json.data.items[0].group.unread_count, 2);
  await api(base, 'POST', `/v1/conversations/${convId}/read`, { token: B.token, body: { last_read_msg_id: m2.json.data.msg_id } });
  const mineB = await api(base, 'GET', '/v1/class-groups/mine', { token: B.token });
  assert.equal(mineB.json.data.items[0].group.unread_count, 0);
  const mineC2 = await api(base, 'GET', '/v1/class-groups/mine', { token: C.token });
  assert.equal(mineC2.json.data.items[0].group.unread_count, 2, 'B 的已读不影响 C 的位点');

  // 成员列表：姓名走可见性引擎（非好友同班同学按渐显规则掩码），群主标记正确
  const members = await api(base, 'GET', `/v1/class-groups/${convId}/members`, { token: A.token });
  assert.equal(members.json.code, 0);
  assert.equal(members.json.data.items.length, 3);
  assert.equal(members.json.data.owner_id, A.userId);
  assert.equal(members.json.data.items.find((i) => i.user_id === A.userId).is_owner, true);
  const viewOfB = members.json.data.items.find((i) => i.user_id === B.userId);
  assert.notEqual(viewOfB.real_name, '林小芳', '非好友成员真名应按渐显规则掩码');

  // 非成员（D 未入群）发消息被拒、看成员列表被拒
  const sendD = await api(base, 'POST', `/v1/conversations/${convId}/messages`, {
    token: D.token, body: { client_msg_id: 'cg-d1', msg_type: 'text', content: '我也想进群' },
  });
  assert.equal(sendD.json.code, 40301);
  const membersD = await api(base, 'GET', `/v1/class-groups/${convId}/members`, { token: D.token });
  assert.equal(membersD.json.code, 40301);

  // 群公告：非群主被拒；群主可改；超长被拒
  const annB = await api(base, 'PUT', `/v1/class-groups/${convId}/announcement`, {
    token: B.token, body: { announcement: '本周六聚会' },
  });
  assert.equal(annB.json.code, 40301);
  const annLong = await api(base, 'PUT', `/v1/class-groups/${convId}/announcement`, {
    token: A.token, body: { announcement: '长'.repeat(201) },
  });
  assert.equal(annLong.json.code, 40001);
  const annA = await api(base, 'PUT', `/v1/class-groups/${convId}/announcement`, {
    token: A.token, body: { announcement: '本周六上午十点母校门口集合' },
  });
  assert.equal(annA.json.code, 0);
  const mineA = await api(base, 'GET', '/v1/class-groups/mine', { token: A.token });
  assert.equal(mineA.json.data.items[0].group.announcement, '本周六上午十点母校门口集合');

  // 退群后发消息被拒
  const leaveB = await api(base, 'POST', `/v1/class-groups/${convId}/leave`, { token: B.token });
  assert.equal(leaveB.json.code, 0);
  const sendB2 = await api(base, 'POST', `/v1/conversations/${convId}/messages`, {
    token: B.token, body: { client_msg_id: 'cg-b2', msg_type: 'text', content: '我还在吗' },
  });
  assert.equal(sendB2.json.code, 40301, '退群后发言被拒');

  // 群主 A 退群 → 群主顺延给最早加入者 C（B 已退）；群与消息历史保留
  const leaveA = await api(base, 'POST', `/v1/class-groups/${convId}/leave`, { token: A.token });
  assert.equal(leaveA.json.code, 0);
  const ownerRow = db.prepare('SELECT created_by FROM class_groups WHERE conv_id=?').get(convId);
  assert.equal(ownerRow.created_by, C.userId, '群主顺延给最早加入者');
  const membersC = await api(base, 'GET', `/v1/class-groups/${convId}/members`, { token: C.token });
  assert.equal(membersC.json.data.owner_id, C.userId);
  const msgsC = await api(base, 'GET', `/v1/conversations/${convId}/messages`, { token: C.token });
  assert.ok(msgsC.json.data.items.some((m) => m.msg_id === msg1Id), '退群后消息历史保留');
  // 新群主 C 可改公告
  const annC = await api(base, 'PUT', `/v1/class-groups/${convId}/announcement`, {
    token: C.token, body: { announcement: '新群主上任' },
  });
  assert.equal(annC.json.code, 0);

  // 群主 C 退群 → 群空：created_by 置 NULL（群与消息历史保留），不再悬空给已退群者
  const leaveC = await api(base, 'POST', `/v1/class-groups/${convId}/leave`, { token: C.token });
  assert.equal(leaveC.json.code, 0);
  const ownerRow2 = db.prepare('SELECT created_by FROM class_groups WHERE conv_id=?').get(convId);
  assert.equal(ownerRow2.created_by, null, '空群时 created_by 置 NULL，待下位 join 者补位');
  const mineB2 = await api(base, 'GET', '/v1/class-groups/mine', { token: B.token });
  assert.equal(mineB2.json.data.items[0].group.member_count, 0, '群空但群仍存在');

  // 空群补位：B 重新 join → 继任群主，可改公告，消息历史仍在
  const rejoinB = await api(base, 'POST', '/v1/class-groups/join', {
    token: B.token, body: { school_id: 1001, enroll_year: 1996, class_name: '六年2班' },
  });
  assert.equal(rejoinB.json.code, 0);
  assert.equal(rejoinB.json.data.conv_id, convId);
  assert.equal(rejoinB.json.data.created, false, '群未销毁，重 join 不新建');
  const ownerRow3 = db.prepare('SELECT created_by FROM class_groups WHERE conv_id=?').get(convId);
  assert.equal(ownerRow3.created_by, B.userId, '空群后 join 者补位为群主');
  const membersB = await api(base, 'GET', `/v1/class-groups/${convId}/members`, { token: B.token });
  assert.equal(membersB.json.data.owner_id, B.userId);
  assert.equal(membersB.json.data.items.find((i) => i.user_id === B.userId).is_owner, true);
  const annB2 = await api(base, 'PUT', `/v1/class-groups/${convId}/announcement`, {
    token: B.token, body: { announcement: '老群主回归' },
  });
  assert.equal(annB2.json.code, 0, '补位群主可改公告');
  const msgsB2 = await api(base, 'GET', `/v1/conversations/${convId}/messages`, { token: B.token });
  assert.ok(msgsB2.json.data.items.some((m) => m.msg_id === msg1Id), '空群重 join 后消息历史保留');

  // 已退群的原群主 C 不再是群主且非成员，改公告被拒
  const annC2 = await api(base, 'PUT', `/v1/class-groups/${convId}/announcement`, {
    token: C.token, body: { announcement: '我还想管事' },
  });
  assert.equal(annC2.json.code, 40301);

  // 防御：非空群 created_by 异常为 NULL 时（理论上不应出现），join 者补位
  db.prepare('UPDATE class_groups SET created_by=NULL WHERE conv_id=?').run(convId);
  const rejoinA = await api(base, 'POST', '/v1/class-groups/join', {
    token: A.token, body: { school_id: 1001, enroll_year: 1996, class_name: '六年2班' },
  });
  assert.equal(rejoinA.json.code, 0);
  const ownerRow4 = db.prepare('SELECT created_by FROM class_groups WHERE conv_id=?').get(convId);
  assert.equal(ownerRow4.created_by, A.userId, '非空群 created_by 为 NULL 时由 join 者补位');
});
