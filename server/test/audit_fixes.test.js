import { test } from 'node:test';
import assert from 'node:assert/strict';
import { startTestServer, api, registerUser, addDemoClassEducation, befriend } from './helpers.js';
import { containsContactInfo } from '../src/engine/index.js';
import { q1, run } from '../src/repo.js';
import { now } from '../src/util.js';

// 审计修复回归：P0-1 主 feed 好友门 / P0-2 同学圈同校同届 / P0-3 内容安全正则
// P1-4 通用幂等 / P1-5 滑块验证码全流程

// ---------- P0-3 内容安全：拦截用例与误伤用例 ----------
test('containsContactInfo：联系方式拦截，正常英文/数字串不误伤', () => {
  const blocked = [
    '加我微信13800001111',
    '加我V信详聊',
    '微信: abc123456',
    'QQ 123456789',
    '联系我13812345678',
    'q q：7654321',
    'vx: dimi_2024',
    '威信 abcdef8',
  ];
  for (const s of blocked) assert.equal(containsContactInfo(s), true, `应拦截: ${s}`);
  const allowed = [
    'Saturday morning, feeling great!',
    '20240601聚会见',
    'classroom english',
    '聚会定在六月一号，老地方见',
    '我们的 QQ 群解散了', // 带 QQ 字样但无号码
  ];
  for (const s of allowed) assert.equal(containsContactInfo(s), false, `应放行: ${s}`);
});

// ---------- P0-1 主 feed 只含「自己 + 好友」；陌生人十条只在相册页生效 ----------
test('feed 不含陌生人动态（stranger_moments_10 开启也不进主 feed）；相册页仍可见陌生人十条', async (t) => {
  const { base, close } = await startTestServer();
  t.after(close);
  const stranger = await registerUser(base, { phone: '13950000001', nickname: '路人甲' });
  const viewer = await registerUser(base, { phone: '13950000002', nickname: '看客' });
  // 陌生人开启「允许陌生人看十条」
  let r = await api(base, 'PUT', '/v1/privacy/settings', { token: stranger.token, body: { stranger_moments_10: true } });
  assert.equal(r.json.code, 0);
  r = await api(base, 'POST', '/v1/moments', { token: stranger.token, body: { content_type: 'text', content: '路人的公开动态', visibility: 'public' } });
  assert.equal(r.json.code, 0);
  const momentId = r.json.data.moment_id;

  // 主 feed：不含陌生人动态
  const feed = await api(base, 'GET', '/v1/moments/feed', { token: viewer.token });
  assert.equal(feed.json.code, 0);
  assert.ok(!feed.json.data.items.some((m) => m.moment_id === momentId), '陌生人动态不得进入主 feed');

  // 相册页：陌生人十条逻辑保持不变（可见该公开动态）
  const album = await api(base, 'GET', `/v1/users/${stranger.userId}/moments`, { token: viewer.token });
  assert.equal(album.json.code, 0);
  assert.ok(album.json.data.items.some((m) => m.moment_id === momentId), '相册页陌生人十条应可见');
  assert.ok(album.json.data.items.length <= 10);

  // 自己的动态仍进自己的 feed
  const own = await api(base, 'POST', '/v1/moments', { token: viewer.token, body: { content_type: 'text', content: '我自己的动态', visibility: 'public' } });
  const feed2 = await api(base, 'GET', '/v1/moments/feed', { token: viewer.token });
  assert.ok(feed2.json.data.items.some((m) => m.moment_id === own.json.data.moment_id), '自己的动态应在自己的 feed');
});

