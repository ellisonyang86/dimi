import { test } from 'node:test';
import assert from 'node:assert/strict';
import { startTestServer, api, registerUser, befriend } from './helpers.js';
import { q1, run } from '../src/repo.js';

// 三轮审计修复回归：
// 1 contents 顶层 rolled_up（已在 hometownPages.test.js 覆盖）
// 2 users.js 家乡门禁分档 / 3 家乡页作者隐私口径 / 4 GET 页懒返回缺省（hometownPages.test.js）
// 5 content_count 实时计数 + 详情 u.status=1 + follow 频控 / 6 媒体消息 url 校验
// 7 好友列表 status=1 下推 SQL / 8 noteFail 手机号格式门 / 9 路径畸形编码 40001 + 公开端点 IP 限流

async function setHometown(base, token, regionCode, visibility = 'public', db = null, userId = null) {
  // 家乡修改频控 2 次/日（防滥用设计）：测试需多次设置时经 db 直清计数器绕过频控，
  // 不绕过业务校验（频控本身的用例在 hometownPages/频控测试覆盖）
  if (db && userId != null) {
    const day = new Date().toISOString().slice(0, 10);
    run(db, 'DELETE FROM rate_counters WHERE key=?', `hometown_set:${userId}:${day}`);
  }
  const r = await api(base, 'PUT', '/v1/users/me/hometown', { token, body: { type: 1, region_code: regionCode, visibility } });
  assert.equal(r.json?.code, 0, 'set hometown failed: ' + JSON.stringify(r.json));
}

// ---------- 项2：users.js 家乡门禁分档生效 ----------
test('资料卡家乡门禁：friends 仅好友 / fellows_only 好友或同乡 / private 不可见 / public 走交集降级', async (t) => {
  const { base, db, close } = await startTestServer();
  t.after(close);
  const owner = await registerUser(base, { phone: '13981000001', nickname: '家乡主', gender: 1 });
  const friend = await registerUser(base, { phone: '13981000002', nickname: '好友', gender: 1 });
  const fellow = await registerUser(base, { phone: '13981000003', nickname: '同乡', gender: 1 });
  const stranger = await registerUser(base, { phone: '13981000004', nickname: '异乡人', gender: 1 });
  await setHometown(base, owner.token, '411623102', 'public', db, owner.userId); // 周口市 商水县 城关乡
  await setHometown(base, fellow.token, '411623103', 'public', db, fellow.userId); // 同县 练集镇
  await setHometown(base, stranger.token, '330106005', 'public', db, stranger.userId); // 杭州 古荡街道（异市）
  await befriend(base, owner, friend);

  const card = (token) => api(base, 'GET', `/v1/users/${owner.userId}`, { token });
  const setVis = (v) => api(base, 'PUT', '/v1/privacy/settings', { token: owner.token, body: { hometown_visibility: v } });

  // public（默认）：好友 depth=4 含跳转码；同乡（T2 同县）depth=3 无跳转码；T0 陌生人缺省
  let r = await card(friend.token);
  assert.equal(r.json.data.hometown_display, '河南省周口市商水县城关乡');
  assert.equal(r.json.data.hometown_region_code, '411623102');
  r = await card(fellow.token);
  assert.equal(r.json.data.hometown_display, '河南省周口市商水县', 'T2 同乡降级到县');
  assert.equal(r.json.data.hometown_region_code, undefined, '低粒度档不下发跳转码');
  r = await card(stranger.token);
  assert.equal(r.json.data.hometown_display, undefined, 'T0 陌生人缺省');

  // friends：仅好友可见（同乡非好友缺省）
  assert.equal((await setVis('friends')).json.code, 0);
  r = await card(friend.token);
  assert.equal(r.json.data.hometown_display, '河南省周口市商水县城关乡', 'friends 档好友可见');
  r = await card(fellow.token);
  assert.equal(r.json.data.hometown_display, undefined, 'friends 档非好友同乡不可见');
  r = await card(stranger.token);
  assert.equal(r.json.data.hometown_display, undefined);

  // fellows_only：好友或同乡交集可见
  assert.equal((await setVis('fellows_only')).json.code, 0);
  r = await card(friend.token);
  assert.equal(r.json.data.hometown_display, '河南省周口市商水县城关乡', 'fellows_only 档好友可见');
  r = await card(fellow.token);
  assert.equal(r.json.data.hometown_display, '河南省周口市商水县', 'fellows_only 档同乡可见（降级粒度不变）');
  r = await card(stranger.token);
  assert.equal(r.json.data.hometown_display, undefined, 'fellows_only 档异乡陌生人不可见');

  // private：好友也不可见
  assert.equal((await setVis('private')).json.code, 0);
  r = await card(friend.token);
  assert.equal(r.json.data.hometown_display, undefined, 'private 档对好友同样缺省');
  r = await card(fellow.token);
  assert.equal(r.json.data.hometown_display, undefined);

  // 双入口取更严：privacy public 但家乡记录 visibility=friends → 仅好友可见
  assert.equal((await setVis('public')).json.code, 0);
  await setHometown(base, owner.token, '411623102', 'friends', db, owner.userId);
  r = await card(friend.token);
  assert.equal(r.json.data.hometown_display, '河南省周口市商水县城关乡', '记录级 friends 档好友仍可见');
  r = await card(fellow.token);
  assert.equal(r.json.data.hometown_display, undefined, '记录级 friends 档对非好友同乡生效（更严档胜出）');
});

