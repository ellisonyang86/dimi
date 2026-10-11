import { test } from 'node:test';
import assert from 'node:assert/strict';
import { startTestServer, api, registerUser } from './helpers.js';
import { creditCoins, coinBalance } from '../src/coins.js';
import { openDb } from '../src/db.js';

async function fixture(t) {
  const app = await startTestServer();
  t.after(app.close);
  const author = await registerUser(app.base, { phone: '13988000001', nickname: '家乡作者' });
  const reader = await registerUser(app.base, { phone: '13988000002', nickname: '读者' });
  const third = await registerUser(app.base, { phone: '13988000003', nickname: '另一位读者' });
  const home = await api(app.base, 'PUT', '/v1/users/me/hometown', { token: author.token,
    body: { type: 1, region_code: '411623102' } });
  assert.equal(home.json.code, 0);
  const result = await api(app.base, 'POST', '/v1/hometown-contents', { token: author.token,
    body: { region_code: '411623102', category: 'story', title: '故乡的老街', body: '## 清晨\n\n一碗热汤。\n\n> 记忆里的味道。' } });
  assert.equal(result.json.code, 0);
  return { ...app, author, reader, third, path: '/v1/hometown-contents/' + result.json.data.content_id,
    contentId: result.json.data.content_id };
}

test('家乡评论：分页、幂等、删除权限、拉黑过滤及输入校验', async t => {
  const f = await fixture(t);
  const write = (text, user = f.reader, headers) => api(f.base, 'POST', f.path + '/comments', {
    token: user.token, body: { content: text }, headers });
  const first = await write('这里的清晨真美', f.reader, { 'Idempotency-Key': 'article-comment-1' });
  assert.equal(first.json.code, 0);
  const replay = await write('这里的清晨真美', f.reader, { 'Idempotency-Key': 'article-comment-1' });
  assert.equal(replay.json.data.comment_id, first.json.data.comment_id);
  for (const text of ['', '  ', '字'.repeat(501), 123, {}]) assert.equal((await write(text)).json.code, 40001);
  assert.equal((await write('请联系我 13800001234')).json.code, 45001);
  let page = await api(f.base, 'GET', f.path + '/comments', { token: f.reader.token });
  assert.equal(page.json.data.total_count, 1);
  assert.equal(page.json.data.items[0].can_delete, true);
  const id = first.json.data.comment_id;
  assert.equal((await api(f.base, 'DELETE', f.path + '/comments/' + id, { token: f.third.token })).json.code, 40301);
  assert.equal((await api(f.base, 'DELETE', f.path + '/comments/' + id, { token: f.author.token })).json.code, 0);
  assert.equal((await api(f.base, 'GET', f.path + '/comments', { token: f.reader.token })).json.data.total_count, 0);
  const insert = f.db.prepare('INSERT INTO hometown_comments(content_id,from_user,content,created_at) VALUES(?,?,?,?)');
  for (let i = 0; i < 25; i++) insert.run(f.contentId, f.reader.userId, '评论 ' + i, new Date().toISOString());
  insert.run(f.contentId, f.third.userId, '被拉黑读者的评论', new Date().toISOString());
  f.db.prepare('INSERT INTO blocks(user_id,blocked_id) VALUES(?,?)').run(f.author.userId, f.third.userId);
  page = await api(f.base, 'GET', f.path + '/comments', { token: f.author.token });
  assert.equal(page.json.data.total_count, 25);
  assert.equal(page.json.data.items.length, 20);
  const next = await api(f.base, 'GET', f.path + '/comments?cursor=' + page.json.data.next_cursor, { token: f.author.token });
  assert.equal(next.json.data.items.length, 5);
  assert.equal(next.json.data.next_cursor, null);
  assert.equal(new Set([...page.json.data.items, ...next.json.data.items].map(c => c.id)).size, 25);
  assert.equal((await api(f.base, 'GET', f.path + '/comments?cursor=bad', { token: f.author.token })).json.code, 40001);
});