// ---------- P0-2 同学圈/老乡圈：按作者关系聚合（同窗/同乡的 classmates|fellows + public 均可见，无需好友）；主时间线好友门不变 ----------
test('classmates/fellows 可见范围 = 同窗/同乡即可见（无需好友）；主时间线仍仅好友', async (t) => {
  const { base, close } = await startTestServer();
  t.after(close);
  const A = await registerUser(base, { phone: '13950000011', nickname: '同届生' });
  const B = await registerUser(base, { phone: '13950000012', nickname: '同班友' });
  const C = await registerUser(base, { phone: '13950000013', nickname: '差届友' });
  const D = await registerUser(base, { phone: '13950000014', nickname: '同窗陌路人' });
  const E = await registerUser(base, { phone: '13950000015', nickname: '老乡陌路人' });
  await addDemoClassEducation(base, A.token); // 城关镇第二小学 1996
  await addDemoClassEducation(base, B.token); // 同校 1996
  await addDemoClassEducation(base, D.token); // 同校 1996（不与 A 加好友）
  await api(base, 'POST', '/v1/users/me/educations', {
    token: C.token,
    body: { stage: 'PRIMARY', school_id: 1001, enroll_year: 1997, class_name: '六年1班' },
  }); // 同校但 1997（差一届）
  await befriend(base, A, B);
  await befriend(base, A, C);

  const pub = await api(base, 'POST', '/v1/moments', { token: A.token, body: { content_type: 'text', content: '公开动态', visibility: 'public' } });
  const cls = await api(base, 'POST', '/v1/moments', { token: A.token, body: { content_type: 'text', content: '孩子成绩照只发同学圈', visibility: 'classmates' } });
  assert.equal(cls.json.code, 0);
  const pubId = pub.json.data.moment_id, clsId = cls.json.data.moment_id;

  // B（好友，同校同届）：主时间线可见 classmates（好友场景保持不变）
  const feedB = await api(base, 'GET', '/v1/moments/feed', { token: B.token });
  const idsB = feedB.json.data.items.map((m) => m.moment_id);
  assert.ok(idsB.includes(pubId) && idsB.includes(clsId), '同届好友应可见 classmates 动态');

  // C（好友，同校差一届）：可见 public，不可见 classmates（主时间线与聚合页均不可见）
  const feedC = await api(base, 'GET', '/v1/moments/feed', { token: C.token });
  const idsC = feedC.json.data.items.map((m) => m.moment_id);
  assert.ok(idsC.includes(pubId), '差届好友仍可见 public 动态');
  assert.ok(!idsC.includes(clsId), '差一届不得可见 classmates 动态');
  const aggC = await api(base, 'GET', '/v1/moments/feed?visibility=classmates', { token: C.token });
  assert.ok(!aggC.json.data.items.some((m) => m.moment_id === clsId), '差一届在同学圈聚合页也不可见');
  const detailC = await api(base, 'GET', `/v1/moments/${clsId}`, { token: C.token });
  assert.equal(detailC.json.code, 40301, '差届好友直接访问详情应 40301');

  // D（非好友，同校同届）：同学圈聚合页可见 A 的 classmates 与 public 动态（圈页按作者关系聚合，
  // public 的陌生人十条门禁在圈页语境不适用）
  const aggD = await api(base, 'GET', '/v1/moments/feed?visibility=classmates', { token: D.token });
  assert.equal(aggD.json.code, 0);
  assert.ok(aggD.json.data.items.some((m) => m.moment_id === clsId), '非好友同校同届在同学圈聚合页应可见 classmates 动态');
  assert.ok(aggD.json.data.items.some((m) => m.moment_id === pubId), '同窗的 public 动态也应进同学圈聚合页');
  // 圈页可见则详情可见：D 可直访 A 的 public 动态详情
  const detailD = await api(base, 'GET', `/v1/moments/${pubId}`, { token: D.token });
  assert.equal(detailD.json.code, 0, '同窗应可直访 public 动态详情');
  // 但这些动态不进 D 的主时间线（好友门不变）
  const feedD = await api(base, 'GET', '/v1/moments/feed', { token: D.token });
  assert.ok(!feedD.json.data.items.some((m) => m.moment_id === clsId), '非好友动态不得进主时间线');
  assert.ok(!feedD.json.data.items.some((m) => m.moment_id === pubId), '非好友 public 动态同样不得进主时间线');

  // A 自己的同学圈：自己的 classmates 与 public 动态均出现（自己恒满足关系）
  const aggA = await api(base, 'GET', '/v1/moments/feed?visibility=classmates', { token: A.token });
  assert.ok(aggA.json.data.items.some((m) => m.moment_id === clsId), '自己的 classmates 动态应在自己的同学圈');
  assert.ok(aggA.json.data.items.some((m) => m.moment_id === pubId), '自己的 public 动态也应在自己的同学圈');

  // F（与 A 无任何交集：无教育经历、无家乡）：同学圈看不到 A 的任何动态
  const F = await registerUser(base, { phone: '13950000016', nickname: '纯路人' });
  const aggF = await api(base, 'GET', '/v1/moments/feed?visibility=classmates', { token: F.token });
  assert.equal(aggF.json.code, 0);
  assert.ok(![pubId, clsId].some((id) => aggF.json.data.items.some((m) => m.moment_id === id)),
    '无任何交集的用户在同学圈不得看到 A 的动态');
  const detailF = await api(base, 'GET', `/v1/moments/${pubId}`, { token: F.token });
  assert.equal(detailF.json.code, 40301, '无交集陌生人直访 public 动态详情仍被陌生人十条门禁拦截');

  // fellows：A 与 E（非好友）家乡同市（周口 4116），老乡圈聚合页可见 fellows 与 public 动态
  for (const u of [A, E]) {
    const h = await api(base, 'PUT', '/v1/users/me/hometown', {
      token: u.token,
      body: { type: 1, region_code: '411623102' }, // 河南省周口市商水县城关乡
    });
    assert.equal(h.json.code, 0);
  }
  const fel = await api(base, 'POST', '/v1/moments', { token: A.token, body: { content_type: 'text', content: '只发老乡圈', visibility: 'fellows' } });
  assert.equal(fel.json.code, 0);
  const felId = fel.json.data.moment_id;
  const aggE = await api(base, 'GET', '/v1/moments/feed?visibility=fellows', { token: E.token });
  assert.equal(aggE.json.code, 0);
  assert.ok(aggE.json.data.items.some((m) => m.moment_id === felId), '非好友同乡在老乡圈聚合页应可见 fellows 动态');
  assert.ok(aggE.json.data.items.some((m) => m.moment_id === pubId), '同乡的 public 动态也应进老乡圈聚合页');
  const feedE = await api(base, 'GET', '/v1/moments/feed', { token: E.token });
  assert.ok(!feedE.json.data.items.some((m) => m.moment_id === felId), '非好友 fellows 动态不得进主时间线');
  // D（非同乡，家乡未设置）在老乡圈聚合页不可见
  const aggD2 = await api(base, 'GET', '/v1/moments/feed?visibility=fellows', { token: D.token });
  assert.ok(!aggD2.json.data.items.some((m) => m.moment_id === felId), '非同乡不得可见 fellows 动态');
  assert.ok(!aggD2.json.data.items.some((m) => m.moment_id === pubId), '非同乡也不得在老乡圈看到 public 动态');
});

