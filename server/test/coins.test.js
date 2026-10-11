import { test } from 'node:test';
import assert from 'node:assert/strict';
import { startTestServer, api, registerUser, addDemoClassEducation, befriend } from './helpers.js';
import { refundExpiredRedPackets } from '../src/janitor.js';

// P0 纯赠送体系（《DIMI围城_虚拟币与打赏体系设计_V1.md》§1.3）：
// 任务赠送幂等 / 打赏全流程与防透支 / 私聊红包全流程与幂等键 / 群红包拼手气与灰度门 / 24h 未领退回

async function wallet(base, token) {
  const r = await api(base, 'GET', '/v1/wallet', { token });
  assert.equal(r.json.code, 0);
  return r.json.data;
}

test('任务赠送：每日打卡/完善经历/首条动态/添加好友，同一成就只发一次', async (t) => {
  const { base, close } = await startTestServer();
  t.after(close);
  const A = await registerUser(base, { phone: '13930000001', nickname: '阿明', gender: 1, real_name: '王明' });
  const B = await registerUser(base, { phone: '13930000002', nickname: '小芳', gender: 2, real_name: '林小芳' });

  // 初始为 0
  assert.equal((await wallet(base, A.token)).balance, 0);

  // 每日打卡 +5，当日重复打卡幂等
  const c1 = await api(base, 'POST', '/v1/wallet/checkin', { token: A.token });
  assert.equal(c1.json.code, 0);
  assert.deepEqual([c1.json.data.granted, c1.json.data.amount, c1.json.data.balance], [true, 5, 5]);
  const c2 = await api(base, 'POST', '/v1/wallet/checkin', { token: A.token });
  assert.deepEqual([c2.json.data.granted, c2.json.data.balance], [false, 5], '当日重复打卡不再发币');

  // 完善首条教育经历 +10（第二段经历不再发）
  await addDemoClassEducation(base, A.token);
  assert.equal((await wallet(base, A.token)).balance, 15);
  const edu2 = await api(base, 'POST', '/v1/users/me/educations', {
    token: A.token, body: { stage: 'PRIMARY', school_id: 1001, enroll_year: 1997, class_name: '一年1班' },
  });
  assert.equal(edu2.json.code, 0);
  assert.equal((await wallet(base, A.token)).balance, 15, 'edu_complete 为一次性成就');

  // 发布首条动态 +10（第二条不再发）
  const m1 = await api(base, 'POST', '/v1/moments', { token: A.token, body: { content: '第一条动态' } });
  assert.equal(m1.json.code, 0);
  assert.equal((await wallet(base, A.token)).balance, 25);
  await api(base, 'POST', '/v1/moments', { token: A.token, body: { content: '第二条动态' } });
  assert.equal((await wallet(base, A.token)).balance, 25, 'first_moment 为一次性成就');

  // 成功添加好友：申请人 +30（每目标一次），被申请人不发
  await befriend(base, A, B);
  assert.equal((await wallet(base, A.token)).balance, 55);
  assert.equal((await wallet(base, B.token)).balance, 0, 'friend_accept 只发给申请人');

  // 任务清单 done 标记
  const w = await wallet(base, A.token);
  const doneOf = (code) => w.tasks.find((x) => x.code === code)?.done;
  assert.equal(doneOf('daily_login'), true);
  assert.equal(doneOf('edu_complete'), true);
  assert.equal(doneOf('first_moment'), true);
  assert.equal(w.today_checked_in, true);

  // 流水可查且与余额一致
  const txns = await api(base, 'GET', '/v1/wallet/transactions', { token: A.token });
  assert.equal(txns.json.code, 0);
  const sum = txns.json.data.items.reduce((s, x) => s + (x.direction === 'in' ? x.amount : -x.amount), 0);
  assert.equal(sum, 55);
  assert.equal(txns.json.data.items[0].balance_after, 55, 'balance_after 为入账后余额');
});