// ---------- 项3+5：家乡页作者隐私口径 / content_count 实时计数 / 详情 u.status=1 / follow 频控 ----------
test('家乡页作者隐私：private 对非作者缺省（列表/详情/公开端点）；公开端点仅 public 作者入选', async (t) => {
  const { base, db, close } = await startTestServer();
  t.after(close);
  const A = await registerUser(base, { phone: '13982000001', nickname: '城关作者', gender: 1 });
  const B = await registerUser(base, { phone: '13982000002', nickname: '看客', gender: 1 });
  await setHometown(base, A.token, '411623102', 'public', db, A.userId);
  await setHometown(base, B.token, '330106005', 'public', db, B.userId);
  const post = await api(base, 'POST', '/v1/hometown-contents', {
    token: A.token, body: { region_code: '411623102', category: 'story', title: '老街旧事' },
  });
  assert.equal(post.json.code, 0);
  const cid = post.json.data.content_id;

  const list = (token) => api(base, 'GET', '/v1/hometown-pages/411623102/contents', { token });
  const detail = (token) => api(base, 'GET', `/v1/hometown-contents/${cid}`, { token });
  const pub = () => api(base, 'GET', '/v1/public/hometown-pages/411623102');

  // 基线：public 作者对所有人可见
  assert.equal((await list(B.token)).json.data.items.length, 1);
  assert.equal((await detail(B.token)).json.code, 0);
  assert.equal((await pub()).json.data.items.length, 1);
  assert.equal((await pub()).json.data.items[0].author_nickname, '城**者', '公开端点昵称掩码');

  // 记录级 private：非作者列表/详情/公开端点一律缺省；作者本人不受影响
  await setHometown(base, A.token, '411623102', 'private', db, A.userId);
  assert.equal((await list(B.token)).json.data.items.length, 0, '作者记录级 private：列表对非作者缺省');
  assert.equal((await detail(B.token)).json.code, 41001, '作者记录级 private：详情对非作者 41001');
  assert.equal((await pub()).json.data.items.length, 0, '作者记录级 private：公开端点缺省');
  assert.equal((await list(A.token)).json.data.items.length, 1, '作者本人仍可见自己的内容');
  assert.equal((await detail(A.token)).json.code, 0);

  // 设置级 private（privacy_settings.hometown_visibility）同口径
  await setHometown(base, A.token, '411623102', 'public', db, A.userId);
  assert.equal((await api(base, 'PUT', '/v1/privacy/settings', { token: A.token, body: { hometown_visibility: 'private' } })).json.code, 0);
  assert.equal((await list(B.token)).json.data.items.length, 0, '作者设置级 private：列表对非作者缺省');
  assert.equal((await detail(B.token)).json.code, 41001);
  assert.equal((await pub()).json.data.items.length, 0);
  await api(base, 'PUT', '/v1/privacy/settings', { token: A.token, body: { hometown_visibility: 'public' } });

  // friends 档统一遵循仅好友可见；公开端点不入选。
  await setHometown(base, A.token, '411623102', 'friends', db, A.userId);
  assert.equal((await list(B.token)).json.data.items.length, 0, 'friends 档对非好友缺省');
  await befriend(base, A, B);
  assert.equal((await list(B.token)).json.data.items.length, 1, 'friends 档对好友可见');
  assert.equal((await pub()).json.data.items.length, 0, '公开端点仅作者 visibility=public 的内容入选');
  await setHometown(base, A.token, '411623102', 'public', db, A.userId);

  // content_count 实时 COUNT：仅计 status=published（直接改库模拟下架）
  let page = await api(base, 'GET', '/v1/hometown-pages/411623102', { token: B.token });
  assert.equal(page.json.data.content_count, 1);
  run(db, "UPDATE hometown_contents SET status='removed' WHERE content_id=?", cid);
  page = await api(base, 'GET', '/v1/hometown-pages/411623102', { token: B.token });
  assert.equal(page.json.data.content_count, 0, '下架后 content_count 实时归零（不依赖冗余列）');
  run(db, "UPDATE hometown_contents SET status='published' WHERE content_id=?", cid);

  // 详情 JOIN users：作者账号非活跃（status!=1）对访客 41001
  run(db, 'UPDATE users SET status=2 WHERE id=?', A.userId);
  assert.equal((await detail(B.token)).json.code, 41001, '作者停用后详情 41001');
  assert.equal((await list(B.token)).json.data.items.length, 0, '作者停用后列表缺省（u.status=1 过滤）');
  run(db, 'UPDATE users SET status=1 WHERE id=?', A.userId);

  // follow/unfollow 频控 100 次/日：预置计数到顶 → 42901；窗口内减 1 次后放行
  run(db, 'INSERT INTO rate_counters(key,count,reset_at) VALUES(?,?,?)', `hometown_follow:${B.userId}:day`, 100, Date.now() + 3600_000);
  let r = await api(base, 'POST', '/v1/hometown-pages/411623102/follow', { token: B.token });
  assert.equal(r.json.code, 42901, '关注超 100 次/日应 42901');
  r = await api(base, 'DELETE', '/v1/hometown-pages/411623102/follow', { token: B.token });
  assert.equal(r.json.code, 42901, '取关与关注共用同一频控额度');
  run(db, 'UPDATE rate_counters SET count=99 WHERE key=?', `hometown_follow:${B.userId}:day`);
  r = await api(base, 'POST', '/v1/hometown-pages/411623102/follow', { token: B.token });
  assert.equal(r.json.code, 0, '窗口内第 100 次应放行');
  assert.equal(r.json.data.is_following, true);
});