// ---------- P1-4 通用幂等：重放返回缓存响应，不产生重复写入 ----------
test('通用幂等：POST /v1/moments 带 Idempotency-Key 重放返回同一 moment_id 且不重复落库', async (t) => {
  const { base, close } = await startTestServer();
  t.after(close);
  const u = await registerUser(base, { phone: '13950000021', nickname: '幂等君' });
  const key = 'idem-moment-001';
  const body = { content_type: 'text', content: '幂等动态', visibility: 'public' };
  const r1 = await api(base, 'POST', '/v1/moments', { token: u.token, body, headers: { 'Idempotency-Key': key } });
  assert.equal(r1.json.code, 0);
  const r2 = await api(base, 'POST', '/v1/moments', { token: u.token, body, headers: { 'Idempotency-Key': key } });
  assert.equal(r2.json.code, 0);
  assert.equal(r2.json.data.moment_id, r1.json.data.moment_id, '重放应返回相同 moment_id');
  assert.equal(r2.json.message, 'ok(idempotent)');

  const feed = await api(base, 'GET', '/v1/moments/feed', { token: u.token });
  const mine = feed.json.data.items.filter((m) => m.content === '幂等动态');
  assert.equal(mine.length, 1, '重放不得产生重复动态');

  // 不同用户使用同 key 互不影响（键按用户隔离）
  const v = await registerUser(base, { phone: '13950000022', nickname: '幂等乙' });
  const r3 = await api(base, 'POST', '/v1/moments', { token: v.token, body: { content_type: 'text', content: '另一人的动态', visibility: 'public' }, headers: { 'Idempotency-Key': key } });
  assert.equal(r3.json.code, 0);
  assert.notEqual(r3.json.data.moment_id, r1.json.data.moment_id);
});

