import { test } from 'node:test';
import assert from 'node:assert/strict';
import { startTestServer, api, registerUser } from './helpers.js';

// 设置家乡（type=1，需四级行政区划）
async function setHometown(base, token, regionCode) {
  const r = await api(base, 'PUT', '/v1/users/me/hometown', { token, body: { type: 1, region_code: regionCode } });
  if (r.json?.code !== 0) throw new Error('set hometown failed: ' + JSON.stringify(r.json));
}

// 投稿快捷封装
async function postContent(base, token, { region_code, category = 'scenery', title, body, media = [], headers } = {}) {
  return api(base, 'POST', '/v1/hometown-contents', {
    token, body: { region_code, category, title, body, media }, headers,
  });
}

// 家乡页 M1：建页/投稿门禁/频控/45001/浏览去重/点赞关注幂等/低密度 rollup/公开端点脱敏
test('家乡页 M1 全流程', async (t) => {
  const { base, db, close } = await startTestServer();
  t.after(close);

  const A = await registerUser(base, { phone: '13931000001', nickname: '城关阿明', gender: 1, real_name: '王明' });
  const B = await registerUser(base, { phone: '13931000002', nickname: '练集小芳', gender: 2, real_name: '林小芳' });
  const C = await registerUser(base, { phone: '13931000003', nickname: '杭漂铁柱', gender: 1, real_name: '赵铁柱' });
  await setHometown(base, A.token, '411623102'); // 河南 周口市 商水县 城关乡
  await setHometown(base, B.token, '411623103'); // 河南 周口市 商水县 练集镇（同县同市）
  await setHometown(base, C.token, '330106005'); // 浙江 杭州市 西湖区 古荡街道（异市）

  // ---- 页聚合懒返回缺省：GET 不落库（建页移到投稿/关注写路径）；region_path 逐级拼省市区镇；group 未创建为 null ----
  const page0 = await api(base, 'GET', '/v1/hometown-pages/411623102', { token: A.token });
  assert.equal(page0.json.code, 0);
  assert.deepEqual(page0.json.data.region_path, ['河南省', '周口市', '商水县', '城关乡']);
  assert.equal(page0.json.data.follower_count, 0);
  assert.equal(page0.json.data.content_count, 0);
  assert.equal(page0.json.data.is_following, false);
  assert.equal(page0.json.data.can_post, true);
  assert.equal(page0.json.data.group, null);
  const pageRow = db.prepare("SELECT * FROM hometown_pages WHERE region_code='411623102'").get();
  assert.equal(pageRow, undefined, 'GET 页聚合为懒返回缺省，不得落库建页');

  // 异市 C 看同页：can_post=false；未设家乡的市外用户投稿门禁见下
  const pageC = await api(base, 'GET', '/v1/hometown-pages/411623102', { token: C.token });
  assert.equal(pageC.json.data.can_post, false);
  // 非四级行政区划 40001；不存在区划 41001
  const pageCity = await api(base, 'GET', '/v1/hometown-pages/411600', { token: A.token });
  assert.equal(pageCity.json.code, 40001);
  const pageBad = await api(base, 'GET', '/v1/hometown-pages/999999999', { token: A.token });
  assert.equal(pageBad.json.code, 41001);

  // ---- 投稿资格门禁：异市 C 投稿 40301；未设家乡的 D 同样 40301 ----
  const postC = await postContent(base, C.token, { region_code: '411623102', title: '我也想投稿' });
  assert.equal(postC.json.code, 40301);
  assert.equal(postC.json.message, '只有当地老乡才能向该家乡页投稿');
  const D = await registerUser(base, { phone: '13931000004', nickname: '无家乡路人', gender: 1 });
  const postD = await postContent(base, D.token, { region_code: '411623102', title: '我没设家乡' });
  assert.equal(postD.json.code, 40301);

  // ---- 45001 联系方式拦截（机器拦截即初审，不落库） ----
  const blocked = await postContent(base, A.token, {
    region_code: '411623102', title: '家乡特产', body: '正宗红薯粉，联系我 13800001234 购买',
  });
  assert.equal(blocked.json.code, 45001);
  const blockAudit = db.prepare("SELECT 1 x FROM audit_logs WHERE event='content_block' AND scene='hometown_content' AND user_id=?").get(A.userId);
  assert.ok(blockAudit, '45001 拦截应落审计');

  // ---- 正常投稿：直接 published；页 content_count 同步；幂等键重放不重复 ----
  const post1 = await postContent(base, A.token, {
    region_code: '411623102', category: 'scenery', title: '沙河渡口晚霞', body: '傍晚的渡口很美',
    media: ['/media/test-shake.jpg'], headers: { 'Idempotency-Key': 'hp-post-1' },
  });
  assert.equal(post1.json.code, 0);
  assert.equal(post1.json.data.title, '沙河渡口晚霞');
  assert.deepEqual(post1.json.data.media, ['/media/test-shake.jpg']);
  assert.equal(post1.json.data.author.nickname, '城关阿明');
  const cid1 = post1.json.data.content_id;
  assert.ok(db.prepare("SELECT * FROM hometown_pages WHERE region_code='411623102'").get(), '首次投稿应自动建页（写路径）');
  const post1Replay = await postContent(base, A.token, {
    region_code: '411623102', category: 'scenery', title: '沙河渡口晚霞', body: '傍晚的渡口很美',
    media: ['/media/test-shake.jpg'], headers: { 'Idempotency-Key': 'hp-post-1' },
  });
  assert.equal(post1Replay.json.message, 'ok(idempotent)');
  assert.equal(post1Replay.json.data.content_id, cid1, '幂等键重放返回原内容');
  // 参数校验：超长标题 / 非法分类 / 非法媒体 url
  const longTitle = await postContent(base, A.token, { region_code: '411623102', title: '长'.repeat(61) });
  assert.equal(longTitle.json.code, 40001);
  const badCat = await postContent(base, A.token, { region_code: '411623102', category: 'gossip', title: '八卦' });
  assert.equal(badCat.json.code, 40001);
  const badMedia = await postContent(base, A.token, { region_code: '411623102', title: '坏图', media: ['http://evil.com/x.jpg'] });
  assert.equal(badMedia.json.code, 40001);

  // ---- 频控：5 条/日/人（post1 已计 1 条；幂等重放与参数失败不计） ----
  for (const [i, title] of ['老街油馍头', '渡口老槐树', '镇上正月会', '麦田灌溉渠'].entries()) {
    const r = await postContent(base, A.token, { region_code: '411623102', category: ['product', 'scenery', 'craft', 'story'][i], title });
    assert.equal(r.json.code, 0, `第 ${i + 2} 条投稿应成功`);
  }
  const post6 = await postContent(base, A.token, { region_code: '411623102', title: '第六条投稿' });
  assert.equal(post6.json.code, 42901, '第 6 条投稿触发日频控');

  // 页计数同步：5 条 published
  const page1 = await api(base, 'GET', '/v1/hometown-pages/411623102', { token: A.token });
  assert.equal(page1.json.data.content_count, 5);

  // ---- 内容列表：倒序；category 过滤；城关乡 5 条不触发 rollup ----
  const list = await api(base, 'GET', '/v1/hometown-pages/411623102/contents', { token: B.token });
  assert.equal(list.json.code, 0);
  assert.equal(list.json.data.items.length, 5);
  assert.equal(list.json.data.rollup_items.length, 0, '镇内容 ≥5 条不触发低密度兜底');
  assert.equal(list.json.data.rolled_up, false, '顶层 rolled_up 标记：无兜底为 false');
  assert.ok(list.json.data.items[0].content_id > list.json.data.items[4].content_id, '倒序排列');
  assert.equal(list.json.data.next_cursor, null);
  const listScenery = await api(base, 'GET', '/v1/hometown-pages/411623102/contents?category=scenery', { token: B.token });
  assert.equal(listScenery.json.data.items.length, 2);
  assert.ok(listScenery.json.data.items.every((i) => i.category === 'scenery'));

  // ---- 浏览去重：B 两次详情计 1 次，A 再访计第 2 次 ----
  const detail1 = await api(base, 'GET', `/v1/hometown-contents/${cid1}`, { token: B.token });
  assert.equal(detail1.json.code, 0);
  assert.equal(detail1.json.data.view_count, 1);
  const detail2 = await api(base, 'GET', `/v1/hometown-contents/${cid1}`, { token: B.token });
  assert.equal(detail2.json.data.view_count, 1, '同人 24h 内重复浏览只计 1 次');
  const detail3 = await api(base, 'GET', `/v1/hometown-contents/${cid1}`, { token: A.token });
  assert.equal(detail3.json.data.view_count, 2, '换人才再次计数');

  // ---- 点赞幂等：重复点赞不重复计数；取消幂等 ----
  const like1 = await api(base, 'POST', `/v1/hometown-contents/${cid1}/like`, { token: B.token });
  assert.equal(like1.json.data.like_count, 1);
  const like2 = await api(base, 'POST', `/v1/hometown-contents/${cid1}/like`, { token: B.token });
  assert.equal(like2.json.data.like_count, 1, '重复点赞幂等');
  const listAfterLike = await api(base, 'GET', '/v1/hometown-pages/411623102/contents', { token: B.token });
  assert.equal(listAfterLike.json.data.items.find((i) => i.content_id === cid1).liked, true);
  const unlike1 = await api(base, 'DELETE', `/v1/hometown-contents/${cid1}/like`, { token: B.token });
  assert.equal(unlike1.json.data.like_count, 0);
  const unlike2 = await api(base, 'DELETE', `/v1/hometown-contents/${cid1}/like`, { token: B.token });
  assert.equal(unlike2.json.data.like_count, 0, '重复取消点赞幂等且不为负');

  // ---- 关注幂等：follower_count 同步；页 is_following 翻转 ----
  const follow1 = await api(base, 'POST', '/v1/hometown-pages/411623102/follow', { token: B.token });
  assert.equal(follow1.json.data.follower_count, 1);
  const follow2 = await api(base, 'POST', '/v1/hometown-pages/411623102/follow', { token: B.token });
  assert.equal(follow2.json.data.follower_count, 1, '重复关注幂等');
  const pageB = await api(base, 'GET', '/v1/hometown-pages/411623102', { token: B.token });
  assert.equal(pageB.json.data.is_following, true);
  const unfollow1 = await api(base, 'DELETE', '/v1/hometown-pages/411623102/follow', { token: B.token });
  assert.equal(unfollow1.json.data.follower_count, 0);
  const unfollow2 = await api(base, 'DELETE', '/v1/hometown-pages/411623102/follow', { token: B.token });
  assert.equal(unfollow2.json.data.follower_count, 0, '重复取关幂等且不为负');

  // ---- 低密度兜底 rollup：练集镇（411623103）仅 B 投稿 2 条，首页附加同县城关乡内容 ----
  const b1 = await postContent(base, B.token, { region_code: '411623103', category: 'product', title: '练集葡萄熟了' });
  assert.equal(b1.json.code, 0);
  const b2 = await postContent(base, B.token, { region_code: '411623103', category: 'story', title: '镇上的老茶馆' });
  assert.equal(b2.json.code, 0);
  const listTownB = await api(base, 'GET', '/v1/hometown-pages/411623103/contents', { token: A.token });
  assert.equal(listTownB.json.data.items.length, 2);
  assert.equal(listTownB.json.data.rollup_items.length, 5, '同县其他镇最新内容最多兜底 5 条');
  assert.equal(listTownB.json.data.rolled_up, true, '顶层 rolled_up 标记：有兜底为 true');
  assert.ok(listTownB.json.data.rollup_items.every((i) => i.rolled_up === true && i.region_code === '411623102'));
  // 带 cursor 翻页不触发兜底
  const cursor = listTownB.json.data.items[listTownB.json.data.items.length - 1].content_id;
  const listTownBP2 = await api(base, 'GET', `/v1/hometown-pages/411623103/contents?cursor=${cursor}`, { token: A.token });
  assert.equal(listTownBP2.json.data.rollup_items.length, 0, '翻页（有 cursor）不触发兜底');
  assert.equal(listTownBP2.json.data.rolled_up, false);
  // 跨县不兜底：杭州古荡街道无内容且无同县其他镇
  const listHZ = await api(base, 'GET', '/v1/hometown-pages/330106005/contents', { token: C.token });
  assert.equal(listHZ.json.data.items.length, 0);
  assert.equal(listHZ.json.data.rollup_items.length, 0, '同县无其他镇内容时兜底为空');
  assert.equal(listHZ.json.data.rolled_up, false);

  // ---- 老乡群入口卡：A 建群后页聚合带出 group ----
  const joinA = await api(base, 'POST', '/v1/hometown-groups/join', { token: A.token });
  assert.equal(joinA.json.code, 0);
  const page2 = await api(base, 'GET', '/v1/hometown-pages/411623102', { token: B.token });
  assert.equal(page2.json.data.group.conv_id, joinA.json.data.conv_id);
  assert.equal(page2.json.data.group.title, '周口市老乡群');
  assert.equal(page2.json.data.group.member_count, 1);

  // ---- 公开端点（免鉴权）：不含 body 全文、不含作者 id，作者昵称掩码（maskName） ----
  const pub = await api(base, 'GET', '/v1/public/hometown-pages/411623102');
  assert.equal(pub.json.code, 0);
  assert.equal(pub.json.data.region_name, '城关乡');
  assert.equal(pub.json.data.follower_count, 0);
  assert.equal(pub.json.data.items.length, 5);
  const pubItem = pub.json.data.items[0];
  assert.deepEqual(Object.keys(pubItem).sort(), ['author_nickname', 'category', 'cover', 'created_at', 'title', 'view_count']);
  assert.equal(pubItem.author_nickname, '城**明', '公开端点昵称应掩码（maskName 首尾规则）');
  const pubCoverItem = pub.json.data.items.find((i) => i.title === '沙河渡口晚霞');
  assert.equal(pubCoverItem.cover, '/media/test-shake.jpg');
  const pubRaw = JSON.stringify(pub.json.data);
  assert.ok(!pubRaw.includes('傍晚的渡口很美'), '公开端点不得泄漏 body 全文');
  assert.ok(!pubRaw.includes('user_id') && !pubRaw.includes('author_id'), '公开端点不得泄漏作者 id 字段');
  const pubBad = await api(base, 'GET', '/v1/public/hometown-pages/999999999');
  assert.equal(pubBad.json.code, 41001);

  // ---- janitor：hometown_views 超 48h 记录被清理 ----
  const { runJanitor } = await import('../src/janitor.js');
  const old = new Date(Date.now() - 49 * 3600 * 1000).toISOString();
  db.prepare('UPDATE hometown_views SET viewed_at=? WHERE content_id=? AND viewer_id=?').run(old, cid1, B.userId);
  runJanitor(db);
  const staleView = db.prepare('SELECT 1 x FROM hometown_views WHERE content_id=? AND viewer_id=?').get(cid1, B.userId);
  assert.equal(staleView, undefined, '超 48h 浏览位点应被 janitor 清理');
  const freshView = db.prepare('SELECT 1 x FROM hometown_views WHERE content_id=? AND viewer_id=?').get(cid1, A.userId);
  assert.ok(freshView, '48h 内浏览位点保留');
});