test('动态打赏：全流程 / 面额白名单 / 防透支 / 非好友不可打赏', async (t) => {
  const { base, close } = await startTestServer();
  t.after(close);
  const A = await registerUser(base, { phone: '13930000011', nickname: '阿明', gender: 1 });
  const B = await registerUser(base, { phone: '13930000012', nickname: '小芳', gender: 2 });
  const C = await registerUser(base, { phone: '13930000013', nickname: '路人', gender: 1 });
  await befriend(base, A, B); // A +30
  await api(base, 'POST', '/v1/wallet/checkin', { token: A.token }); // A +5 = 35

  const mb = await api(base, 'POST', '/v1/moments', { token: B.token, body: { content: '母校的老槐树' } });
  const momentId = mb.json.data.moment_id;

  // 非好友 C：看不到动态（陌生人十条默认关）→ 打赏被拒
  const giftC = await api(base, 'POST', `/v1/moments/${momentId}/gifts`, { token: C.token, body: { coin_amount: 10 } });
  assert.equal(giftC.json.code, 40301);

  // 面额白名单：7 不在 [1,5,10,52,100] 内
  const bad = await api(base, 'POST', `/v1/moments/${momentId}/gifts`, { token: A.token, body: { coin_amount: 7 } });
  assert.equal(bad.json.code, 40001);

  // 正常打赏 10：A 35→25，B（发首条动态已得 +10）10→20
  const g1 = await api(base, 'POST', `/v1/moments/${momentId}/gifts`, { token: A.token, body: { coin_amount: 10 } });
  assert.equal(g1.json.code, 0);
  assert.equal(g1.json.data.balance, 25);
  assert.equal((await wallet(base, B.token)).balance, 20);

  // 打赏列表
  const list = await api(base, 'GET', `/v1/moments/${momentId}/gifts`, { token: B.token });
  assert.equal(list.json.data.total_count, 1);
  assert.equal(list.json.data.total_coins, 10);

  // 不能给自己的动态打赏
  const ma = await api(base, 'POST', '/v1/moments', { token: A.token, body: { content: '自己的动态' } });
  const self = await api(base, 'POST', `/v1/moments/${ma.json.data.moment_id}/gifts`, { token: A.token, body: { coin_amount: 1 } });
  assert.equal(self.json.code, 40001);

  // 防透支：A 余额 35（发动态再 +10），打赏 52 被拒
  const over = await api(base, 'POST', `/v1/moments/${momentId}/gifts`, { token: A.token, body: { coin_amount: 52 } });
  assert.equal(over.json.code, 40001);
  assert.match(over.json.message, /余额不足/);
  assert.equal((await wallet(base, A.token)).balance, 35, '透支失败不扣币');
  assert.equal((await wallet(base, B.token)).balance, 20, '透支失败对方不入账');
});