// ---------- P1-5 滑块验证码：签发 → 失败作废 → 成功签发 token → 消费一次性 ----------
test('captcha：挑战一次性 + captcha_token 一次性放行 42901 场景；dev_bypass 开发模式可用', async (t) => {
  const { base, db, close } = await startTestServer();
  t.after(close);
  const u = await registerUser(base, { phone: '13950000031', nickname: '验证者' });
  await addDemoClassEducation(base, u.token);

  // 签发挑战
  let r = await api(base, 'GET', '/v1/captcha/slider');
  assert.equal(r.json.code, 0);
  const { captcha_id, width, height, notch_y, bg_seed, expires_in } = r.json.data;
  assert.equal(width, 280);
  assert.equal(height, 160);
  assert.ok(typeof notch_y === 'number' && bg_seed && expires_in === 300);
  const targetX = q1(db, 'SELECT target_x FROM captcha_challenges WHERE captcha_id=?', captcha_id).target_x;
  assert.ok(targetX >= 40 && targetX <= 230, 'target_x 应在 40–230');

  // 失败校验 → 40001；且挑战无论成败标记已用
  r = await api(base, 'POST', '/v1/captcha/verify', { body: { captcha_id, x: targetX + 50 } });
  assert.equal(r.json.code, 40001);
  r = await api(base, 'POST', '/v1/captcha/verify', { body: { captcha_id, x: targetX } });
  assert.equal(r.json.code, 40001, '已用挑战不得二次校验成功');

  // 新挑战 + 正确 x（含容差边界 ±3）→ captcha_token
  const ch2 = await api(base, 'GET', '/v1/captcha/slider');
  const id2 = ch2.json.data.captcha_id;
  const tx2 = q1(db, 'SELECT target_x FROM captcha_challenges WHERE captcha_id=?', id2).target_x;
  r = await api(base, 'POST', '/v1/captcha/verify', { body: { captcha_id: id2, x: tx2 + 3 } });
  assert.equal(r.json.code, 0, '容差边界 ±3 应通过');
  const captchaToken = r.json.data.captcha_token;
  assert.ok(captchaToken);

  // 触发 42901（翻页过深）→ 携带 token 放行 → 同 token 复用被拒
  const search = (extra) => api(base, 'GET', `/v1/discover/search-user?school_id=1001&enroll_year=1996&page=4${extra}`, { token: u.token });
  r = await search('');
  assert.equal(r.json.code, 42901);
  assert.equal(r.json.data.need_captcha, true);
  r = await search(`&captcha_token=${captchaToken}`);
  assert.equal(r.json.code, 0, '有效 captcha_token 应放行翻页过深');
  r = await search(`&captcha_token=${captchaToken}`);
  assert.equal(r.json.code, 42901, 'captcha_token 一次性，用后作废');

  // 伪造 token 无效
  r = await search('&captcha_token=forged-token');
  assert.equal(r.json.code, 42901);

  // dev 模式接受 dev_bypass
  r = await search('&captcha_token=dev_bypass');
  assert.equal(r.json.code, 0, 'DIMI_SMS_DEV=true 时 dev_bypass 应放行');
});

// ---------- 契约修复1：PUT /users/me 头像字段 avatar_url ----------
test('头像字段：avatar_url（/media/ 前缀校验）写入 avatar_url；旧字段 avatar_media_id 兼容', async (t) => {
  const { base, close } = await startTestServer();
  t.after(close);
  const u = await registerUser(base, { phone: '13960000001', nickname: '头像君' });

  let r = await api(base, 'PUT', '/v1/users/me', { token: u.token, body: { avatar_url: '/media/avatar-ab12cd.jpg' } });
  assert.equal(r.json.code, 0);
  let me = await api(base, 'GET', '/v1/users/me', { token: u.token });
  assert.equal(me.json.data.avatar_url, '/media/avatar-ab12cd.jpg');

  // 非 /media/ 前缀 → 40001
  r = await api(base, 'PUT', '/v1/users/me', { token: u.token, body: { avatar_url: 'https://evil.com/a.jpg' } });
  assert.equal(r.json.code, 40001);
  r = await api(base, 'PUT', '/v1/users/me', { token: u.token, body: { avatar_url: '/etc/passwd' } });
  assert.equal(r.json.code, 40001);

  // 旧字段 avatar_media_id 兼容（按 url 同样校验）
  r = await api(base, 'PUT', '/v1/users/me', { token: u.token, body: { avatar_media_id: '/media/legacy-99.png' } });
  assert.equal(r.json.code, 0);
  me = await api(base, 'GET', '/v1/users/me', { token: u.token });
  assert.equal(me.json.data.avatar_url, '/media/legacy-99.png');
});