test('家乡打赏：账本守恒、幂等、防透支、作者自赏限制、迁移可重跑', async t => {
  const f = await fixture(t);
  creditCoins(f.db, { userId: f.reader.userId, bizType: 'test_grant', bizId: 'gift-test', amount: 20 });
  const beforeReader = coinBalance(f.db, f.reader.userId);
  const beforeAuthor = coinBalance(f.db, f.author.userId);
  const gift = (amount, user = f.reader, key = 'home-gift-1') => api(f.base, 'POST', f.path + '/gifts', {
    token: user.token, headers: { 'Idempotency-Key': key }, body: { coin_amount: amount } });
  const first = await gift(5);
  assert.equal(first.json.code, 0);
  const replay = await gift(5);
  assert.equal(replay.json.data.order_id, first.json.data.order_id);
  assert.equal(coinBalance(f.db, f.reader.userId), beforeReader - 5);
  assert.equal(coinBalance(f.db, f.author.userId), beforeAuthor + 5);
  assert.equal((await gift(52, f.reader, 'not-enough')).json.code, 40001);
  assert.equal((await gift(2, f.reader, 'invalid-denomination')).json.code, 40001);
  assert.equal((await gift(1, f.author, 'self-gift')).json.code, 40001);
  assert.equal(coinBalance(f.db, f.reader.userId), beforeReader - 5);
  const summary = await api(f.base, 'GET', f.path + '/gifts', { token: f.reader.token });
  assert.equal(summary.json.data.total_count, 1);
  assert.equal(summary.json.data.total_coins, 5);
  assert.equal(f.db.prepare('SELECT gift_coins FROM hometown_contents WHERE content_id=?').get(f.contentId).gift_coins, 5);
  assert.equal(f.db.prepare('SELECT COUNT(*) n FROM coin_transactions WHERE biz_id=?').get(first.json.data.order_id).n, 2);
  const reopened = openDb(f.db.prepare('PRAGMA database_list').get().file);
  assert.equal(reopened.prepare('SELECT COUNT(*) n FROM gift_orders WHERE hometown_content_id=?').get(f.contentId).n, 1);
  reopened.close();
});

test('文章隐私和删除统一限制评论、点赞与打赏', async t => {
  const f = await fixture(t);
  f.db.prepare("UPDATE privacy_settings SET hometown_visibility='private' WHERE user_id=?").run(f.author.userId);
  for (const [method, suffix, body] of [
    ['GET', '/comments'], ['POST', '/comments', { content: '不应写入' }],
    ['GET', '/gifts'], ['POST', '/gifts', { coin_amount: 1 }], ['POST', '/like'],
  ]) assert.equal((await api(f.base, method, f.path + suffix, { token: f.reader.token, body })).json.code, 41001);
  assert.equal(f.db.prepare('SELECT COUNT(*) n FROM hometown_comments').get().n, 0);
  await api(f.base, 'DELETE', f.path, { token: f.author.token });
  assert.equal((await api(f.base, 'GET', f.path + '/comments', { token: f.author.token })).json.code, 41001);
});

test('长文发布：两万字、图片引用与个人主页读取，普通动态仍限制两千字', async t => {
  const f = await fixture(t);
  const content = '# 故乡的故事\n\n## 出发\n\n' + '旧时的故事。'.repeat(1500);
  const post = (body) => api(f.base, 'POST', '/v1/moments', { token: f.author.token, body });
  const article = await post({ content_type: 'article', content, visibility: 'public', media_ids: ['/media/article.jpg'] });
  assert.equal(article.json.code, 0);
  assert.equal(article.json.data.content, content);
  assert.equal(article.json.data.content_type, 'article');
  assert.equal((await post({ content_type: 'text', content })).json.code, 40001);
  assert.equal((await post({ content_type: 'article', content: '字'.repeat(20001) })).json.code, 40001);
  const profile = await api(f.base, 'GET', '/v1/users/' + f.author.userId + '/moments', { token: f.author.token });
  assert.equal(profile.json.data.items[0].moment_id, article.json.data.moment_id);
  const hometown = await api(f.base, 'POST', '/v1/hometown-contents', { token: f.author.token,
    body: { region_code: '411623102', category: 'story', title: '长篇家乡故事', body: content } });
  assert.equal(hometown.json.code, 0);
  assert.equal(hometown.json.data.body, content);
});