test('私聊红包：全流程 / Idempotency-Key 防重 / 余额不足拒发', async (t) => {
  const { base, close } = await startTestServer();
  t.after(close);
  const A = await registerUser(base, { phone: '13930000021', nickname: '阿明', gender: 1 });
  const B = await registerUser(base, { phone: '13930000022', nickname: '小芳', gender: 2 });
  const convId = await befriend(base, A, B); // A +30
  await api(base, 'POST', '/v1/wallet/checkin', { token: A.token }); // A = 35

  // 发红包（固定普通 1 份，10 豆）：A 35→25，红包消息卡入会话
  const send = await api(base, 'POST', '/v1/red-packets', {
    token: A.token,
    headers: { 'Idempotency-Key': 'rp-single-1' },
    body: { conv_id: convId, type: 'normal', total_amount: 10, count: 1, greeting: '老同学好' },
  });
  assert.equal(send.json.code, 0);
  assert.equal(send.json.data.balance, 25);
  const packetId = send.json.data.packet_id;
  assert.ok(packetId);
  const msgs = await api(base, 'GET', `/v1/conversations/${convId}/messages`, { token: B.token });
  const card = msgs.json.data.items.find((m) => m.msg_type === 'red_packet');
  assert.ok(card, '会话中应有红包消息卡');
  assert.ok(card.content.includes(packetId));

  // Idempotency-Key 重放：同一响应、不重复扣币、不产生第二个红包
  const replay = await api(base, 'POST', '/v1/red-packets', {
    token: A.token,
    headers: { 'Idempotency-Key': 'rp-single-1' },
    body: { conv_id: convId, type: 'normal', total_amount: 10, count: 1 },
  });
  assert.equal(replay.json.data.packet_id, packetId);
  assert.equal((await wallet(base, A.token)).balance, 25, '幂等重放不重复扣币');

  // 发出者不能领自己的私聊红包
  const claimA = await api(base, 'POST', `/v1/red-packets/${packetId}/claim`, { token: A.token });
  assert.equal(claimA.json.code, 40001);

  // B 领取：+10，红包 finished
  const claimB = await api(base, 'POST', `/v1/red-packets/${packetId}/claim`, { token: B.token });
  assert.equal(claimB.json.code, 0);
  assert.equal(claimB.json.data.amount, 10);
  assert.equal(claimB.json.data.packet.status, 'finished');
  assert.equal((await wallet(base, B.token)).balance, 10);
  const again = await api(base, 'POST', `/v1/red-packets/${packetId}/claim`, { token: B.token });
  assert.equal(again.json.code, 40001, '领完后再领被拒');

  // 红包详情含领取记录
  const detail = await api(base, 'GET', `/v1/red-packets/${packetId}`, { token: A.token });
  assert.equal(detail.json.data.claims.length, 1);
  assert.equal(detail.json.data.claimed_amount, 10);

  // 余额不足：A 余额 25，发 200 被拒且不扣币
  const over = await api(base, 'POST', '/v1/red-packets', {
    token: A.token, body: { conv_id: convId, type: 'normal', total_amount: 200, count: 1 },
  });
  assert.equal(over.json.code, 40001);
  assert.match(over.json.message, /余额不足/);
  assert.equal((await wallet(base, A.token)).balance, 25);
});