// ---------- 契约修复2：POST /v1/auth/password 设置/修改登录密码 ----------
test('设置/修改登录密码：短信二次验证 + ≥8 位 + 改密后新旧密码切换', async (t) => {
  const { base, close } = await startTestServer();
  t.after(close);
  const phone = '13960000011';
  const u = await registerUser(base, { phone, nickname: '密码君' }); // 注册时未设密码

  // 密码过短 → 40001（注册已发过一条短信，60s 间隔内第二条触发 42901，用 dev_bypass 放行）
  let r = await api(base, 'POST', '/v1/auth/password', { token: u.token, body: { new_password: 'short1', sms_code: '000000' } });
  assert.equal(r.json.code, 40001);
  assert.ok(r.json.message.includes('8'));

  // 取第二条短信验证码：60s 间隔触发 42901 need_captcha → dev_bypass 放行
  let sms = await api(base, 'POST', '/v1/auth/sms/send', { body: { phone } });
  assert.equal(sms.json.code, 42901, '60s 内重发应触发频控');
  assert.equal(sms.json.data.need_captcha, true);
  sms = await api(base, 'POST', '/v1/auth/sms/send', { body: { phone, captcha_token: 'dev_bypass' } });
  assert.equal(sms.json.code, 0, 'dev 模式 dev_bypass 应放行频控');
  const code1 = sms.json.data.sms_code;

  // 错误验证码 → 40001
  r = await api(base, 'POST', '/v1/auth/password', { token: u.token, body: { new_password: 'passw0rd123', sms_code: String(1000000 - Number(code1)).slice(0, 6) } });
  assert.equal(r.json.code, 40001);

  // 首次设置成功（changed=false），随后可用密码登录
  r = await api(base, 'POST', '/v1/auth/password', { token: u.token, body: { new_password: 'passw0rd123', sms_code: code1 } });
  assert.equal(r.json.code, 0);
  assert.equal(r.json.data.changed, false);
  r = await api(base, 'POST', '/v1/auth/login', { body: { grant_type: 'password', phone, password: 'passw0rd123' } });
  assert.equal(r.json.code, 0, '设置密码后应可密码登录');

  // 改密：再取一条验证码（dev_bypass 过频控），改密后旧密码失效、新密码可用
  sms = await api(base, 'POST', '/v1/auth/sms/send', { body: { phone, captcha_token: 'dev_bypass' } });
  assert.equal(sms.json.code, 0);
  r = await api(base, 'POST', '/v1/auth/password', { token: u.token, body: { new_password: 'newpass4567', sms_code: sms.json.data.sms_code } });
  assert.equal(r.json.code, 0);
  assert.equal(r.json.data.changed, true, '已有密码时应标记为改密');
  r = await api(base, 'POST', '/v1/auth/login', { body: { grant_type: 'password', phone, password: 'passw0rd123' } });
  assert.equal(r.json.code, 40001, '旧密码应失效');
  r = await api(base, 'POST', '/v1/auth/login', { body: { grant_type: 'password', phone, password: 'newpass4567' } });
  assert.equal(r.json.code, 0, '新密码应可用');

  // 未登录 → 40101
  r = await api(base, 'POST', '/v1/auth/password', { body: { new_password: 'whatever88', sms_code: '123456' } });
  assert.equal(r.json.code, 40101);
});

// ---------- 契约修复3：contact-viewers 仅近 30 天 ----------
test('contact-viewers：仅返回近 30 天的查看记录', async (t) => {
  const { base, db, close } = await startTestServer();
  t.after(close);
  const me = await registerUser(base, { phone: '13960000021', nickname: '被看者' });
  const v1 = await registerUser(base, { phone: '13960000022', nickname: '新看客' });
  const v2 = await registerUser(base, { phone: '13960000023', nickname: '旧看客' });

  // 直接落审计行：一条现在、一条 31 天前
  run(db, "INSERT INTO audit_logs(user_id,event,target_id,created_at) VALUES(?,?,?,?)",
    v1.userId, 'contact_view', me.userId, now());
  run(db, "INSERT INTO audit_logs(user_id,event,target_id,created_at) VALUES(?,?,?,?)",
    v2.userId, 'contact_view', me.userId, new Date(Date.now() - 31 * 86400 * 1000).toISOString());

  const r = await api(base, 'GET', '/v1/users/me/contact-viewers', { token: me.token });
  assert.equal(r.json.code, 0);
  const ids = r.json.data.items.map((i) => i.user_id);
  assert.ok(ids.includes(v1.userId), '近 30 天记录应返回');
  assert.ok(!ids.includes(v2.userId), '超过 30 天的记录应被过滤');
});

// ---------- 二次审计修复回归 ----------

