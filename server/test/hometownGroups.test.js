import { test } from 'node:test';
import assert from 'node:assert/strict';
import { startTestServer, api, registerUser } from './helpers.js';

// 设置家乡（type=1，需四级行政区划）：河南周口商水 411623xxx（市级前缀 4116）/ 浙江杭州西湖 330106005（前缀 3301）
async function setHometown(base, token, regionCode) {
  const r = await api(base, 'PUT', '/v1/users/me/hometown', { token, body: { type: 1, region_code: regionCode } });
  if (r.json?.code !== 0) throw new Error('set hometown failed: ' + JSON.stringify(r.json));
}

// 老乡群聊：未设家乡拒入 / 建群幂等 / 同市同群跨市不同群 / 群消息收发 / 退群与群主顺延
test('老乡群聊全流程', async (t) => {
  const { base, db, close } = await startTestServer();
  t.after(close);

  const A = await registerUser(base, { phone: '13930000001', nickname: '阿明', gender: 1, real_name: '王明' });
  const B = await registerUser(base, { phone: '13930000002', nickname: '小芳', gender: 2, real_name: '林小芳' });
  const C = await registerUser(base, { phone: '13930000003', nickname: '杭漂', gender: 1, real_name: '赵铁柱' });
  const D = await registerUser(base, { phone: '13930000004', nickname: '路人', gender: 1 });
  await setHometown(base, A.token, '411623102'); // 河南 周口市 商水县 城关乡
  await setHometown(base, B.token, '411623103'); // 河南 周口市 商水县 练集镇（同市）
  await setHometown(base, C.token, '330106005'); // 浙江 杭州市 西湖区 古荡街道（异市）
  // D 不设置家乡

  // 未设家乡：mine 为空，join 拒 40301
  const mineD = await api(base, 'GET', '/v1/hometown-groups/mine', { token: D.token });
  assert.equal(mineD.json.code, 0);
  assert.deepEqual(mineD.json.data.items, []);
  const joinD = await api(base, 'POST', '/v1/hometown-groups/join', { token: D.token });
  assert.equal(joinD.json.code, 40301);
  assert.equal(joinD.json.message, '先设置家乡才能加入老乡群');

  // mine：A 已设家乡，群尚未创建
  const mine0 = await api(base, 'GET', '/v1/hometown-groups/mine', { token: A.token });
  assert.equal(mine0.json.data.items.length, 1);
  assert.equal(mine0.json.data.items[0].region_code, '411623102');
  assert.equal(mine0.json.data.items[0].region_name, '周口市');
  assert.equal(mine0.json.data.items[0].group, null);

  // A 创建并入群
  const joinA = await api(base, 'POST', '/v1/hometown-groups/join', { token: A.token });
  assert.equal(joinA.json.code, 0);
  assert.equal(joinA.json.data.created, true);
  assert.equal(joinA.json.data.member_count, 1);
  assert.equal(joinA.json.data.title, '周口市老乡群');
  const convId = joinA.json.data.conv_id;
  assert.ok(convId > 0);

  // 建群幂等：A 重复 join 落同一个群；B 同市（不同乡镇）入同群，member_count=2
  const joinA2 = await api(base, 'POST', '/v1/hometown-groups/join', { token: A.token });
  assert.equal(joinA2.json.data.conv_id, convId);
  assert.equal(joinA2.json.data.created, false);
  assert.equal(joinA2.json.data.member_count, 1, '重复 join 不产生重复成员');
  const joinB = await api(base, 'POST', '/v1/hometown-groups/join', { token: B.token });
  assert.equal(joinB.json.data.conv_id, convId);
  assert.equal(joinB.json.data.member_count, 2);
  const groupRows = db.prepare("SELECT COUNT(*) c FROM hometown_groups WHERE region_prefix='4116'").get();
  assert.equal(groupRows.c, 1, '同市重复 join 不产生第二个群');

  // mine 返回 joined / 未读
  const mineA = await api(base, 'GET', '/v1/hometown-groups/mine', { token: A.token });
  assert.equal(mineA.json.data.items[0].group.joined, true);
  assert.equal(mineA.json.data.items[0].group.member_count, 2);

  // C 异市：入的是杭州市老乡群，与周口群不同
  const joinC = await api(base, 'POST', '/v1/hometown-groups/join', { token: C.token });
  assert.equal(joinC.json.code, 0);
  assert.equal(joinC.json.data.created, true);
  assert.equal(joinC.json.data.title, '杭州市老乡群');
  assert.notEqual(joinC.json.data.conv_id, convId, '不同市不同群');

  // 群消息收发：A 发言，B 非好友轮询可见（群成员不要求互为好友）
  const m1 = await api(base, 'POST', `/v1/conversations/${convId}/messages`, {
    token: A.token, body: { client_msg_id: 'hg-m1', msg_type: 'text', content: '老乡们好！' },
  });
  assert.equal(m1.json.code, 0);
  const msgsB = await api(base, 'GET', `/v1/conversations/${convId}/messages`, { token: B.token });
  assert.ok(msgsB.json.data.items.some((m) => m.msg_id === m1.json.data.msg_id && m.content === '老乡们好！'));
  const mineB = await api(base, 'GET', '/v1/hometown-groups/mine', { token: B.token });
  assert.equal(mineB.json.data.items[0].group.unread_count, 1);

  // 会话列表：老乡群会话 conv_type=group 且 group_kind='hometown'（群资料页据此区分）
  const convsB = await api(base, 'GET', '/v1/conversations', { token: B.token });
  const groupConv = convsB.json.data.items.find((c) => c.conv_id === convId);
  assert.ok(groupConv, '老乡群会话应出现在 /v1/conversations');
  assert.equal(groupConv.conv_type, 'group');
  assert.equal(groupConv.group_kind, 'hometown');

  // 非成员（C 在杭州群）发消息被拒、看成员列表被拒
  const sendC = await api(base, 'POST', `/v1/conversations/${convId}/messages`, {
    token: C.token, body: { client_msg_id: 'hg-c1', msg_type: 'text', content: '我也想进周口群' },
  });
  assert.equal(sendC.json.code, 40301);
  const membersC = await api(base, 'GET', `/v1/hometown-groups/${convId}/members`, { token: C.token });
  assert.equal(membersC.json.code, 40301);

  // 成员列表：群主标记正确，非好友成员真名按渐显规则掩码
  const members = await api(base, 'GET', `/v1/hometown-groups/${convId}/members`, { token: A.token });
  assert.equal(members.json.code, 0);
  assert.equal(members.json.data.items.length, 2);
  assert.equal(members.json.data.owner_id, A.userId);
  assert.equal(members.json.data.items.find((i) => i.user_id === A.userId).is_owner, true);
  const viewOfB = members.json.data.items.find((i) => i.user_id === B.userId);
  assert.notEqual(viewOfB.real_name, '林小芳', '非好友成员真名应按渐显规则掩码');

  // 群公告：非群主被拒；超长被拒；群主可改
  const annB = await api(base, 'PUT', `/v1/hometown-groups/${convId}/announcement`, {
    token: B.token, body: { announcement: '本周六聚会' },
  });
  assert.equal(annB.json.code, 40301);
  const annLong = await api(base, 'PUT', `/v1/hometown-groups/${convId}/announcement`, {
    token: A.token, body: { announcement: '长'.repeat(201) },
  });
  assert.equal(annLong.json.code, 40001);
  const annA = await api(base, 'PUT', `/v1/hometown-groups/${convId}/announcement`, {
    token: A.token, body: { announcement: '春节拼车接龙' },
  });
  assert.equal(annA.json.code, 0);
  const mineA2 = await api(base, 'GET', '/v1/hometown-groups/mine', { token: A.token });
  assert.equal(mineA2.json.data.items[0].group.announcement, '春节拼车接龙');

  // 群主 A 退群 → 群主顺延给最早加入者 B；群与消息历史保留
  const leaveA = await api(base, 'POST', `/v1/hometown-groups/${convId}/leave`, { token: A.token });
  assert.equal(leaveA.json.code, 0);
  const ownerRow = db.prepare('SELECT created_by FROM hometown_groups WHERE conv_id=?').get(convId);
  assert.equal(ownerRow.created_by, B.userId, '群主顺延给最早加入者');
  const membersB = await api(base, 'GET', `/v1/hometown-groups/${convId}/members`, { token: B.token });
  assert.equal(membersB.json.data.owner_id, B.userId);
  const msgsB2 = await api(base, 'GET', `/v1/conversations/${convId}/messages`, { token: B.token });
  assert.ok(msgsB2.json.data.items.some((m) => m.msg_id === m1.json.data.msg_id), '退群后消息历史保留');
  // 退群后 A 发言被拒；新群主 B 可改公告
  const sendA2 = await api(base, 'POST', `/v1/conversations/${convId}/messages`, {
    token: A.token, body: { client_msg_id: 'hg-a2', msg_type: 'text', content: '我还在吗' },
  });
  assert.equal(sendA2.json.code, 40301, '退群后发言被拒');
  const annB2 = await api(base, 'PUT', `/v1/hometown-groups/${convId}/announcement`, {
    token: B.token, body: { announcement: '新群主上任' },
  });
  assert.equal(annB2.json.code, 0);

  // B 退群 → 群空：created_by 置 NULL；A 重新 join 补位为群主
  const leaveB = await api(base, 'POST', `/v1/hometown-groups/${convId}/leave`, { token: B.token });
  assert.equal(leaveB.json.code, 0);
  const ownerRow2 = db.prepare('SELECT created_by FROM hometown_groups WHERE conv_id=?').get(convId);
  assert.equal(ownerRow2.created_by, null, '空群时 created_by 置 NULL，待下位 join 者补位');
  const rejoinA = await api(base, 'POST', '/v1/hometown-groups/join', { token: A.token });
  assert.equal(rejoinA.json.code, 0);
  assert.equal(rejoinA.json.data.conv_id, convId);
  assert.equal(rejoinA.json.data.created, false, '群未销毁，重 join 不新建');
  const ownerRow3 = db.prepare('SELECT created_by FROM hometown_groups WHERE conv_id=?').get(convId);
  assert.equal(ownerRow3.created_by, A.userId, '空群后 join 者补位为群主');
});