test('群红包：单元灰度门 / 拼手气分配守恒 / 24h 未领退回', async (t) => {
  const { base, db, close } = await startTestServer();
  t.after(close);
  const A = await registerUser(base, { phone: '13930000031', nickname: '阿明', gender: 1, real_name: '王明' });
  const B = await registerUser(base, { phone: '13930000032', nickname: '小芳', gender: 2, real_name: '林小芳' });
  const C = await registerUser(base, { phone: '13930000033', nickname: '铁柱', gender: 1, real_name: '赵铁柱' });
  for (const u of [A, B, C]) await addDemoClassEducation(base, u.token); // 各 +10
  for (const u of [A, B, C]) await api(base, 'POST', '/v1/wallet/checkin', { token: u.token }); // 各 +5
  await befriend(base, A, B); // A 再 +30 = 45（群红包需要足够余额）
  const join = await api(base, 'POST', '/v1/class-groups/join', {
    token: A.token, body: { school_id: 1001, enroll_year: 1996, class_name: '六年2班' },
  });
  const convId = join.json.data.conv_id;
  for (const u of [B, C]) {
    await api(base, 'POST', '/v1/class-groups/join', {
      token: u.token, body: { school_id: 1001, enroll_year: 1996, class_name: '六年2班' },
    });
  }

  // 灰度门：单元注册 3 < 15，群红包暂不可用
  const gated = await api(base, 'POST', '/v1/red-packets', {
    token: A.token, body: { conv_id: convId, type: 'luck', total_amount: 30, count: 3 },
  });
  assert.equal(gated.json.code, 40301);
  // 补齐到 15 人点亮（直接落库占位经历）
  for (let i = 1; i <= 12; i++) {
    db.prepare(
      "INSERT INTO education_experiences(user_id,stage,school_id,enroll_year,class_name_norm,created_at) VALUES(?,'PRIMARY',1001,1996,'6-2',?)"
    ).run(9000 + i, new Date().toISOString());
  }

  // 拼手气红包 30/3：A 15→ -30；三人领取金额守恒且各 ≥1
  const send = await api(base, 'POST', '/v1/red-packets', {
    token: A.token, body: { conv_id: convId, type: 'luck', total_amount: 30, count: 3, greeting: '欢迎新同学' },
  });
  assert.equal(send.json.code, 0);
  const packetId = send.json.data.packet_id;
  const amounts = [];
  for (const u of [A, B, C]) {
    const r = await api(base, 'POST', `/v1/red-packets/${packetId}/claim`, { token: u.token });
    assert.equal(r.json.code, 0);
    amounts.push(r.json.data.amount);
  }
  assert.ok(amounts.every((a) => a >= 1), '每份至少 1 觅豆');
  assert.equal(amounts.reduce((s, a) => s + a, 0), 30, '拼手气分配总额守恒');
  const detail = await api(base, 'GET', `/v1/red-packets/${packetId}`, { token: A.token });
  assert.equal(detail.json.data.status, 'finished');
  assert.equal(detail.json.data.claims.filter((c) => c.is_best).length, 1, '领完后结算手气最佳');
  const sumA = (await wallet(base, A.token)).balance;
  assert.equal(sumA, 45 - 30 + amounts[0]);

  // 普通群红包 10/2（单份 5）：B 领一份；篡改过期时间后走 janitor 扫描退回剩余 5
  const send2 = await api(base, 'POST', '/v1/red-packets', {
    token: A.token, body: { conv_id: convId, type: 'normal', total_amount: 10, count: 2 },
  });
  assert.equal(send2.json.code, 0);
  const p2 = send2.json.data.packet_id;
  const claimB = await api(base, 'POST', `/v1/red-packets/${p2}/claim`, { token: B.token });
  assert.equal(claimB.json.data.amount, 5);
  db.prepare('UPDATE red_packets SET expire_at=? WHERE packet_id=?').run(new Date(0).toISOString(), p2);
  const refunded = refundExpiredRedPackets(db);
  assert.equal(refunded, 1);
  const detail2 = await api(base, 'GET', `/v1/red-packets/${p2}`, { token: A.token });
  assert.equal(detail2.json.data.status, 'expired');
  assert.equal((await wallet(base, A.token)).balance, sumA - 10 + 5, '未领部分原路退回币账户');
  const late = await api(base, 'POST', `/v1/red-packets/${p2}/claim`, { token: C.token });
  assert.equal(late.json.code, 40001, '过期后不可再领');
  // 重复扫描幂等：不再退回
  assert.equal(refundExpiredRedPackets(db), 0);
  assert.equal((await wallet(base, A.token)).balance, sumA - 5);

  // 领取路径惰性过期：不发扫描也能即时结算
  const send3 = await api(base, 'POST', '/v1/red-packets', {
    token: A.token, body: { conv_id: convId, type: 'normal', total_amount: 6, count: 2 },
  });
  assert.equal(send3.json.code, 0);
  const p3 = send3.json.data.packet_id;
  const balBefore = (await wallet(base, A.token)).balance; // 已扣 6 豆
  db.prepare('UPDATE red_packets SET expire_at=? WHERE packet_id=?').run(new Date(0).toISOString(), p3);
  const lazy = await api(base, 'POST', `/v1/red-packets/${p3}/claim`, { token: B.token });
  assert.equal(lazy.json.code, 40001);
  assert.equal((await wallet(base, A.token)).balance, balBefore + 6, '惰性过期全额退回');
  // Equal shares must still have exactly one best claim (earliest wins ties).
  const tied = await api(base, 'POST', '/v1/red-packets', {
    token: A.token, body: { conv_id: convId, type: 'normal', total_amount: 2, count: 2 },
  });
  assert.equal(tied.json.code, 0);
  const tiedId = tied.json.data.packet_id;
  for (const u of [B, C]) {
    assert.equal((await api(base, 'POST', '/v1/red-packets/' + tiedId + '/claim', { token: u.token })).json.code, 0);
  }
  const tiedDetail = await api(base, 'GET', '/v1/red-packets/' + tiedId, { token: A.token });
  assert.equal(tiedDetail.json.data.claims.filter(c => c.is_best).length, 1);
  assert.equal(tiedDetail.json.data.claims[0].is_best, true);
});