// 高隐私分组门禁 ctx 透传：好友在高隐私分组时访问其动态返回 40301（此前 TypeError 必现 500）
test('高隐私分组：未解锁访问好友动态 40301（不再 500）；解锁后可见', async (t) => {
  const { base, close } = await startTestServer();
  t.after(close);
  const A = await registerUser(base, { phone: '13970000001', nickname: '分组主' });
  const B = await registerUser(base, { phone: '13970000002', nickname: '密友' });
  await befriend(base, A, B);
  // A 设隐私密码 → 建高隐私分组 → 把 B 移入
  let r = await api(base, 'PUT', '/v1/privacy/password', { token: A.token, body: { password: 'secret123' } });
  assert.equal(r.json.code, 0);
  r = await api(base, 'POST', '/v1/contact-groups', { token: A.token, body: { name: '密友组', privacy_level: 'high' } });
  assert.equal(r.json.code, 0);
  const groupId = r.json.data.group_id;
  r = await api(base, 'PUT', `/v1/friends/${B.userId}/group`, { token: A.token, body: { group_id: groupId } });
  assert.equal(r.json.code, 0);
  r = await api(base, 'POST', '/v1/moments', { token: B.token, body: { content_type: 'text', content: '密友的动态', visibility: 'public' } });
  const momentId = r.json.data.moment_id;

  // 未解锁：详情/点赞/评论均 40301（关键：不得 500）；相册页 40301 locked
  r = await api(base, 'GET', `/v1/moments/${momentId}`, { token: A.token });
  assert.equal(r.json.code, 40301, '未解锁访问高隐私分组好友动态应 40301 而非 500');
  r = await api(base, 'POST', `/v1/moments/${momentId}/likes`, { token: A.token });
  assert.equal(r.json.code, 40301);
  r = await api(base, 'POST', `/v1/moments/${momentId}/comments`, { token: A.token, body: { content: '在吗' } });
  assert.equal(r.json.code, 40301);
  r = await api(base, 'GET', `/v1/users/${B.userId}/moments`, { token: A.token });
  assert.equal(r.json.code, 40301);
  assert.equal(r.json.data.locked, true);
  // feed 正常返回（不 500），但不含被门禁的动态
  const feed = await api(base, 'GET', '/v1/moments/feed', { token: A.token });
  assert.equal(feed.json.code, 0);
  assert.ok(!feed.json.data.items.some((m) => m.moment_id === momentId));

  // 解锁后详情可见
  r = await api(base, 'POST', '/v1/privacy/groups/unlock', { token: A.token, body: { password: 'secret123' } });
  assert.equal(r.json.code, 0);
  const unlockToken = r.json.data.unlock_token;
  r = await api(base, 'GET', `/v1/moments/${momentId}`, { token: A.token, headers: { 'X-Group-Unlock': unlockToken } });
  assert.equal(r.json.code, 0, '解锁后应可见高隐私分组好友动态');
});

// 陌生人十条窗口：无交集陌生人详情/互动直访仅作者最新 10 条 public 可见；同窗放行保持现状
test('陌生人十条：详情直访按 moment_id 窗口限定最新 10 条 public 动态', async (t) => {
  const { base, close } = await startTestServer();
  t.after(close);
  const author = await registerUser(base, { phone: '13970000011', nickname: '作者' });
  const stranger = await registerUser(base, { phone: '13970000012', nickname: '纯陌生人' });
  let r = await api(base, 'PUT', '/v1/privacy/settings', { token: author.token, body: { stranger_moments_10: true } });
  assert.equal(r.json.code, 0);
  const ids = [];
  for (let i = 1; i <= 12; i++) {
    r = await api(base, 'POST', '/v1/moments', { token: author.token, body: { content_type: 'text', content: `公开动态 ${i}`, visibility: 'public' } });
    assert.equal(r.json.code, 0);
    ids.push(r.json.data.moment_id);
  }
  // 窗口 = 最新 10 条（ids[2..11]）；ids[0]、ids[1] 在窗口外
  for (const id of [ids[0], ids[1]]) {
    r = await api(base, 'GET', `/v1/moments/${id}`, { token: stranger.token });
    assert.equal(r.json.code, 40301, `窗口外历史动态 ${id} 直访应 40301`);
    r = await api(base, 'POST', `/v1/moments/${id}/likes`, { token: stranger.token });
    assert.equal(r.json.code, 40301, `窗口外历史动态 ${id} 点赞应 40301`);
  }
  r = await api(base, 'GET', `/v1/moments/${ids[2]}`, { token: stranger.token });
  assert.equal(r.json.code, 0, '窗口下界（第 10 新）应可见');
  r = await api(base, 'GET', `/v1/moments/${ids[11]}`, { token: stranger.token });
  assert.equal(r.json.code, 0, '最新一条应可见');
  // 相册页 slice(10) 逻辑不变：仍返回 10 条且为最新 10 条
  const album = await api(base, 'GET', `/v1/users/${author.userId}/moments`, { token: stranger.token });
  assert.equal(album.json.code, 0);
  assert.equal(album.json.data.items.length, 10);
  assert.ok(album.json.data.items.some((m) => m.moment_id === ids[11]));
  assert.ok(!album.json.data.items.some((m) => m.moment_id === ids[0]));
  // 同窗（非好友）放行保持现状：窗口外历史动态仍可见
  const classmate = await registerUser(base, { phone: '13970000013', nickname: '同窗' });
  await addDemoClassEducation(base, author.token);
  await addDemoClassEducation(base, classmate.token);
  r = await api(base, 'GET', `/v1/moments/${ids[0]}`, { token: classmate.token });
  assert.equal(r.json.code, 0, '同窗不受陌生人十条窗口限制（刻意保持现状）');
});