// ---------- 项6：image/voice/video 消息 content 过 storage.isValidMediaUrl ----------
test('媒体消息：content 须为 /misc/upload 媒体 url（image 图 / voice m4a·aac / video mp4·mov）', async (t) => {
  const { base, close } = await startTestServer();
  t.after(close);
  const A = await registerUser(base, { phone: '13983000001', nickname: '聊主' });
  const B = await registerUser(base, { phone: '13983000002', nickname: '聊友' });
  const convId = await befriend(base, A, B);
  const send = (msg_type, content) => api(base, 'POST', `/v1/conversations/${convId}/messages`, {
    token: A.token, body: { client_msg_id: `m-${msg_type}-${Math.random()}`, msg_type, content },
  });

  assert.equal((await send('image', '/media/img-a1.jpg')).json.code, 0);
  assert.equal((await send('voice', '/media/voice-b2.m4a')).json.code, 0);
  assert.equal((await send('voice', '/media/voice-c3.aac')).json.code, 0);
  assert.equal((await send('video', '/media/vid-d4.mp4')).json.code, 0);
  assert.equal((await send('video', '/media/vid-e5.mov')).json.code, 0);

  assert.equal((await send('image', 'https://evil.com/x.jpg')).json.code, 40001, '外链图片应 40001');
  assert.equal((await send('image', '/etc/passwd')).json.code, 40001);
  assert.equal((await send('voice', '/media/not-voice.jpg')).json.code, 40001, '语音消息不接受图片扩展名');
  assert.equal((await send('video', '/media/not-video.png')).json.code, 40001, '视频消息不接受图片扩展名');
  assert.equal((await send('image', undefined)).json.code, 40001, '媒体消息 content 必填');
});

// ---------- 项7：好友列表 status=1 过滤下推 SQL ----------
test('好友列表：注销/停用好友在 SQL 层剔除，不占分页窗口', async (t) => {
  const { base, db, close } = await startTestServer();
  t.after(close);
  const A = await registerUser(base, { phone: '13984000001', nickname: '主号' });
  const B = await registerUser(base, { phone: '13984000002', nickname: '好友甲' });
  const C = await registerUser(base, { phone: '13984000003', nickname: '好友乙' });
  await befriend(base, A, B);
  await befriend(base, A, C);

  let r = await api(base, 'GET', '/v1/friends', { token: A.token });
  assert.equal(r.json.data.items.length, 2);

  run(db, 'UPDATE users SET status=9 WHERE id=?', C.userId); // 模拟注销冷静期
  r = await api(base, 'GET', '/v1/friends', { token: A.token });
  assert.equal(r.json.data.items.length, 1, '停用好友不出现在列表');
  assert.equal(r.json.data.items[0].user_id, B.userId);
  assert.equal(r.json.data.next_cursor, null, '剔除在 SQL 层：不多占 limit+1 窗口，无虚假翻页');
});

