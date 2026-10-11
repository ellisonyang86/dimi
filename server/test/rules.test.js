import { test } from 'node:test';
import assert from 'node:assert/strict';
import { startTestServer, api, registerUser, addDemoClassEducation } from './helpers.js';

// 检索锚点强制（§5.2.5）与翻页深度频控（§6.2.3 / §22.4）
test('锚点强制：无锚点检索 → 40001；page>3 → 42901 need_captcha', async (t) => {
  const { base, close } = await startTestServer();
  t.after(close);
  const u = await registerUser(base, { phone: '13920000001', nickname: '检索者' });
  // 检索者需有自己的交集坐标（T0 用户按 §5.2.4 本就搜不到任何人）
  await addDemoClassEducation(base, u.token);
  await api(base, 'PUT', '/v1/users/me/hometown', { token: u.token, body: { type: 1, region_code: '411623102' } });

  // 纯姓名、无锚点 → 40001
  let r = await api(base, 'GET', '/v1/discover/search-user?name=李娟', { token: u.token });
  assert.equal(r.json.code, 40001);
  // 仅学校无届 → 40001
  r = await api(base, 'GET', '/v1/discover/search-user?school_id=1001&name=李娟', { token: u.token });
  assert.equal(r.json.code, 40001);
  // 区县级（非镇级）region 锚点 → 40001
  r = await api(base, 'GET', '/v1/discover/search-user?region_id=411623&name=李娟', { token: u.token });
  assert.equal(r.json.code, 40001);

  // 合法学校锚点 → 200，且命中种子班用户（姓名按渐显矩阵处理）
  r = await api(base, 'GET', '/v1/discover/search-user?school_id=1001&enroll_year=1996&name=李娟', { token: u.token });
  assert.equal(r.json.code, 0);
  assert.ok(r.json.data.items.length >= 1);
  assert.notEqual(r.json.data.items[0].real_name, '李娟', '陌生人检索结果不得返回完整真名');

  // 合法镇级锚点 → 200
  r = await api(base, 'GET', '/v1/discover/search-user?region_id=411623102', { token: u.token });
  assert.equal(r.json.code, 0);
  assert.ok(r.json.data.items.length >= 1);

  // page=4（>3）→ 42901 + need_captcha
  r = await api(base, 'GET', '/v1/discover/search-user?school_id=1001&enroll_year=1996&page=4', { token: u.token });
  assert.equal(r.status, 429);
  assert.equal(r.json.code, 42901);
  assert.equal(r.json.data.need_captcha, true);

  // 无鉴权 → 40101
  r = await api(base, 'GET', '/v1/discover/search-user?school_id=1001&enroll_year=1996');
  assert.equal(r.json.code, 40101);
});

test('未成年人注册门槛（V3.1 A3）：<14 拒绝；14–18 提示暂不支持', async (t) => {
  const { base, close } = await startTestServer();
  t.after(close);
  const year = new Date().getFullYear();
  const tryRegister = async (phone, birth_year) => {
    const sms = await api(base, 'POST', '/v1/auth/sms/send', { body: { phone } });
    return api(base, 'POST', '/v1/auth/register', {
      body: { phone, sms_code: sms.json.data.sms_code, nickname: '测试', birth_year },
    });
  };
  let r = await tryRegister('13930000001', year - 13);
  assert.equal(r.json.code, 40001);
  assert.ok(r.json.message.includes('14'));
  r = await tryRegister('13930000002', year - 16);
  assert.equal(r.json.code, 40001);
  assert.ok(r.json.message.includes('暂不支持'));
  r = await tryRegister('13930000003', year - 30);
  assert.equal(r.json.code, 0, '成年人应可正常注册');
});

test('公开接口：invites/{code} 免鉴权返回头像墙；管理接口 X-Admin-Token 鉴权', async (t) => {
  const { base, close } = await startTestServer();
  t.after(close);

  // 免鉴权：不带 token 也应返回（契约对齐 h5/index.html）
  let r = await api(base, 'GET', '/v1/public/invites/CG2X96');
  assert.equal(r.json.code, 0);
  const d = r.json.data;
  assert.ok(d.unit_name.includes('城关镇第二小学'));
  assert.ok(d.unit_name.includes('1996'));
  assert.equal(d.lit, 10, '10 位 demo 用户已点亮');
  assert.equal(d.target, 45, '45 人名册');
  assert.equal(d.avatars.length, 10);
  assert.ok(d.avatars[0].nickname);
  assert.ok(d.avatars[0].avatar_color?.startsWith('#'));
  assert.ok(d.avatars.every((w) => w.masked_name.includes('*')), '头像墙姓名必须掩码');
  assert.ok(d.inviter?.nickname, '应返回邀请人昵称');
  assert.ok(d.slogan);
  r = await api(base, 'GET', '/v1/public/invites/NOPE99');
  assert.equal(r.json.code, 41001);

  // 管理接口：无 token → 40101；正确 token → 密度数据（契约对齐 admin/index.html）
  r = await api(base, 'GET', '/admin-api/density/summary');
  assert.equal(r.json.code, 40101);
  r = await api(base, 'GET', '/admin-api/density/summary', { headers: { 'X-Admin-Token': 'test-admin-token' } });
  assert.equal(r.json.code, 0);
  const s = r.json.data;
  assert.equal(s.total_users, 10);
  assert.equal(s.total_units, 3, '2 个班级单元 + 1 个镇单元');
  assert.ok(typeof s.qualified_units === 'number' && typeof s.qualified_rate === 'number');

  r = await api(base, 'GET', '/admin-api/density/units?level=class', { headers: { 'X-Admin-Token': 'test-admin-token' } });
  assert.equal(r.json.code, 0);
  assert.ok(Array.isArray(r.json.data), 'units 应直接返回数组');
  const cls = r.json.data.find((i) => i.school_id === 1001 && i.class_norm === '6-2');
  assert.equal(cls.level, 'class');
  assert.ok(cls.unit_name.includes('城关镇第二小学'));
  assert.equal(cls.registered, 10);
  assert.equal(cls.target, 45);
  assert.equal(cls.retention_7d, 0.8, '10 名注册满 7 天用户中 8 名近 7 天活跃');
  assert.equal(cls.qualified, false, '注册 <15 未达标');

  r = await api(base, 'GET', '/admin-api/density/units?level=town', { headers: { 'X-Admin-Token': 'test-admin-token' } });
  const town = r.json.data.find((i) => i.region_code === '411623102');
  assert.equal(town.level, 'town');
  assert.equal(town.registered, 10);
  assert.equal(town.target, 200);
});