// 通用发消息口：仅服务端可发的 msg_type 拒绝（40001）；content ≤4000；单聊频控 30 条/60s
test('单聊：system/red_packet 等服务端类型 40001；超长 40001；30 条/60s 频控', async (t) => {
  const { base, close } = await startTestServer();
  t.after(close);
  const A = await registerUser(base, { phone: '13970000021', nickname: '聊主' });
  const B = await registerUser(base, { phone: '13970000022', nickname: '聊友' });
  const convId = await befriend(base, A, B);

  for (const mt of ['red_packet', 'system', 'ice_breaker', 'contact_card', 'location']) {
    const r = await api(base, 'POST', `/v1/conversations/${convId}/messages`, {
      token: A.token, body: { client_msg_id: `bad-${mt}`, msg_type: mt, content: 'x' },
    });
    assert.equal(r.json.code, 40001, `msg_type=${mt} 应被拒（仅服务端可发）`);
  }
  let r = await api(base, 'POST', `/v1/conversations/${convId}/messages`, {
    token: A.token, body: { client_msg_id: 'too-long', msg_type: 'text', content: '长'.repeat(4001) },
  });
  assert.equal(r.json.code, 40001, 'content 超过 4000 字应 40001');

  // 频控：30 条放行，第 31 条 42901
  for (let i = 1; i <= 30; i++) {
    r = await api(base, 'POST', `/v1/conversations/${convId}/messages`, {
      token: A.token, body: { client_msg_id: `rl-${i}`, msg_type: 'text', content: `消息 ${i}` },
    });
    assert.equal(r.json.code, 0, `第 ${i} 条应放行`);
  }
  r = await api(base, 'POST', `/v1/conversations/${convId}/messages`, {
    token: A.token, body: { client_msg_id: 'rl-31', msg_type: 'text', content: '第 31 条' },
  });
  assert.equal(r.json.code, 42901, '第 31 条应触发单聊频控');
});

// 群消息与群公告内容安全：联系方式/引流 45001
test('群消息/群公告：联系方式内容 45001（班级群 + 老乡群公告）', async (t) => {
  const { base, close } = await startTestServer();
  t.after(close);
  const A = await registerUser(base, { phone: '13970000031', nickname: '群主' });
  await addDemoClassEducation(base, A.token);
  const join = await api(base, 'POST', '/v1/class-groups/join', {
    token: A.token, body: { school_id: 1001, enroll_year: 1996, class_name: '六年2班' },
  });
  const convId = join.json.data.conv_id;

  let r = await api(base, 'POST', `/v1/conversations/${convId}/messages`, {
    token: A.token, body: { client_msg_id: 'grp-bad', msg_type: 'text', content: '加我微信13800001111' },
  });
  assert.equal(r.json.code, 45001, '群消息含联系方式应 45001');
  r = await api(base, 'PUT', `/v1/class-groups/${convId}/announcement`, {
    token: A.token, body: { announcement: '拼车加我V信详聊' },
  });
  assert.equal(r.json.code, 45001, '班级群公告含联系方式应 45001');
  // 正常内容不受影响
  r = await api(base, 'PUT', `/v1/class-groups/${convId}/announcement`, {
    token: A.token, body: { announcement: '周六上午十点母校门口集合' },
  });
  assert.equal(r.json.code, 0);

  // 老乡群公告同样拦截
  r = await api(base, 'PUT', '/v1/users/me/hometown', { token: A.token, body: { type: 1, region_code: '411623102' } });
  assert.equal(r.json.code, 0);
  const hjoin = await api(base, 'POST', '/v1/hometown-groups/join', { token: A.token });
  assert.equal(hjoin.json.code, 0);
  r = await api(base, 'PUT', `/v1/hometown-groups/${hjoin.json.data.conv_id}/announcement`, {
    token: A.token, body: { announcement: 'QQ 123456789 拼车群' },
  });
  assert.equal(r.json.code, 45001, '老乡群公告含联系方式应 45001');
});