// ---------- 项8：noteFail 的 phone 先过格式校验再参与计数 key ----------
test('登录失败计数：畸形手机号不生成 phone 维度计数 key（IP 维度仍计数）', async (t) => {
  const { base, db, close } = await startTestServer();
  t.after(close);

  // 合法手机号失败仍计入 phone 维度（先行，避免耗尽 IP 维度 10 次/小时配额）
  let r = await api(base, 'POST', '/v1/auth/login', { body: { grant_type: 'password', phone: '13985000099', password: 'x'.repeat(10) } });
  assert.equal(r.json.code, 40001);
  assert.ok(q1(db, "SELECT 1 x FROM rate_counters WHERE key='login_fail:phone:13985000099'"), '合法手机号应计入 phone 维度');

  // 畸形手机号连试 9 次：全部 40001（不触发 phone 维度 42901；IP 维度连前 1 次恰好到上限未超）
  for (let i = 1; i <= 9; i++) {
    r = await api(base, 'POST', '/v1/auth/login', { body: { grant_type: 'password', phone: 'not-a-phone', password: 'x'.repeat(10) } });
    assert.equal(r.json.code, 40001, `第 ${i} 次畸形手机号登录应 40001 而非 42901`);
  }
  assert.equal(q1(db, "SELECT 1 x FROM rate_counters WHERE key='login_fail:phone:not-a-phone'"), undefined,
    '畸形手机号不得生成 phone 维度计数 key');
  const ipRow = q1(db, "SELECT count FROM rate_counters WHERE key='login_fail:ip:127.0.0.1'");
  assert.equal(ipRow.count, 10, 'IP 维度仍正常计数');
});

// ---------- 项9：路径参数畸形编码 40001；公开家乡页端点按 IP 60 次/小时低频限 ----------
test('路径参数畸形 percent-encoding 转 40001；公开家乡页端点 IP 限流 60 次/小时', async (t) => {
  const { base, db, close } = await startTestServer();
  t.after(close);
  const u = await registerUser(base, { phone: '13986000001', nickname: '路人' });

  // 畸形编码：%ZZ 与截断的多字节序列均 40001（不再 500）
  let r = await api(base, 'GET', '/v1/hometown-pages/%ZZ', { token: u.token });
  assert.equal(r.json.code, 40001, '畸形编码应 40001');
  r = await api(base, 'GET', '/v1/hometown-pages/%E4%B8', { token: u.token });
  assert.equal(r.json.code, 40001, '截断的 UTF-8 编码应 40001');

  // 公开端点基线可用
  r = await api(base, 'GET', '/v1/public/hometown-pages/411623102');
  assert.equal(r.json.code, 0);
  // 预置 IP 计数到 60 → 42901（data=null，不走滑块流程）
  run(db, `INSERT INTO rate_counters(key,count,reset_at) VALUES(?,?,?)
           ON CONFLICT(key) DO UPDATE SET count=excluded.count, reset_at=excluded.reset_at`,
    'pub_hometown_page:127.0.0.1:hour', 60, Date.now() + 3600_000);
  r = await api(base, 'GET', '/v1/public/hometown-pages/411623102');
  assert.equal(r.json.code, 42901, '公开端点超 60 次/小时/IP 应 42901');
  assert.equal(r.json.data, null);
});

// ---------- 家乡修改防滥用（设计 §19）：2 次/日频控 + 换市自动退原老乡群 ----------
test('家乡修改频控 2 次/日；换市自动退出原老乡群', async (t) => {
  const { base, db, close } = await startTestServer();
  t.after(close);
  const A = await registerUser(base, { phone: '13983000001', nickname: '迁客', gender: 1 });
  const put = (code) => api(base, 'PUT', '/v1/users/me/hometown', { token: A.token, body: { type: 1, region_code: code } });

  // 第 1、2 次成功，第 3 次 42901（频控收紧：10/日 → 2/日）
  assert.equal((await put('411623102')).json.code, 0);
  assert.equal((await put('411623103')).json.code, 0);
  const third = await put('411623102');
  assert.equal(third.json.code, 42901, '当日第 3 次修改被频控拒绝');

  // 换市自动退群：新用户（独立频控窗口）先入周口市老乡群，再改家乡到杭州
  const B = await registerUser(base, { phone: '13983000002', nickname: '搬家者', gender: 1 });
  const setB = (code) => api(base, 'PUT', '/v1/users/me/hometown', { token: B.token, body: { type: 1, region_code: code } });
  assert.equal((await setB('411623102')).json.code, 0);
  const join = await api(base, 'POST', '/v1/hometown-groups/join', { token: B.token });
  assert.equal(join.json.code, 0);
  const convId = join.json.data.conv_id;
  assert.equal((await setB('330106005')).json.code, 0, '换到杭州（市前缀变化）');
  const members = await api(base, 'GET', `/v1/hometown-groups/${convId}/members`, { token: B.token });
  assert.equal(members.json.code, 40301, '已不在原市老乡群（自动退出）');
  const leaveLog = q1(db, "SELECT * FROM audit_logs WHERE event='hometown_group_auto_leave' AND user_id=?", B.userId);
  assert.ok(leaveLog, '自动退群落审计');
});