// captcha：verify 按 IP 失败计数 10 次/小时 → 42901；slider 自身限流响应不带 captcha_required
test('captcha：verify 失败计数 42901；slider 限流 data 无 captcha_required', async (t) => {
  const { base, close } = await startTestServer();
  t.after(close);
  // 不存在的 captcha_id 恒失败：前 10 次 40001，第 11 次 42901
  for (let i = 1; i <= 10; i++) {
    const r = await api(base, 'POST', '/v1/captcha/verify', { body: { captcha_id: `forged-${i}`, x: 100 } });
    assert.equal(r.json.code, 40001, `第 ${i} 次失败应 40001`);
  }
  let r = await api(base, 'POST', '/v1/captcha/verify', { body: { captcha_id: 'forged-11', x: 100 } });
  assert.equal(r.json.code, 42901, '失败超 10 次/小时应 42901');
  assert.equal(r.json.data, null, '验证码接口自身的 42901 不得带 captcha_required（鸡生蛋）');

  // slider 签发限流（30 次/小时/IP）：第 31 次 42901 且 data 为 null
  for (let i = 1; i <= 30; i++) {
    r = await api(base, 'GET', '/v1/captcha/slider');
    assert.equal(r.json.code, 0, `第 ${i} 次签发应放行`);
  }
  r = await api(base, 'GET', '/v1/captcha/slider');
  assert.equal(r.json.code, 42901);
  assert.equal(r.json.data, null, 'slider 限流响应不得带 captcha_required');
});


// ---------- 朋友圈封面 moment_cover：设置/读取/非法值 40001 ----------
test('moment_cover：PUT 校验（/media/ 前缀）写入；GET /users/me 与 GET /users/:id 下发；null 清除', async (t) => {
  const { base, db, close } = await startTestServer();
  t.after(close);
  const owner = await registerUser(base, { phone: '13970000001', nickname: '封面君' });
  const viewer = await registerUser(base, { phone: '13970000002', nickname: '访客' });

  // 未设置时本人/他人视角均为 null
  let me = await api(base, 'GET', '/v1/users/me', { token: owner.token });
  assert.equal(me.json.data.moment_cover, null);
  let card = await api(base, 'GET', `/v1/users/${owner.userId}`, { token: viewer.token });
  assert.equal(card.json.data.moment_cover, null);

  // 非法值 → 40001（外链 / 路径穿越 / 非图片扩展名）
  for (const bad of ['https://evil.com/cover.jpg', '/etc/passwd', '/media/x.gif']) {
    const r = await api(base, 'PUT', '/v1/users/me', { token: owner.token, body: { moment_cover: bad } });
    assert.equal(r.json.code, 40001, `${bad} 应 40001`);
  }

  // 合法值写入，本人与他人视角均可读
  let r = await api(base, 'PUT', '/v1/users/me', { token: owner.token, body: { moment_cover: '/media/cover-ab12cd.webp' } });
  assert.equal(r.json.code, 0);
  me = await api(base, 'GET', '/v1/users/me', { token: owner.token });
  assert.equal(me.json.data.moment_cover, '/media/cover-ab12cd.webp');
  card = await api(base, 'GET', `/v1/users/${owner.userId}`, { token: viewer.token });
  assert.equal(card.json.data.moment_cover, '/media/cover-ab12cd.webp');

  // 审计落库
  const log = q1(db, "SELECT 1 x FROM audit_logs WHERE user_id=? AND event='moment_cover_update'", owner.userId);
  assert.ok(log, 'moment_cover 更新应落审计');

  // null 清除
  r = await api(base, 'PUT', '/v1/users/me', { token: owner.token, body: { moment_cover: null } });
  assert.equal(r.json.code, 0);
  me = await api(base, 'GET', '/v1/users/me', { token: owner.token });
  assert.equal(me.json.data.moment_cover, null);
});
